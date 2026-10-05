"""Planner (interest pool -> tasks).

plan_task: for one rigid task (exam / quiz / assignment / project / meeting), work back to review blocks and reminders.
plan_week: after rigid tasks, split the week's remaining free time among interests by weight x (1 - heat),
           then let the LLM (or templates) turn "guitar 3h/week" into concrete practice sessions.
"""

import math;
import from datetime { datetime, date, timedelta }
import from user.user { User, current_user }
import from interests.pool { Interest, InterestKind }
import from interests.dynamics { allocate_hours, priority, effective_budget }
import from tasks.task { Task, StudyBlock, TaskKind, TaskStatus }
import from tasks.rules { estimate_hours, reminder_chain, exam_review_plan, quiz_review_hours, split_chunks, project_weekly_hours }
import from tasks.slots { find_slot, free_hours }
import from common.graph { board_of, tasks_of, blocks_of, interest_of, interests_of, attach_task, add_block, add_reminder, clear_future, delete_task, tasks_of_interest }
import from common.timeutil { to_dt, fmt_dt, at, pretty, pretty_day, hm, weekday_name, week_monday, round_half, plural }
import from common.config { cfg }
import from ai.generate { tasks_from_interest, base_hours, review_focus }
import from sync.events { emit_event }

glob PREF_LABEL: dict = {
    "peak": "placed in your high-focus hours", "low": "placed in a low-energy slot", "morning": "in the morning, as you prefer",
    "afternoon": "in the afternoon, as you prefer", "evening": "in the evening, as you prefer"
};

"""Split `hours` into blocks no longer than one focus session and place them on `day` (trying fallback_days if they do not fit)."""
def place_hours(u: User, t: Task, day: date, hours: float, focus: str, pref: str, now: datetime, latest_end: datetime | None, why: str, fallback_days: list = []) -> list[StudyBlock] {
    max_h = u.max_focus_min / 60.0;
    n = max(1, math.ceil(hours / max_h - 1e-9));
    per_min = int(round(hours * 60 / n / 15)) * 15;
    per_min = max(15, per_min);
    placed: list[StudyBlock] = [];
    candidates = [day] + fallback_days;
    order = [d for d in candidates if d >= now.date()];
    for _ in range(n) {
        slot = None;
        # look within the daily cap first, then relax the cap
        for respect in [True, False] {
            for d in order {
                slot = find_slot(u, d, per_min, pref, now, latest_end, respect, None, True);
                if slot is not None {
                    break;
                }
            }
            if slot is not None {
                break;
            }
        }
        if slot is None {
            continue;
        }
        placed.append(add_block(u, t, fmt_dt(slot[0]), fmt_dt(slot[1]), focus, why));
    }
    return placed;
}

walker plan_task {
    has out: list[str] = [],
        quiet: bool = False;

    can plan with Task entry {
        u = current_user();
        t = here;
        if not t.is_open() or t.locked or not t.due {
            disengage;
        }
        now = u.now();
        now_s = fmt_dt(now);
        clear_future(t, now_s);
        i = interest_of(t);
        kind = t.kind.name;
        mastery = i.mastery if (i is not None and i.kind == InterestKind.STUDY and kind in ["EXAM", "QUIZ", "ASSIGNMENT"]) else -1.0;
        if t.est_hours <= 0 {
            base = base_hours(t.title, kind, t.scope);
            t.est_hours = estimate_hours(base, t.difficulty, u.calib_of(kind), float(cfg("buffer_ratio")), mastery);
        }
        due = to_dt(t.due);
        blocks: list[StudyBlock] = [];
        course = i.name if i is not None else t.title;
        weak = i.weak_points if i is not None else [];
        src = f"Rigid task {t.title} from \"{i.name}\"" if i is not None else f"Rigid task {t.title}";

        if kind == "EXAM" {
            days_left = (due.date() - now.date()).days;
            n = min(int(cfg("exam_lead_days")), days_left);
            plan = exam_review_plan(t.est_hours, n, weak);
            focuses = review_focus(course, t.scope, weak, [s.focus for s in plan]);
            for (k, s) in enumerate(plan) {
                day = due.date() - timedelta(days=s.offset);
                label = f"T-{s.offset}" if s.offset > 0 else "T-0";
                why = f"{src}: {label} by working back from the date, {PREF_LABEL['peak'] if s.stage != 'glance' else 'on the morning of the exam'}";
                if s.stage in ["glance", "cram"] {
                    latest = due - timedelta(minutes=30);
                    pref = "morning" if s.stage == "glance" else "peak";
                    blocks += place_hours(u, t, day, s.hours, f"{t.title} review: {focuses[k]}", pref, now, latest, why);
                } else {
                    fallback = [day - timedelta(days=1), day + timedelta(days=1)];
                    fallback = [d for d in fallback if d < due.date()];
                    blocks += place_hours(u, t, day, s.hours, f"{t.title} review: {focuses[k]}", "peak", now, due - timedelta(hours=1), why, fallback);
                }
            }
            reviews = [b for b in blocks if "Quick morning skim" not in b.focus];
            if not self.quiet {
                extra = " (mastery is low, so extra time was added)" if 0 <= mastery < 0.6 else "";
                self.out.append(f"Estimated review: {hm(t.est_hours)}{extra}");
                if reviews {
                    days = sorted(set([to_dt(b.start).date() for b in reviews]));
                    per_day = [sum([b.hours() for b in reviews if to_dt(b.start).date() == d]) for d in days];
                    span = f"{days[0].month}/{days[0].day}–{days[-1].month}/{days[-1].day}" if len(days) > 1 else f"{days[0].month}/{days[0].day}";
                    rng = hm(min(per_day)) if min(per_day) == max(per_day) else f"{hm(min(per_day)).rstrip('h')}–{hm(max(per_day))}";
                    self.out.append(f"📅 {span}: {rng} of review per day");
                    quiz = [b for b in reviews if "quiz" in b.focus.lower()];
                    if quiz {
                        self.out.append(f"🧪 {pretty(quiz[0].start)} mini quiz + cheat sheet");
                    }
                }
            }
        } elif kind == "QUIZ" {
            h = quiz_review_hours(t.est_hours);
            day = due.date() - timedelta(days=int(cfg("quiz_lead_days")));
            if day < now.date() {
                day = now.date();
            }
            focus = f"{t.title} review: {t.scope + ' ' if t.scope else ''}key points + 5 self-test questions";
            blocks += place_hours(u, t, day, h, focus, "peak", now, due - timedelta(hours=1), f"{src}: T-1 rule", [now.date()]);
            if not self.quiet and blocks {
                self.out.append(f"📅 {pretty(blocks[0].start)} review {hm(h)} + 5 self-test questions");
            }
        } elif kind == "ASSIGNMENT" {
            max_chunk = min(2.0, u.max_focus_min / 60.0);
            chunks = split_chunks(t.est_hours, max_chunk);
            finish = due.date() - timedelta(days=1);
            latest = at(finish, u.sleep_h);
            if finish < now.date() {
                finish = now.date();
                latest = due - timedelta(hours=1);
            }
            days = [now.date() + timedelta(days=k) for k in range((finish - now.date()).days + 1)];
            span = days[:max(1, min(len(days), len(chunks) * 2))];
            for (k, c) in enumerate(chunks) {
                idx = int(math.floor(len(span) * k / len(chunks)));
                day = span[min(idx, len(span) - 1)];
                fallback = [d for d in days if d != day];
                blocks += place_hours(u, t, day, c, f"{t.title} ({k + 1}/{len(chunks)})", "peak", now, latest, f"{src}: split into blocks of <=2h, done the day before it is due", fallback);
            }
            if not self.quiet {
                self.out.append(f"Estimated {hm(t.est_hours)}, split into {len(chunks)} blocks, planned to finish by {pretty_day(finish)}");
            }
        } elif kind == "PROJECT" {
            days_left = max(1, (due.date() - now.date()).days);
            weekly = project_weekly_hours(t.est_hours, days_left);
            for (w, h) in enumerate(weekly) {
                start_day = now.date() + timedelta(days=7 * w);
                week_days = [start_day + timedelta(days=k) for k in range(7) if start_day + timedelta(days=k) < due.date()];
                if not week_days {
                    continue;
                }
                chunks = split_chunks(h, u.max_focus_min / 60.0);
                step = max(1, len(week_days) // max(1, len(chunks)));
                for (k, c) in enumerate(chunks) {
                    d0 = week_days[min(len(week_days) - 1, k * step)];
                    rest = [d for d in week_days if d != d0];
                    blocks += place_hours(u, t, d0, c, f"{t.title}: week {w + 1} progress", "peak", now, due - timedelta(hours=2), f"{src}: worked back from the milestone, a fixed block each week", rest);
                }
            }
            if not self.quiet {
                self.out.append(f"Estimated {hm(t.est_hours)} over {plural(len(weekly), 'week')}, about {hm(weekly[0])} per week");
            }
        } elif kind == "MEETING" {
            blocks += place_hours(u, t, due.date(), 0.5, f"{t.title}: prep", "peak", now, due - timedelta(minutes=15), f"{src}: prep before the meeting", [due.date() - timedelta(days=1)]);
        }

        for spec in reminder_chain(kind, t.title, due, now, u.wake_h) {
            add_reminder(t, spec.at, spec.message);
        }
        if blocks {
            t.status = TaskStatus.SCHEDULED;
        }
        missing = t.est_hours - sum([b.hours() for b in blocks]);
        if kind in ["EXAM", "ASSIGNMENT", "PROJECT"] and missing > 0.5 and not self.quiet {
            self.out.append(f"⚠️ About {hm(missing)} could not be fitted into free time. You may need to adjust your schedule");
        }
    }
}

def kind_for(i: Interest) -> TaskKind {
    if i.kind == InterestKind.HOBBY {
        return TaskKind.HOBBY;
    }
    if i.kind == InterestKind.HABIT {
        return TaskKind.HABIT;
    }
    return TaskKind.PRACTICE;
}

def default_pref(i: Interest) -> str {
    if i.preferred_time {
        return i.preferred_time;
    }
    if i.kind == InterestKind.HOBBY {
        return "low";
    }
    if i.kind == InterestKind.HABIT {
        return "morning";
    }
    return "peak";
}

walker plan_week {
    has week_start: str = "",           # Monday of the week "YYYY-MM-DD"; empty = this week
        verbose: bool = False,          # True: list the plan for every interest
        focus_names: list[str] = [],    # interests to report in detail (e.g. ones just added)
        out: list[str] = [],
        alloc: dict = {};

    can plan with User entry {
        u = here;
        now = u.now();
        now_s = fmt_dt(now);
        monday = week_monday(now.date()) if not self.week_start else date.fromisoformat(self.week_start);
        week_key = monday.isoformat();
        w_start = max(now, at(monday, 0));
        w_end = at(monday + timedelta(days=7), 0);
        w_end_s = fmt_dt(w_end);
        w_start_s = fmt_dt(at(monday, 0));

        # 1. only replan the future: remove this week's PLANNER tasks that have not started and are not locked
        covered: dict = {};
        kept_days: dict = {};
        for t in tasks_of(u) {
            i = interest_of(t);
            name = i.name if i is not None else "";
            bs = blocks_of(t);
            if not bs or not (w_start_s <= bs[0].start < w_end_s) {
                continue;
            }
            if t.origin == "PLANNER" {
                if t.is_open() and bs[0].start > now_s and not t.locked {
                    delete_task(t);
                    continue;
                }
                # done / in progress / locked this week count toward the interest's hours this week
                if t.status != TaskStatus.CANCELLED and not bs[0].skipped {
                    covered[name] = covered.get(name, 0.0) + sum([b.hours() for b in bs]);
                    kept_days.setdefault(name, []).append(to_dt(bs[0].start).date());
                }
            } elif t.is_rigid() and t.status != TaskStatus.CANCELLED {
                covered[name] = covered.get(name, 0.0) + sum([b.hours() for b in bs if w_start_s <= b.start < w_end_s]);
            }
        }

        # 2. capacity: the smaller of free time and comfortable load
        days_n = max(1, (w_end.date() - w_start.date()).days);
        free_h = free_hours(u, w_start, days_n);
        used = sum(covered.values());
        cap = max(float(cfg("min_hobby_h_per_week")), u.comfort_week_h - used);
        capacity = min(free_h, cap);

        exams = [t for t in tasks_of(u) if t.kind == TaskKind.EXAM and t.is_open() and t.due and now_s <= t.due < fmt_dt(max(w_end, now + timedelta(days=7)))];
        exam_week = len(exams) > 0;
        last_exam_day = max([to_dt(t.due).date() for t in exams]) if exams else None;

        active = [i for i in interests_of(u) if i.plannable()];
        alloc = allocate_hours(active, capacity, float(cfg("min_hobby_h_per_week")), exam_week, float(cfg("exam_week_hobby_ratio")), covered);
        self.alloc = alloc;

        # 3. generate concrete content and place it on the timeline
        days = [w_start.date() + timedelta(days=k) for k in range(days_n)];
        for i in sorted(active, key=lambda i: Interest : -priority(i)) {
            h = alloc.get(i.name, 0.0);
            total = round_half(h + covered.get(i.name, 0.0));
            prev = i.planned.get(week_key, -1.0);
            i.planned[week_key] = total;
            if h <= 0 {
                if prev > 0 and total < prev - 0.49 {
                    self.out.append(f"{i.label()} this week: {hm(prev)} → {hm(total) if total > 0 else '0'}");
                }
                continue;
            }
            recent = [t.title for t in tasks_of_interest(i) if t.status == TaskStatus.DONE][-5:];
            sessions = tasks_from_interest(i, h, u.max_focus_min, recent);
            pref = default_pref(i);
            cand_days = days;
            if i.kind == InterestKind.HABIT {
                # habits are once a day: skip days that already have one, and today if it is too late
                taken = kept_days.get(i.name, []);
                cand_days = [d for d in days if d not in taken and (d > now.date() or now.hour < u.sleep_h - 1)];
                sessions = sessions[:len(cand_days)];
                if not cand_days {
                    continue;
                }
            }
            after_exam = False;
            if exam_week and i.kind == InterestKind.HOBBY and last_exam_day is not None {
                later = [d for d in days if d > last_exam_day];
                if later {
                    cand_days = later;
                    after_exam = True;
                }
            }
            why = f"From the interest pool: \"{i.name}\" (weight {i.weight:.1f} · heat {i.heat:.2f}) · {PREF_LABEL.get(pref, '')}";
            if after_exam {
                why += " · squeezed for exam week, placed after the exam";
            }
            placed: list[StudyBlock] = [];
            used_days: list = [];
            n = len(sessions);
            for (k, s) in enumerate(sessions) {
                if i.kind == InterestKind.HABIT {
                    order = [cand_days[k % len(cand_days)]];
                } else {
                    idx = min(len(cand_days) - 1, int(math.floor(len(cand_days) * (k + 0.5) / n)));
                    rotated = cand_days[idx:] + cand_days[:idx];
                    order = [d for d in rotated if d not in used_days] + [d for d in rotated if d in used_days];
                }
                slot = None;
                for d in order {
                    slot = find_slot(u, d, s.minutes, pref, now);
                    if slot is None and s.minutes <= 30 {
                        # very short habits / practice ignore the daily cap
                        slot = find_slot(u, d, s.minutes, pref, now, None, False);
                    }
                    if slot is not None {
                        break;
                    }
                }
                if slot is None {
                    continue;
                }
                t = Task(id=board_of(u).new_id("t"), title=s.title, kind=kind_for(i), origin="PLANNER", est_hours=s.minutes / 60.0, created=now_s, status=TaskStatus.SCHEDULED);
                attach_task(u, t, i);
                label = s.title if i.name.lower() in s.title.lower() else f"{i.name}: {s.focus}";
                b = add_block(u, t, fmt_dt(slot[0]), fmt_dt(slot[1]), label, why);
                if i.kind == InterestKind.HABIT {
                    add_reminder(t, b.start, f"🔁 Time for {i.name} ({hm(b.hours())})");
                }
                placed.append(b);
                used_days.append(slot[0].date());
            }
            emit_event("planned", i.name, {"hours": h, "week": week_key}, "system");

            # 4. report (only when the total changes by >= 0.5h, to avoid noise)
            changed = prev >= 0 and abs(prev - total) >= 0.5;
            if self.verbose or i.name in self.focus_names or changed {
                if changed {
                    if after_exam and total < prev {
                        self.out.append(f"⚖️ Exam week: {i.name} squeezed from {hm(prev)} to {hm(total)} (placed after the exam)");
                    } else {
                        self.out.append(f"{i.label()} this week: {hm(prev)} → {hm(total)}");
                    }
                }
                if placed and (self.verbose or i.name in self.focus_names) {
                    placed = sorted(placed, key=lambda b: StudyBlock : b.start);
                    times = ", ".join([f"{weekday_name(to_dt(b.start))} {b.start[-5:]}" for b in placed]);
                    lens = set([b.hours() for b in placed]);
                    each = f", {hm(list(lens)[0])} each" if len(lens) == 1 else "";
                    prefix = f"{i.label()} " if self.verbose else "";
                    self.out.append(f"{prefix}Scheduled this week: {times}{each}");
                    steps: list[str] = [];
                    for b in placed {
                        step = b.focus.split(": ", 1)[-1];
                        if step not in steps {
                            steps.append(step);
                        }
                    }
                    if i.kind != InterestKind.HABIT {
                        self.out.append(f"{'  ' if self.verbose else ''}Plan: {' → '.join(steps[:4])}");
                    }
                }
                if len(placed) < n and i.kind != InterestKind.HABIT {
                    self.out.append(f"⚠️ Could not find a good time for {plural(n - len(placed), 'session')} of {i.name}");
                }
            }
        }
    }
}

"""User actions: task_action (user -> task) and update_interest (user -> interest pool).

Every action is written to the event bus; task status changes flow back to the interest pool along Feeds edges (the feedback walker).
"""

import from datetime { datetime, date, timedelta }
import from user.user { User, current_user, update_calibration }
import from interests.pool { Interest, InterestKind, InterestStatus, clamp01, Has }
import from tasks.task { Task, StudyBlock, TaskKind, TaskStatus }
import from tasks.slots { find_slot, scheduled_hours_on }
import from tasks.planner { plan_task, default_pref }
import from ai.classify { CancelReason, classify_cancel, REASON_LABEL }
import from ai.parse { InterestDraft, derive_aliases }
import from sync.feedback { feedback }
import from sync.events { emit_event }
import from common.graph { pool_of, board_of, tasks_of, blocks_of, interest_of, interests_of, find_interest, clear_future, tasks_of_interest }
import from common.timeutil { to_dt, fmt_dt, pretty, hm, weekday_name }

"""this morning / tonight / tomorrow evening / Wed afternoon"""
def rel_day(now: datetime, s: str) -> str {
    d = to_dt(s);
    diff = (d.date() - now.date()).days;
    part = "morning" if d.hour < 12 else ("afternoon" if d.hour < 18 else "evening");
    if diff == 0 {
        return "tonight" if part == "evening" else f"this {part}";
    }
    base = "tomorrow" if diff == 1 else weekday_name(d);
    return f"{base} {part}";
}

"""Move a block to the least loaded later day (too busy -> only reschedule)."""
def move_block(u: User, b: StudyBlock, pref: str, min_days: int = 1, max_days: int = 7, latest: datetime | None = None) -> bool {
    now = u.now();
    minutes = int(round(b.hours() * 60));
    base_day = max(now.date(), to_dt(b.start).date());
    cands = [base_day + timedelta(days=k) for k in range(min_days, max_days + 1)];
    cands = sorted(cands, key=lambda d: date : (scheduled_hours_on(u, d, b), d));
    for d in cands {
        slot = find_slot(u, d, minutes, pref, now, latest, True, b);
        if slot is not None {
            b.start = fmt_dt(slot[0]);
            b.end = fmt_dt(slot[1]);
            b.skipped = False;
            return True;
        }
    }
    return False;
}

walker task_action {
    has action: str,                  # done | cancel | postpone | quiz | lock | unlock
        block_id: str = "",
        reason_text: str = "",
        reason: CancelReason | None = None,
        actual_h: float = 0.0,
        days: int = 0,
        score: float = -1.0,
        wrong_topics: list[str] = [],
        out: list[str] = [],
        result: str = "";             # classification result / status for the caller

    can act with Task entry {
        u = current_user();
        now = u.now();
        now_s = fmt_dt(now);
        t = here;
        i = interest_of(t);

        if self.action == "lock" or self.action == "unlock" {
            t.locked = self.action == "lock";
            self.out.append(f"{'🔒 Locked' if t.locked else '🔓 Unlocked'}: {t.title}");
            disengage;
        }

        if self.action == "done" {
            blocks = blocks_of(t);
            if self.block_id {
                bs = [b for b in blocks if b.id == self.block_id];
                if bs {
                    bs[0].done = True;
                    self.out.append(f"✅ Done: {bs[0].focus}");
                }
                rest = [b for b in blocks_of(t) if not b.done and not b.skipped];
                if not t.is_rigid() and not rest {
                    t.status = TaskStatus.DONE;
                }
                if t.status == TaskStatus.TODO {
                    t.status = TaskStatus.DOING;
                }
            } else {
                t.status = TaskStatus.DONE;
                for b in blocks {
                    if b.start <= now_s and not b.skipped {
                        b.done = True;
                    }
                }
                if not t.is_rigid() {
                    for b in blocks {
                        b.done = True;
                    }
                }
                clear_future(t, now_s);
                self.out.append(f"✅ Done: {t.title}");
            }
            if self.actual_h > 0 {
                est = t.est_hours;
                if self.block_id {
                    bs = [b for b in blocks_of(t) if b.id == self.block_id];
                    est = bs[0].hours() if bs else est;
                }
                old = u.calib_of(t.kind.name);
                t.actual_hours += self.actual_h;
                new = update_calibration(u, t.kind.name, est, self.actual_h);
                self.out.append(f"⏱️ Actual {hm(self.actual_h)} / estimated {hm(est)}; {t.kind.name} calibration {old:.2f} → {new:.2f}");
            }
            ev = "block_done" if self.block_id else ("finished" if t.kind.name in ["EXAM", "PROJECT"] else "done");
            fb = t spawn feedback(event=ev);
            self.out += fb.out;
            emit_event("task_status", t.id, {"status": t.status.name, "rigid": t.is_rigid(), "kind": t.kind.name});
            self.result = "done";
        } elif self.action == "cancel" {
            r = self.reason if self.reason is not None else classify_cancel(t.title, self.reason_text);
            self.result = r.name;
            if self.reason_text {
                self.out.append(f"(Reason classified as: {REASON_LABEL[r.name]})");
            }
            if r == CancelReason.BUSY or r == CancelReason.BAD_ESTIMATE {
                if r == CancelReason.BAD_ESTIMATE {
                    old = u.calib_of(t.kind.name);
                    new = update_calibration(u, t.kind.name, 1.0, 1.5);
                    self.out.append(f"📐 Personal calibration updated ({t.kind.name}): {old:.2f} → {new:.2f}");
                }
                if t.is_rigid() {
                    t.est_hours = 0.0 if r == CancelReason.BAD_ESTIMATE else t.est_hours;
                    p = t spawn plan_task(quiet=True);
                    self.out.append("Rescheduled with the latest times" + (f"; next: {pretty(blocks_of(t)[0].start)}" if [b for b in blocks_of(t) if b.start > now_s] else ""));
                } else {
                    target = [b for b in blocks_of(t) if not b.done];
                    pref = default_pref(i) if i is not None else "low";
                    if target and move_block(u, target[0], pref) {
                        name = i.name if i is not None else t.title;
                        keep = f"{name} keeps its weight. " if r == CancelReason.BUSY else "";
                        self.out.append(f"Got it. {keep}Moved to {pretty(target[0].start)}");
                        t.status = TaskStatus.SCHEDULED;
                    } else {
                        t.status = TaskStatus.CANCELLED;
                        clear_future(t, now_s);
                        self.out.append("There's really no room this week, so this one is cancelled. Your interest pool is unchanged");
                    }
                }
                emit_event("reschedule", t.id, {"reason": r.name});
            } else {
                t.status = TaskStatus.CANCELLED;
                clear_future(t, now_s);
                self.out.append(f"Cancelled: {t.title}");
                if r == CancelReason.LOST_INTEREST or r == CancelReason.NOT_NEEDED {
                    fb = t spawn feedback(event="cancel", reason=r);
                    self.out += fb.out;
                    if r == CancelReason.NOT_NEEDED and i is not None {
                        rigid = [x for x in tasks_of_interest(i) if x.is_open() and x.is_rigid() and x.id != t.id];
                        if rigid {
                            self.out.append(f"\"{i.name}\" still has {len(rigid)} open rigid task(s): {', '.join([x.id for x in rigid])}. Use /cancel on each one if needed");
                        }
                    }
                }
                emit_event("task_status", t.id, {"status": "CANCELLED", "rigid": t.is_rigid(), "kind": t.kind.name, "reason": r.name});
            }
        } elif self.action == "postpone" {
            if t.is_rigid() and self.days > 0 and t.due {
                t.due = fmt_dt(to_dt(t.due) + timedelta(days=self.days));
                p = t spawn plan_task(quiet=True);
                self.out.append(f"Due date pushed to {pretty(t.due)} and rescheduled");
            } else {
                target = [b for b in blocks_of(t) if not b.done and not b.skipped];
                if self.block_id {
                    target = [b for b in target if b.id == self.block_id];
                }
                if not target {
                    self.out.append("No time block left to postpone");
                    disengage;
                }
                b = target[0];
                pref = default_pref(i) if i is not None else "peak";
                latest = to_dt(t.due) - timedelta(hours=1) if (t.is_rigid() and t.due) else None;
                if move_block(u, b, pref, max(1, self.days), max(7, self.days + 3), latest) {
                    self.out.append(f"Postponed to {pretty(b.start)}");
                } else {
                    self.out.append("⚠️ No new time found before the deadline, so the original plan stays");
                }
            }
            emit_event("reschedule", t.id, {"reason": "POSTPONE"});
        } elif self.action == "quiz" {
            if self.block_id {
                for b in blocks_of(t) {
                    if b.id == self.block_id {
                        b.done = True;
                    }
                }
            }
            if t.kind == TaskKind.QUIZ {
                t.status = TaskStatus.DONE;
            }
            fb = t spawn feedback(event="quiz", score=max(0.0, self.score), wrong_topics=self.wrong_topics);
            self.out += fb.out;
            # write the weak points into the next review block
            if self.wrong_topics and i is not None {
                nxt: list[StudyBlock] = [];
                for x in tasks_of_interest(i) {
                    if x.is_open() {
                        nxt += [b for b in blocks_of(x) if b.start > now_s and not b.done];
                    }
                }
                if nxt {
                    nb = sorted(nxt, key=lambda b: StudyBlock : b.start)[0];
                    if "focus:" not in nb.focus {
                        nb.focus = f"{nb.focus} (focus: {', '.join(self.wrong_topics)})";
                    }
                    nb.why = nb.why + " · adjusted for quiz mistakes";
                    what = "skim" if nb.hours() <= 0.5 else "review";
                    cnt = "these two topics" if len(self.wrong_topics) == 2 else ("this topic" if len(self.wrong_topics) == 1 else "these topics");
                    self.out.append(f"Your {hm(nb.hours())} {what} {rel_day(now, nb.start)} will focus on {cnt}.");
                }
            }
            emit_event("task_status", t.id, {"status": t.status.name, "rigid": t.is_rigid(), "kind": t.kind.name});
            self.result = "quiz";
        }
    }
}

walker update_interest {
    has op: str,           # add | weight_up | weight_down | set_weight | budget | time | short |
                           # pause | resume | archive | lock | unlock | confirm | reject
        name: str = "",
        draft: InterestDraft | None = None,
        value: float = 0.0,
        text: str = "",
        out: list[str] = [],
        interest: Interest | None = None,
        related: list[str] = [];    # on archive: ids of related future tasks (the caller asks whether to cancel them)

    can go with User entry {
        u = here;
        now_s = u.now_str();
        pool = pool_of(u);

        if self.op == "add" {
            d = self.draft;
            i = find_interest(u, d.name, True);
            if i is not None and i.name.lower() == d.name.lower() or (i is not None and i.matches(d.name)) {
                changed: list[str] = [];
                if i.status != InterestStatus.ACTIVE {
                    i.status = InterestStatus.ACTIVE;
                    changed.append("reactivated");
                }
                if d.weekly_budget_h > 0 and abs(d.weekly_budget_h - i.weekly_budget_h) > 1e-6 {
                    i.weekly_budget_h = d.weekly_budget_h;
                    i.budget_weight = i.weight;
                    changed.append(f"{hm(d.weekly_budget_h)}/week");
                }
                if d.preferred_time and d.preferred_time != i.preferred_time {
                    i.preferred_time = d.preferred_time;
                    changed.append("time preference updated");
                }
                self.interest = i;
                self.out.append(f"{i.label()} is already in your interest pool" + (f": {', '.join(changed)}" if changed else ""));
                emit_event("budget_changed", i.name, {});
                disengage;
            }
            i = Interest(
                name=d.name, kind=d.kind, weight=clamp01(d.weight), weekly_budget_h=max(0.0, d.weekly_budget_h),
                budget_weight=clamp01(d.weight), preferred_time=d.preferred_time, aliases=derive_aliases(d.name),
                created=now_s, heat_log=[[now_s[:10], 0.0]]
            );
            pool +>:Has:+> i;
            self.interest = i;
            budget = f", {hm(i.weekly_budget_h)}/week" if i.weekly_budget_h > 0 else "";
            self.out.append(f"Added to your interest pool: {i.label()} (weight {i.weight:.1f}{budget})");
            emit_event("interest_added", i.name, {"kind": i.kind.name});
            disengage;
        }

        i = find_interest(u, self.name, True);
        if i is None {
            self.out.append(f"\"{self.name}\" is not in your interest pool");
            disengage;
        }
        self.interest = i;
        before = i.weight;

        if self.op in ["weight_up", "weight_down", "set_weight"] {
            if self.op == "weight_up" {
                i.weight = round(clamp01(i.weight + 0.2), 3);
            } elif self.op == "weight_down" {
                i.weight = round(clamp01(i.weight - 0.2), 3);
            } else {
                i.weight = round(clamp01(self.value), 3);
            }
            self.out.append(f"{i.label()} weight {before:.1f} → {i.weight:.1f}");
            emit_event("interest_changed", i.name, {"field": "weight", "before": before, "after": i.weight, "cause": "user"});
        } elif self.op == "budget" {
            i.weekly_budget_h = max(0.0, self.value);
            i.budget_weight = i.weight;
            self.out.append(f"{i.label()} weekly time set to {hm(i.weekly_budget_h)}");
            emit_event("budget_changed", i.name, {"hours": i.weekly_budget_h});
        } elif self.op == "time" {
            i.preferred_time = self.text;
            when = {"morning": "in the morning", "afternoon": "in the afternoon", "evening": "in the evening"}.get(self.text, "at any time");
            self.out.append(f"{i.label()} will be scheduled {when} from now on");
            emit_event("budget_changed", i.name, {});
        } elif self.op == "short" {
            i.session_min = int(self.value);
            self.out.append(f"{i.label()} switched to short {int(self.value)}-minute sessions");
            emit_event("budget_changed", i.name, {});
        } elif self.op in ["pause", "resume", "archive"] {
            old = i.status.name;
            i.status = {"pause": InterestStatus.PAUSED, "resume": InterestStatus.ACTIVE, "archive": InterestStatus.ARCHIVED}[self.op];
            msg = {"pause": "⏸️ paused; nothing new will be scheduled for it", "resume": "▶️ resumed", "archive": "🗄️ archived"}[self.op];
            self.out.append(f"{i.label()} {msg}");
            if self.op == "archive" {
                self.related = [t.id for t in tasks_of_interest(i) if t.is_open() and t.is_rigid()];
            }
            emit_event("interest_status", i.name, {"field": "status", "before": old, "after": i.status.name, "cause": "user"});
        } elif self.op in ["lock", "unlock"] {
            i.locked = self.op == "lock";
            self.out.append(f"{'🔒 Locked' if i.locked else '🔓 Unlocked'}: {i.label()} (automatic updates leave locked items alone)");
        } elif self.op == "confirm" {
            i.confirmed = True;
            i.status = InterestStatus.ACTIVE;
            self.out.append(f"Added to your interest pool: {i.label()}");
            emit_event("interest_added", i.name, {"kind": i.kind.name, "derived": True});
        } elif self.op == "reject" {
            i.status = InterestStatus.ARCHIVED;
            if i.name not in pool.rejected {
                pool.rejected.append(i.name);
            }
            self.out.append(f"OK, I won't suggest \"{i.name}\" again");
        }
    }
}

"""Mark every block that has already started today as done (/done today, "all done for today")."""
def complete_today(u: User) -> list[str] {
    now_s = u.now_str();
    today = now_s[:10];
    done: list[str] = [];
    for t in [x for x in tasks_of(u) if x.is_open()] {
        for b in blocks_of(t) {
            if b.start[:10] == today and b.start <= now_s and not b.done and not b.skipped {
                t spawn task_action(action="done", block_id=b.id);
                done.append(b.focus.split(" (")[0]);
            }
        }
    }
    if not done {
        return ["Nothing scheduled so far today"];
    }
    return [f"✅ Finished {len(done)} item(s) today: {', '.join(done)}", "Heat updated for the related interests 🔥"];
}

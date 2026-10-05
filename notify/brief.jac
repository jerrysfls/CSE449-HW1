"""Daily brief (task -> user), profile digest (interest pool -> user), plus the interest pool / week views."""

import from datetime { timedelta }
import from ai.llm { llm, ai_enabled, ai_failed, ai_ok }
import from user.user { User }
import from interests.pool { Interest, InterestKind, InterestStatus, flames, KIND_LABEL }
import from interests.dynamics { priority, effective_budget }
import from tasks.task { Task, TaskStatus, TaskKind }
import from tasks.slots { load_stats }
import from common.graph { tasks_of, blocks_of, interests_of, interest_of, tasks_of_interest }
import from common.timeutil { to_dt, fmt_dt, pretty, pretty_day, hm, weekday_name, days_until, round_q, plural }

"""Based on the profile facts, give 2-4 gentle, short suggestions in English (one sentence each)."""
def llm_digest_advice(facts: list[str]) -> list[str] by llm();

def days_since(now_s: str, s: str) -> int {
    if not s {
        return -1;
    }
    return (to_dt(now_s).date() - to_dt(s).date()).days;
}

walker daily_brief {
    has out: list[str] = [];

    can run with User entry {
        u = here;
        now = u.now();
        now_s = fmt_dt(now);
        today = now.date();
        hi = "Good morning" if now.hour < 12 else ("Good afternoon" if now.hour < 18 else "Good evening");
        self.out.append(f"☀️ {hi}! {pretty_day(today)}");
        self.out.append("");

        items: list[tuple] = [];
        for t in tasks_of(u) {
            if t.status == TaskStatus.CANCELLED {
                continue;
            }
            if t.due and to_dt(t.due).date() == today and t.is_rigid() {
                mark = " ✅" if t.status == TaskStatus.DONE else "";
                verb = "due" if t.kind.name in ["ASSIGNMENT", "PROJECT"] else "";
                items.append((t.due[-5:], f"{t.icon()} {t.title} {verb}{mark}".rstrip()));
            }
            for b in blocks_of(t) {
                if to_dt(b.start).date() == today {
                    mark = " ✅" if b.done else (" ⏭️" if b.skipped else "");
                    items.append((b.start[-5:], f"{b.focus} ({hm(b.hours())}){mark}"));
                }
            }
        }
        self.out.append("📌 Today");
        if items {
            for (hh, txt) in sorted(items, key=lambda x: tuple : x[0]) {
                self.out.append(f"  {hh}  {txt}");
            }
        } else {
            self.out.append("  Nothing scheduled today. Get some rest 🌿");
        }

        self.out.append("");
        self.out.append("📊 Interest pool");
        exams_soon = [t for t in tasks_of(u) if t.kind == TaskKind.EXAM and t.is_open() and t.due and 0 <= days_until(now, t.due) <= 7];
        for i in sorted([i for i in interests_of(u) if i.plannable()], key=lambda i: Interest : -priority(i)) {
            parts: list[str] = [];
            if i.kind == InterestKind.STUDY {
                arrow = "";
                if i.mastery_prev >= 0 and abs(i.mastery - i.mastery_prev) > 1e-6 {
                    arrow = " ↑" if i.mastery > i.mastery_prev else " ↓";
                }
                parts.append(f"mastery {i.mastery:.2f}{arrow}");
            }
            note = "";
            ds = days_since(now_s, i.last_active);
            if ds >= 4 and i.kind in [InterestKind.HOBBY, InterestKind.HABIT] {
                later = "; catch up after exams?" if exams_soon else "";
                note = f" (idle for {ds} days{later})";
            }
            parts.append(f"heat {flames(i.heat)}{note}");
            self.out.append(f"  {i.label():<22} {'   '.join(parts)}");
        }

        upcoming = sorted([t for t in tasks_of(u) if t.is_open() and t.is_rigid() and t.due and 0 < days_until(now, t.due) <= 7], key=lambda t: Task : t.due);
        if upcoming {
            self.out.append("");
            for t in upcoming[:3] {
                d = to_dt(t.due);
                self.out.append(f"⏰ Coming up: {d.month}/{d.day} {t.title} (in {plural(days_until(now, t.due), 'day')})");
            }
        }
        st = load_stats(u);
        if st["week_h"] > u.comfort_week_h {
            self.out.append(f"⚠️ Load warning: {hm(st['week_h'])} scheduled this week, above your comfort zone ({hm(u.comfort_week_h)})");
        }
        if st["high_load_streak"] >= 3 {
            self.out.append(f"⚠️ {st['high_load_streak']} heavy days in a row. Remember to leave some time to rest");
        }
        pending = [i for i in interests_of(u) if i.source == "DERIVED" and not i.confirmed];
        for i in pending {
            self.out.append(f"💡 New interest to confirm: \"{i.name}\" (/confirm {i.name} or /reject {i.name})");
        }
        u.last_brief_day = today.isoformat();
    }
}

walker profile_digest {
    has out: list[str] = [],
        facts: list[str] = [];

    can run with User entry {
        u = here;
        now = u.now();
        now_s = fmt_dt(now);
        st = load_stats(u);
        self.out.append(f"🧭 Profile digest for {u.name}");
        self.out.append(f"  Scheduled this week {hm(st['week_h'])} / comfort zone {hm(u.comfort_week_h)} · 2-week completion {int(st['completion'] * 100)}%");
        if u.calib {
            cal = ", ".join([f"{k} ×{v:.2f}" for (k, v) in u.calib.items()]);
            self.out.append(f"  Personal calibration: {cal}");
        }
        advice: list[str] = [];
        for i in interests_of(u) {
            if not i.plannable() {
                continue;
            }
            week_done = 0.0;
            for t in tasks_of_interest(i) {
                for b in blocks_of(t) {
                    if b.done and 0 <= (now - to_dt(b.start)).days < 7 {
                        week_done += b.hours();
                    }
                }
            }
            trend = heat_trend(i, now_s);
            goal = round_q(effective_budget(i));
            fact = f"{i.name} ({KIND_LABEL[i.kind.name]}): weight {i.weight:.1f}, heat {i.heat:.2f}, last 7 days {hm(week_done) if week_done > 0 else '0'}, weekly goal {hm(goal) if goal > 0 else 'not set'}";
            if i.kind == InterestKind.STUDY {
                fact += f", mastery {i.mastery:.2f}";
                if i.weak_points {
                    fact += f", weak points: {', '.join(i.weak_points[:3])}";
                }
            }
            if trend {
                fact += f", {trend}";
            }
            if i.skip_streak >= 2 {
                fact += f", skipped {i.skip_streak} times in a row";
            }
            self.facts.append(fact);
            self.out.append(f"  {i.icon()} {fact}");
            if "dropping" in trend and i.kind in [InterestKind.HOBBY, InterestKind.HABIT, InterestKind.GOAL] {
                advice.append(f"{i.name}: {trend}. Lower its weight, or switch to shorter sessions? (/weight {i.name} 0.4 or /short {i.name} 20)");
            } elif i.skip_streak >= 2 {
                advice.append(f"You keep skipping \"{i.name}\". Maybe the timing is off? Try /when {i.name} evening");
            } elif i.kind == InterestKind.STUDY and i.mastery < 0.5 {
                advice.append(f"\"{i.name}\" mastery is low ({i.mastery:.2f}), so the next review gets extra time");
            }
        }
        if st["week_h"] > u.comfort_week_h {
            advice.append("This week is pretty packed. Consider pausing one or two interests (/pause) so you don't burn out.");
        }
        if ai_enabled() and self.facts {
            try {
                extra = llm_digest_advice(self.facts);
                ai_ok();
                if extra {
                    advice = [str(a) for a in extra][:4];
                }
            } except Exception as e {
                ai_failed(e);
            }
        }
        if advice {
            self.out.append("");
            self.out.append("💬 Suggestions");
            for a in advice[:4] {
                self.out.append(f"  · {a}");
            }
        }
    }
}

"""Heat trend over the last 3 weeks, from heat_log."""
def heat_trend(i: Interest, now_s: str) -> str {
    if len(i.heat_log) < 3 {
        return "";
    }
    now_d = to_dt(now_s).date();
    points: list[float] = [];
    for w in [21, 14, 7, 0] {
        target = (now_d - timedelta(days=w)).isoformat();
        vals = [p[1] for p in i.heat_log if p[0] <= target];
        if vals {
            points.append(vals[-1]);
        }
    }
    if len(points) >= 3 and all([points[k] > points[k + 1] for k in range(len(points) - 1)]) {
        return f"heat has been dropping for {len(points) - 1} weeks";
    }
    if len(points) >= 3 and all([points[k] < points[k + 1] for k in range(len(points) - 1)]) {
        return f"heat has been rising for {len(points) - 1} weeks";
    }
    return "";
}

def render_pool(u: User) -> list[str] {
    out = ["📊 Interest pool"];
    items = interests_of(u, True);
    if not items {
        return out + ["  (empty) Tell me what you're busy with and what you enjoy"];
    }
    for i in sorted(items, key=lambda i: Interest : (i.status.value, -priority(i))) {
        tags: list[str] = [];
        if i.status != InterestStatus.ACTIVE {
            tags.append(i.status.name);
        }
        if i.source == "DERIVED" and not i.confirmed {
            tags.append("to confirm");
        }
        if i.locked {
            tags.append("🔒");
        }
        tag = f" [{' '.join(tags)}]" if tags else "";
        goal = round_q(effective_budget(i));
        budget = f" · {hm(goal)}/week" if goal > 0 else "";
        mast = f" · mastery {i.mastery:.2f}" if i.kind == InterestKind.STUDY else "";
        weak = f" · weak: {', '.join(i.weak_points[:3])}" if i.weak_points else "";
        out.append(f"  {i.label()}{tag}  weight {i.weight:.2f} · heat {i.heat:.2f} {flames(i.heat)}{mast}{budget}{weak}");
    }
    return out;
}

def render_week(u: User, days: int = 7, show_why: bool = False) -> list[str] {
    now = u.now();
    today = now.date();
    out = [f"📅 Next {days} days"];
    by_day: dict = {};
    for t in tasks_of(u) {
        if t.status == TaskStatus.CANCELLED {
            continue;
        }
        if t.due and t.is_rigid() {
            d = to_dt(t.due).date();
            if 0 <= (d - today).days < days {
                by_day.setdefault(d, []).append((t.due[-5:], f"{t.icon()} [{t.id}] {t.title}{' due' if t.kind.name in ['ASSIGNMENT', 'PROJECT'] else ''}", ""));
            }
        }
        for b in blocks_of(t) {
            d = to_dt(b.start).date();
            if 0 <= (d - today).days < days {
                mark = " ✅" if b.done else (" ⏭️" if b.skipped else "");
                lock = " 🔒" if t.locked else "";
                by_day.setdefault(d, []).append((b.start[-5:], f"[{b.id}] {b.focus} ({hm(b.hours())}){mark}{lock}", b.why));
            }
        }
    }
    if not by_day {
        return out + ["  (empty)"];
    }
    for d in sorted(by_day.keys()) {
        out.append(f"  {pretty_day(d)}" + (" · today" if d == today else ""));
        for (hh, txt, why) in sorted(by_day[d], key=lambda x: tuple : x[0]) {
            out.append(f"    {hh}  {txt}");
            if show_why and why {
                out.append(f"           ↳ {why}");
            }
        }
    }
    return out;
}

def render_tasks(u: User) -> list[str] {
    out = ["🗂️ Tasks"];
    open_ = [t for t in tasks_of(u) if t.is_open()];
    if not open_ {
        return out + ["  (no open tasks)"];
    }
    rigid = sorted([t for t in open_ if t.is_rigid()], key=lambda t: Task : t.due or "9");
    flex = sorted([t for t in open_ if not t.is_rigid()], key=lambda t: Task : (blocks_of(t)[0].start if blocks_of(t) else "9"));
    for t in rigid {
        i = interest_of(t);
        src = f" ← {i.label()}" if i is not None else "";
        lock = " 🔒" if t.locked else "";
        out.append(f"  {t.summary()}{src}{lock}");
        for b in blocks_of(t) {
            if not b.done and not b.skipped {
                out.append(f"      {b.summary()}");
            }
        }
    }
    for t in flex {
        bs = blocks_of(t);
        when = f" · {pretty(bs[0].start)}" if bs else "";
        i = interest_of(t);
        src = f" ← {i.label()}" if i is not None else "";
        lock = " 🔒" if t.locked else "";
        out.append(f"  [{t.id}] {t.icon()} {t.title}{when}{src}{lock}");
    }
    return out;
}

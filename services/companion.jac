"""Server endpoints for the web / mobile app (mounted by app.jac, `jac start app.jac`).

Every endpoint is a plain `def` that requires login: each account has its own
User graph under its own root (the same data structure as the CLI). UI buttons all become the same commands as the CLI
(/done b12, /weight Guitar 0.7, /time +1d ...) and go through user.session.handle_turn,
so the CLI, web and mobile app behave exactly the same.
"""

import from datetime { datetime, timedelta }
import from user.user { User, set_current_user }
import from user.session { Turn, handle_turn, refresh_state, digest_lines, CANCEL_ASK }
import from interests.pool { Interest, InterestKind, InterestStatus, flames, KIND_LABEL }
import from interests.dynamics { priority, effective_budget }
import from tasks.task { Task, StudyBlock, TaskStatus, TASK_LABEL }
import from tasks.slots { load_stats }
import from ai.llm { ai_enabled, ai_status }
import from data.seed { seed_demo }
import from common.graph { bootstrap, tasks_of, blocks_of, interests_of, interest_of }
import from common.timeutil { to_dt, fmt_dt, pretty, pretty_day, hm, days_until, round_q, plural }

# ---------- view objects returned to the UI ----------

"""One schedule item: a time block (block), or a rigid task's due point (due)."""
obj ItemView {
    has id: str = "",
        task_id: str = "",
        kind: str = "block",
        start: str = "",
        time: str = "",
        end: str = "",
        title: str = "",
        icon: str = "",
        duration: str = "",
        hours: float = 0.0,
        done: bool = False,
        skipped: bool = False,
        past: bool = False,
        locked: bool = False,
        quiz: bool = False,
        why: str = "",
        interest: str = "";
}

obj DayView {
    has date: str = "",
        label: str = "",
        is_today: bool = False,
        hours: str = "",
        items: list[ItemView] = [];
}

obj InterestView {
    has name: str = "",
        kind: str = "",
        kind_label: str = "",
        icon: str = "",
        weight: float = 0.5,
        heat: float = 0.0,
        flames: str = "",
        mastery: float = 0.5,
        is_study: bool = False,
        budget: str = "",              # actual weekly allocation (affected by weight)
        budget_h: float = 0.0,         # weekly hours set by the user
        session_min: int = 0,
        status: str = "ACTIVE",
        pending: bool = False,
        locked: bool = False,
        weak_points: list[str] = [],
        preferred_time: str = "",
        idle_days: int = -1;
}

obj TaskView {
    has id: str = "",
        title: str = "",
        icon: str = "",
        kind: str = "",
        kind_label: str = "",
        due: str = "",
        due_label: str = "",
        days_left: int = 0,
        status: str = "",
        locked: bool = False,
        rigid: bool = False,
        interest: str = "",
        est: str = "",
        blocks_left: int = 0,
        next_block: str = "";
}

obj Msg {
    has style: str = "say", lines: list[str] = [];
}

obj Dashboard {
    has name: str = "",
        now: str = "",
        now_label: str = "",
        greeting: str = "",
        simulated: bool = False,
        ai_on: bool = False,
        ai: str = "",
        fresh: bool = False,
        today: list[ItemView] = [],
        today_done: int = 0,
        today_total: int = 0,
        week: list[DayView] = [],
        interests: list[InterestView] = [],
        tasks: list[TaskView] = [],
        upcoming: list[TaskView] = [],
        alerts: list[str] = [],
        notices: list[Msg] = [],
        question: str = "",
        derived: list[str] = [],
        week_h: str = "",
        comfort_h: str = "",
        load_pct: int = 0,
        completion: int = 0;
}

obj Reply {
    has messages: list[Msg] = [],
        asking: bool = False,
        dash: Dashboard | None = None;
}

# ---------- view builders (functions starting with _ are not exposed as endpoints) ----------

"""The current account's User; created on first access."""
def _user() -> User {
    users = [root -->][?:User];
    if users {
        set_current_user(users[0]);
        return users[0];
    }
    return bootstrap("friend");
}

def _item_of_block(t: Task, b: StudyBlock, now_s: str) -> ItemView {
    i = interest_of(t);
    return ItemView(
        id=b.id, task_id=t.id, kind="block", start=b.start, time=b.start[-5:], end=b.end[-5:],
        title=b.focus, icon=t.icon(), duration=hm(b.hours()), hours=b.hours(), done=b.done,
        skipped=b.skipped, past=b.end <= now_s, locked=t.locked, quiz="quiz" in b.focus.lower(),
        why=b.why, interest=i.name if i is not None else ""
    );
}

def _item_of_due(t: Task, now_s: str) -> ItemView {
    verb = " due" if t.kind.name in ["ASSIGNMENT", "PROJECT"] else "";
    i = interest_of(t);
    return ItemView(
        id=t.id, task_id=t.id, kind="due", start=t.due, time=t.due[-5:], title=f"{t.title}{verb}",
        icon=t.icon(), done=t.status == TaskStatus.DONE, past=t.due <= now_s, locked=t.locked,
        interest=i.name if i is not None else ""
    );
}

def _by_start(x: ItemView) -> str {
    return x.start;
}

"""Schedule for the next `days` days (including today), grouped by day."""
def _days(u: User, days: int) -> list[DayView] {
    now = u.now();
    now_s = fmt_dt(now);
    today = now.date();
    buckets: dict = {};
    for t in tasks_of(u) {
        if t.status == TaskStatus.CANCELLED {
            continue;
        }
        if t.due and t.is_rigid() {
            d = to_dt(t.due).date();
            if 0 <= (d - today).days < days {
                buckets.setdefault(d, []).append(_item_of_due(t, now_s));
            }
        }
        for b in blocks_of(t) {
            d = to_dt(b.start).date();
            if 0 <= (d - today).days < days {
                buckets.setdefault(d, []).append(_item_of_block(t, b, now_s));
            }
        }
    }
    out: list[DayView] = [];
    for k in range(days) {
        d = today + timedelta(days=k);
        raw_items = buckets.get(d, []) as list[ItemView];
        items = sorted(raw_items, key=_by_start);
        total = sum([x.hours for x in items if not x.skipped]);
        out.append(DayView(date=d.isoformat(), label=pretty_day(d), is_today=k == 0, hours=hm(total) if total > 0 else "", items=items));
    }
    return out;
}

def _r2(x: float) -> float {
    return int(x * 100 + 0.5) / 100.0;
}

def _interest_view(i: Interest, now_s: str) -> InterestView {
    goal = round_q(effective_budget(i));
    idle = (to_dt(now_s).date() - to_dt(i.last_active).date()).days if i.last_active else -1;
    return InterestView(
        name=i.name, kind=i.kind.name, kind_label=str(KIND_LABEL[i.kind.name]), icon=i.icon(),
        weight=_r2(i.weight), heat=_r2(i.heat), flames=flames(i.heat), mastery=_r2(i.mastery),
        is_study=i.kind == InterestKind.STUDY, budget=hm(goal) if goal > 0 else "", budget_h=i.weekly_budget_h,
        session_min=i.session_min, status=i.status.name,
        pending=i.source == "DERIVED" and not i.confirmed, locked=i.locked, weak_points=list(i.weak_points[:4]),
        preferred_time=i.preferred_time, idle_days=idle
    );
}

def _task_view(t: Task, now: datetime) -> TaskView {
    i = interest_of(t);
    left = [b for b in blocks_of(t) if not b.done and not b.skipped];
    return TaskView(
        id=t.id, title=t.title, icon=t.icon(), kind=t.kind.name, kind_label=str(TASK_LABEL[t.kind.name]),
        due=t.due, due_label=pretty(t.due) if t.due else "", days_left=days_until(now, t.due) if t.due else 0,
        status=t.status.name, locked=t.locked, rigid=t.is_rigid(), interest=i.name if i is not None else "",
        est=hm(t.est_hours) if t.est_hours > 0 else "", blocks_left=len(left),
        next_block=pretty(left[0].start) if left else ""
    );
}

def _by_priority(i: Interest) -> float {
    return -priority(i);
}

def _by_due(t: Task) -> str {
    return t.due or "9";
}

def _question(u: User) -> str {
    p = u.pending;
    if not p {
        return "";
    }
    if p.get("type") == "cancel_reason" {
        return CANCEL_ASK;
    }
    ids = p.get("ids", []) as list;
    return f"\"{p.get('name', '')}\" still has {plural(len(ids), 'upcoming task')}. Cancel them too?";
}

def _dashboard(u: User, notices: list[Msg] = []) -> Dashboard {
    now = u.now();
    now_s = fmt_dt(now);
    week = _days(u, 7);
    today_items = week[0].items;
    blocks_today = [x for x in today_items if x.kind == "block"];
    st = load_stats(u);
    week_h = st["week_h"] as float;

    items = interests_of(u, True);
    active = sorted([i for i in items if i.status == InterestStatus.ACTIVE], key=_by_priority);
    rest = [i for i in items if i.status != InterestStatus.ACTIVE];
    open_tasks = sorted([t for t in tasks_of(u) if t.is_open()], key=_by_due);
    upcoming = [t for t in open_tasks if t.is_rigid() and t.due and 0 <= days_until(now, t.due) <= 7];

    alerts: list[str] = [];
    if week_h > u.comfort_week_h {
        alerts.append(f"{hm(week_h)} scheduled this week, above your comfort zone ({hm(u.comfort_week_h)}). Consider pausing an interest or two");
    }
    if st["high_load_streak"] >= 3 {
        alerts.append(f"{st['high_load_streak']} heavy days in a row. Remember to leave some time to rest");
    }
    for i in items {
        if i.status == InterestStatus.ACTIVE and i.kind in [InterestKind.HOBBY, InterestKind.HABIT] and i.last_active {
            idle = (now.date() - to_dt(i.last_active).date()).days;
            if idle >= 4 {
                alerts.append(f"{i.label()}: no practice for {idle} days");
            }
        }
    }
    ordered = active + rest;
    hi = "Good morning" if now.hour < 12 else ("Good afternoon" if now.hour < 18 else "Good evening");
    return Dashboard(
        name=u.name, now=now_s, now_label=pretty(now_s), greeting=f"{hi}, {u.name}", simulated=bool(u.clock),
        ai_on=ai_enabled(), ai=ai_status(), fresh=not items and not tasks_of(u),
        today=today_items, today_done=len([x for x in blocks_today if x.done]), today_total=len(blocks_today),
        week=week, interests=[_interest_view(i, now_s) for i in ordered],
        tasks=[_task_view(t, now) for t in open_tasks], upcoming=[_task_view(t, now) for t in upcoming],
        alerts=alerts, notices=notices, question=_question(u), derived=list(u.derived),
        week_h=hm(week_h) if week_h > 0 else "0h", comfort_h=hm(u.comfort_week_h),
        load_pct=int(min(100.0, 100.0 * week_h / max(1.0, u.comfort_week_h))),
        completion=int((st["completion"] as float) * 100)
    );
}

def _msgs(t: Turn) -> list[Msg] {
    return [Msg(style=s.style, lines=list(s.lines)) for s in t.segments];
}

# ---------- endpoints ----------

"""Home data: sync first (time passing, missed blocks, reminders), then return every view."""
def get_dashboard() -> Dashboard {
    u = _user();
    (sync_out, remind_out) = refresh_state(u);
    notices: list[Msg] = [];
    if sync_out {
        notices.append(Msg(style="more", lines=sync_out));
    }
    if remind_out {
        notices.append(Msg(style="raw", lines=remind_out));
    }
    return _dashboard(u, notices);
}

"""Send a sentence or a command (exactly like CLI input)."""
def send_message(text: str) -> Reply {
    u = _user();
    t = handle_turn(u, text);
    nu = t.user if t.user is not None else u;
    set_current_user(nu);
    return Reply(messages=_msgs(t), asking=t.asking, dash=_dashboard(nu));
}

"""Profile digest (may call the LLM, so it is loaded separately)."""
def get_digest() -> list[str] {
    return digest_lines(_user());
}

"""First run: set a display name and optionally load sample data."""
def setup_profile(name: str, demo: bool) -> Dashboard {
    u = _user();
    if name.strip() {
        u.name = name.strip()[:20];
    }
    if demo and not tasks_of(u) {
        seed_demo(u);
    }
    return _dashboard(u);
}

"""Free-time computation: daily routine window - occupied blocks - the rigid events themselves (exams / meetings)."""

import from datetime { datetime, date, timedelta }
import from user.user { User }
import from tasks.task { Task, StudyBlock, TaskStatus }
import from common.graph { tasks_of, blocks_of }
import from common.timeutil { to_dt, fmt_dt, at, week_monday }
import from common.config { cfg }

glob EVENT_MINUTES: dict = {"EXAM": 120, "QUIZ": 30, "MEETING": 60};

"""Tasks generated from the interest pool that have not started and are not locked: the next plan_week reschedules them."""
def is_replannable(t: Task) -> bool {
    return t.origin == "PLANNER" and t.is_open() and not t.locked;
}

"""Occupied intervals on a given day [(start, end), ...]."""
def busy_intervals(u: User, day: date, exclude: StudyBlock | None = None, flex_ok: bool = False) -> list[tuple] {
    out: list[tuple] = [];
    for t in tasks_of(u) {
        if t.status == TaskStatus.CANCELLED or (flex_ok and is_replannable(t)) {
            continue;
        }
        if t.kind.name in EVENT_MINUTES and t.due {
            s = to_dt(t.due);
            if s.date() == day {
                out.append((s, s + timedelta(minutes=EVENT_MINUTES[t.kind.name])));
            }
        }
        for b in blocks_of(t) {
            if b.skipped or (exclude is not None and b.id == exclude.id) {
                continue;
            }
            s = to_dt(b.start);
            if s.date() == day {
                out.append((s, to_dt(b.end)));
            }
        }
    }
    return sorted(out, key=lambda x: tuple : x[0]);
}

"""Hours of study / practice already scheduled on a day."""
def scheduled_hours_on(u: User, day: date, exclude: StudyBlock | None = None, flex_ok: bool = False) -> float {
    total = 0.0;
    for t in tasks_of(u) {
        if t.status == TaskStatus.CANCELLED or (flex_ok and is_replannable(t)) {
            continue;
        }
        for b in blocks_of(t) {
            if not b.skipped and to_dt(b.start).date() == day and (exclude is None or b.id != exclude.id) {
                total += b.hours();
            }
        }
    }
    return total;
}

"""Free windows on a day (time before not_before removed), with a 15-minute buffer around each window."""
def free_windows(u: User, day: date, not_before: datetime, exclude: StudyBlock | None = None, flex_ok: bool = False) -> list[tuple] {
    start = at(day, u.wake_h);
    end = at(day, u.sleep_h);
    if not_before > start {
        # round up to the next half hour
        nb = not_before + timedelta(minutes=(30 - not_before.minute % 30) % 30);
        start = nb.replace(second=0, microsecond=0);
    }
    if start >= end {
        return [];
    }
    windows: list[tuple] = [];
    cur = start;
    for (s, e) in busy_intervals(u, day, exclude, flex_ok) {
        s2 = s - timedelta(minutes=15);
        e2 = e + timedelta(minutes=15);
        if s2 > cur {
            windows.append((cur, min(s2, end)));
        }
        if e2 > cur {
            cur = e2;
        }
        if cur >= end {
            break;
        }
    }
    if cur < end {
        windows.append((cur, end));
    }
    return [(s, e) for (s, e) in windows if e > s];
}

"""Score a time-of-day preference. peak: high-focus hours; low: low-energy hours; morning / afternoon / evening: user-chosen."""
def pref_score(u: User, start: datetime, pref: str) -> float {
    h = start.hour;
    if pref == "peak" {
        # daytime is often taken by classes, so among peak hours lean slightly toward the evening
        if h in u.peak_hours {
            return 3.0 if h >= 18 else 2.5;
        }
        return 1.0 if 19 <= h <= 21 else 0.0;
    }
    if pref == "morning" {
        return 3.0 if 6 <= h < 12 else 0.0;
    }
    if pref == "afternoon" {
        return 3.0 if 12 <= h < 18 else 0.0;
    }
    if pref == "evening" {
        return 3.0 if 19 <= h < 23 else (1.0 if h == 18 else 0.0);
    }
    if pref == "low" {
        # low-energy slots: outside peak hours; early afternoon and evening fit best
        base = 0.0 if h in u.peak_hours else 2.0;
        return base + (1.0 if (13 <= h <= 16 or h >= 19) else 0.0);
    }
    return 0.0;
}

"""Find a slot of `minutes` minutes on a day; returns (start, end) or None."""
def find_slot(u: User, day: date, minutes: int, pref: str, not_before: datetime, latest_end: datetime | None = None, respect_cap: bool = True, exclude: StudyBlock | None = None, flex_ok: bool = False) -> tuple | None {
    if respect_cap and scheduled_hours_on(u, day, exclude, flex_ok) + minutes / 60.0 > float(cfg("daily_cap_h")) {
        return None;
    }
    best = None;
    best_score = -1.0;
    dur = timedelta(minutes=minutes);
    for (ws, we) in free_windows(u, day, not_before, exclude, flex_ok) {
        cand = ws;
        while cand + dur <= we {
            if latest_end is not None and cand + dur > latest_end {
                break;
            }
            sc = pref_score(u, cand, pref);
            if sc > best_score {
                (best, best_score) = ((cand, cand + dur), sc);
            }
            cand = cand + timedelta(minutes=30);
        }
    }
    return best;
}

"""Free hours within `days` days from start (subject to the daily cap)."""
def free_hours(u: User, start: datetime, days: int = 7) -> float {
    total = 0.0;
    cap = float(cfg("daily_cap_h"));
    for k in range(days) {
        day = start.date() + timedelta(days=k);
        win = sum([(e - s).total_seconds() / 3600.0 for (s, e) in free_windows(u, day, start)]);
        room = max(0.0, cap - scheduled_hours_on(u, day));
        total += min(win, room);
    }
    return total;
}

"""Load stats: hours scheduled this week, completion rate, consecutive high-load days."""
def load_stats(u: User) -> dict {
    now = u.now();
    monday = week_monday(now.date());
    week_h = 0.0;
    (done_n, skip_n) = (0, 0);
    per_day: dict = {};
    for t in tasks_of(u) {
        if t.status == TaskStatus.CANCELLED {
            continue;
        }
        for b in blocks_of(t) {
            d = to_dt(b.start).date();
            if b.skipped {
                skip_n += 1;
                continue;
            }
            if monday <= d < monday + timedelta(days=7) {
                week_h += b.hours();
            }
            per_day[d] = per_day.get(d, 0.0) + b.hours();
            if b.done and (now.date() - d).days <= 14 {
                done_n += 1;
            }
        }
    }
    streak = 0;
    d = now.date();
    while per_day.get(d, 0.0) >= float(cfg("high_load_day_h")) {
        streak += 1;
        d = d - timedelta(days=1);
    }
    rate = done_n / (done_n + skip_n) if (done_n + skip_n) > 0 else 1.0;
    return {"week_h": round(week_h, 2), "completion": round(rate, 2), "high_load_streak": streak, "comfort": u.comfort_week_h};
}

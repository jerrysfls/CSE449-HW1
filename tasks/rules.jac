"""Deterministic scheduling rules: reminder chains, review allocation, duration estimates.

The rule engine owns "when", so reminders always fire on time; the LLM only decides "what".
"""

import math;
import from datetime { datetime, timedelta }
import from common.timeutil { at, fmt_dt, round_q, plural }

glob DIFF_FACTOR: dict = {1: 0.7, 2: 0.85, 3: 1.0, 4: 1.2, 5: 1.4};

obj ReminderSpec {
    has at: str, message: str;
}

obj ReviewSlot {
    has offset: int,        # days before the exam (T-offset)
        hours: float,
        focus: str,
        stage: str = "";    # read / practice / weak / quiz / glance
}

"""Estimated hours = base estimate x difficulty factor x personal calibration x (1 + buffer); study tasks also x (1.3 - 0.5 x mastery)."""
def estimate_hours(base: float, difficulty: int, calib: float, buffer: float, mastery: float = -1.0) -> float {
    h = base * DIFF_FACTOR.get(difficulty, 1.0) * calib * (1.0 + buffer);
    if mastery >= 0 {
        h = h * (1.3 - 0.5 * mastery);
    }
    return max(0.25, round_q(h));
}

"""Build the reminder chain for a task kind (times already past are filtered out)."""
def reminder_chain(kind: str, title: str, due: datetime, now: datetime, wake_h: int = 8) -> list[ReminderSpec] {
    specs: list[ReminderSpec] = [];
    if kind == "EXAM" {
        for d in [5, 3, 1] {
            specs.append(ReminderSpec(at=fmt_dt(at(due.date() - timedelta(days=d), 20)), message=f"📝 {title} in {plural(d, 'day')}"));
        }
        morning = at(due.date(), wake_h);
        if morning >= due {
            morning = due - timedelta(hours=2);
        }
        specs.append(ReminderSpec(at=fmt_dt(morning), message=f"📝 {title} today at {due.strftime('%H:%M')}. Good luck!"));
    } elif kind == "QUIZ" {
        for d in [2, 1] {
            specs.append(ReminderSpec(at=fmt_dt(at(due.date() - timedelta(days=d), 20)), message=f"❓ {title} in {plural(d, 'day')}"));
        }
    } elif kind == "ASSIGNMENT" {
        specs.append(ReminderSpec(at=fmt_dt(now + timedelta(minutes=1)), message=f"📚 New assignment: {title}, due {due.strftime('%m/%d %H:%M')}"));
        for d in [3, 1] {
            specs.append(ReminderSpec(at=fmt_dt(at(due.date() - timedelta(days=d), 20)), message=f"📚 {title} is due in {plural(d, 'day')}"));
        }
    } elif kind == "PROJECT" {
        d = now.date() + timedelta(days=(7 - now.weekday()) % 7 or 7);
        while d < due.date() {
            specs.append(ReminderSpec(at=fmt_dt(at(d, 9)), message=f"🚀 Push forward this week: {title} (due {due.strftime('%m/%d')})"));
            d = d + timedelta(days=7);
        }
        specs.append(ReminderSpec(at=fmt_dt(at(due.date() - timedelta(days=3), 9)), message=f"🚀 {title} milestone in 3 days"));
    } elif kind == "MEETING" {
        specs.append(ReminderSpec(at=fmt_dt(due - timedelta(minutes=30)), message=f"👥 In 30 minutes: {title}"));
    }
    now_s = fmt_dt(now);
    return [s for s in specs if s.at > now_s and s.at <= fmt_dt(due)];
}

"""Exam review allocation. n = days actually available (<= exam_lead_days).

For the README example of T-5 and 8h total: 1.5 / 1.5 / 2 / 1.5 / 1.5, plus a 15-minute skim on the morning of T-0.
With fewer days, the later stages are kept (practice, weak points and the quiz always stay)."""
def exam_review_plan(total_h: float, n: int, weak_points: list[str] = []) -> list[ReviewSlot] {
    stages = [
        ("read", 3.0, "Read through the first half and list the key concepts"),
        ("read", 3.0, "Read through the second half"),
        ("practice", 4.0, "Do past exams, mark weak points and log them to the pool"),
        ("weak", 3.0, "Targeted review of weak points"),
        ("quiz", 3.0, "🧪 Mini quiz + build the cheat sheet")
    ];
    if n <= 0 {
        return [ReviewSlot(offset=0, hours=max(0.5, min(2.0, round_q(total_h / 3))), focus="Pre-exam cram: key points + weak points", stage="cram")];
    }
    if n > 5 {
        stages = [("read", 2.0, "Preview / outline the course material")] * (n - 5) + stages;
    }
    chosen = stages[-n:];
    if n == 1 {
        chosen = [("quiz", 1.0, "Key-point review + 🧪 mini quiz + cheat sheet")];
    } elif n == 2 {
        chosen = [("practice", 1.0, "Do past exams and mark weak points"), ("quiz", 1.0, "Weak-point drills + 🧪 mini quiz + cheat sheet")];
    }
    total_w = sum([c[1] for c in chosen]);
    out: list[ReviewSlot] = [];
    for (idx, c) in enumerate(chosen) {
        focus = c[2];
        if c[0] == "weak" and weak_points {
            focus = f"Targeted review of weak points: {', '.join(weak_points[:3])}";
        }
        out.append(ReviewSlot(offset=n - idx, hours=max(0.5, round_q(total_h * c[1] / total_w)), focus=focus, stage=c[0]));
    }
    glance = "Quick morning skim" + (f", focus: {', '.join(weak_points[:3])}" if weak_points else "");
    out.append(ReviewSlot(offset=0, hours=0.25, focus=glance, stage="glance"));
    return out;
}

"""Quiz: a 30-45 minute review plus 5 self-test questions at T-1."""
def quiz_review_hours(est_h: float) -> float {
    return max(0.5, min(0.75, round_q(est_h)));
}

"""Assignment: split into blocks of <= 2h each (and no longer than one focus session)."""
def split_chunks(total_h: float, max_chunk_h: float) -> list[float] {
    if total_h <= 0 {
        return [];
    }
    n = max(1, math.ceil(total_h / max_chunk_h - 1e-9));
    per = round_q(total_h / n);
    chunks = [per] * n;
    diff = round_q(total_h - per * n);
    chunks[-1] = max(0.25, round_q(chunks[-1] + diff));
    return chunks;
}

"""Project: work back from the milestone with a fixed number of hours per week."""
def project_weekly_hours(total_h: float, days_left: int) -> list[float] {
    weeks = max(1, math.ceil(days_left / 7));
    per = round_q(total_h / weeks);
    return [max(0.5, per)] * weeks;
}

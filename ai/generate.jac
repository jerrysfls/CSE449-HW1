"""Generate concrete task content from an interest and estimate base durations. The LLM writes the "content"; templates are used offline."""

import math;
import from ai.llm { llm, ai_enabled, ai_failed, ai_ok }
import from interests.pool { Interest, InterestKind }

obj SessionDraft {
    has title: str,          # short title, e.g. "Guitar: C-G chord changes"
        minutes: int,        # session length (minutes)
        focus: str;          # what exactly to do this time
}

"""Generate this week's concrete practice / study sessions for an interest, in English.
Requirements: total length about `hours` hours; each session at most max_min minutes; HABIT interests are split into 7 short daily sessions;
content builds up step by step and is concrete and actionable (e.g. guitar -> "C-G chord changes", "strumming rhythm", "learn a simple song");
for study interests with weak_points, prioritize targeted work on the weak points; avoid exact repeats of recent_titles."""
def llm_sessions(name: str, kind: str, hours: float, max_min: int, weak_points: list[str], mastery: float, recent_titles: list[str]) -> list[SessionDraft] by llm();

"""Estimate the base time to finish this task (hours, at average difficulty and average proficiency)."""
def llm_base_hours(title: str, kind: str, scope: str) -> float by llm();

"""Write one concrete English review instruction for each exam-review stage (one-to-one with stages, same order).
Use the course, exam scope and weak points, e.g. "Read through lectures 1-3 and list the key concepts"."""
def llm_review_focus(course: str, scope: str, weak_points: list[str], stages: list[str]) -> list[str] by llm();

glob HOBBY_STEPS: dict = {
         "guitar": ["C-G chord changes", "strumming rhythm", "learn a simple song"],
         "piano": ["scales and arpeggios", "hand coordination", "practice a piece"],
         "run": ["easy 5k run", "intervals 6x400m", "long slow run"],
         "gym": ["upper-body strength", "lower-body strength", "core + stretching"],
         "workout": ["upper-body strength", "lower-body strength", "core + stretching"],
         "cook": ["learn a new dish", "weekend meal prep", "perfect a signature dish"],
         "swim": ["breathing drills", "freestyle technique", "endurance swim"],
         "draw": ["sketching practice", "color practice", "finish a small piece"],
         "paint": ["sketching practice", "color practice", "finish a small piece"]
     },
     BASE_HOURS: dict = {
         "EXAM": 6.5, "QUIZ": 0.6, "ASSIGNMENT": 4.0, "PROJECT": 12.0,
         "MEETING": 0.5, "HOBBY": 1.0, "HABIT": 0.25, "PRACTICE": 1.0
     };

def tasks_from_interest(i: Interest, hours: float, max_min: int, recent_titles: list[str] = []) -> list[SessionDraft] {
    if hours <= 0 {
        return [];
    }
    if i.session_min > 0 {
        max_min = min(max_min, i.session_min);
    }
    if ai_enabled() {
        try {
            out = llm_sessions(i.name, i.kind.name, hours, max_min, i.weak_points, i.mastery, recent_titles);
            out = [s for s in out if isinstance(s, SessionDraft) and s.minutes > 0];
            if out {
                ai_ok();
                return [SessionDraft(title=s.title, minutes=min(max_min, int(s.minutes)), focus=s.focus) for s in out];
            }
        } except Exception as e {
            ai_failed(e);
        }
    }
    return fallback_sessions(i, hours, max_min);
}

"""Offline template: split the weekly hours into sessions, rotating through stages."""
def fallback_sessions(i: Interest, hours: float, max_min: int) -> list[SessionDraft] {
    total_min = int(round(hours * 60));
    if i.kind == InterestKind.HABIT {
        n = 7;
        per = max(10, int(round(total_min / 7 / 5)) * 5);
        return [SessionDraft(title=i.name, minutes=per, focus=i.name) for _ in range(n)];
    }
    unit = i.session_min if i.session_min > 0 else (60 if i.kind == InterestKind.HOBBY else min(max_min, 90));
    n = max(1, math.ceil(total_min / unit));
    per = max(15, int(round(total_min / n / 5)) * 5);
    steps = steps_for(i);
    out: list[SessionDraft] = [];
    for k in range(n) {
        step = steps[k % len(steps)];
        out.append(SessionDraft(title=f"{i.name}: {step}", minutes=per, focus=step));
    }
    return out;
}

def steps_for(i: Interest) -> list[str] {
    for (key, steps) in HOBBY_STEPS.items() {
        if key in i.name.lower() {
            return steps;
        }
    }
    if i.kind in [InterestKind.STUDY, InterestKind.WORK] {
        if i.weak_points {
            return [f"focus on {w}" for w in i.weak_points[:3]] + ["cover new material"];
        }
        return ["cover new material", "organize notes", "practice / review"];
    }
    if i.kind == InterestKind.GOAL {
        return ["break down the next milestone", "make one step of progress", "review progress"];
    }
    return ["warm-up + basics", "focused practice", "free practice"];
}

def base_hours(title: str, kind: str, scope: str) -> float {
    if ai_enabled() and kind in ["EXAM", "ASSIGNMENT", "PROJECT"] {
        try {
            h = float(llm_base_hours(title, kind, scope));
            if 0.1 <= h <= 200 {
                ai_ok();
                return h;
            }
        } except Exception as e {
            ai_failed(e);
        }
    }
    return BASE_HOURS.get(kind, 1.0);
}

def review_focus(course: str, scope: str, weak_points: list[str], stages: list[str]) -> list[str] {
    if ai_enabled() {
        try {
            out = llm_review_focus(course, scope, weak_points, stages);
            if isinstance(out, list) and len(out) == len(stages) {
                ai_ok();
                return [str(x) for x in out];
            }
        } except Exception as e {
            ai_failed(e);
        }
    }
    return stages;
}

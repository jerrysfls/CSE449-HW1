"""Interest pool dynamics: heat decay, weight / mastery updates, and time allocation by weight x (1 - heat)."""

import from interests.pool { Interest, InterestKind, clamp01 }
import from common.timeutil { round_half }

"""Interests with high weight and little recent engagement come first."""
def priority(i: Interest) -> float {
    return i.weight * (1.0 - i.heat) + 0.02;
}

"""Suggested weekly hours when no budget is set. STUDY / WORK are driven mainly by rigid tasks, so they default to 0."""
def default_budget(kind: InterestKind) -> float {
    return {"HOBBY": 1.0, "HABIT": 1.0, "GOAL": 1.0, "STUDY": 0.0, "WORK": 0.0}[kind.name];
}

"""Decay heat per day and record it in heat_log (used for trends in the profile)."""
def decay_heat(i: Interest, days: int, per_day: float, day_str: str) -> None {
    if days <= 0 {
        return;
    }
    i.heat = round(max(0.0, i.heat - per_day * days), 3);
    log_heat(i, day_str);
}

def log_heat(i: Interest, day_str: str) -> None {
    if i.heat_log and i.heat_log[-1][0] == day_str {
        i.heat_log[-1][1] = i.heat;
    } else {
        i.heat_log.append([day_str, i.heat]);
    }
    if len(i.heat_log) > 60 {
        i.heat_log = i.heat_log[-60:];
    }
}

"""Expected weekly hours after a weight change: budget x (weight / budget_weight)^2, capped at 1.5x.
E.g. guitar at 3h/week (weight 0.6 when set) drops to 0.5 after "lost interest" -> 3 x (0.5/0.6)^2 ~ 2h."""
def effective_budget(i: Interest) -> float {
    b = i.weekly_budget_h if i.weekly_budget_h > 0 else default_budget(i.kind);
    if i.budget_weight <= 0 {
        return b;
    }
    ratio = (i.weight / i.budget_weight) ** 2;
    return b * max(0.0, min(1.5, ratio));
}

def mastery_factor(mastery: float) -> float {
    return 1.3 - 0.5 * mastery;
}

"""Split free_h hours among the interests.

1. each interest's demand = weekly budget - hours already covered by rigid tasks this week;
2. exam weeks squeeze HOBBY, but min_hobby_h is reserved first (downtime never drops to 0);
3. the remaining time is "water-filled" by priority = weight x (1 - heat), never above demand;
4. results are rounded to 0.5h.
"""
def allocate_hours(items: list[Interest], free_h: float, min_hobby_h: float = 1.0, exam_week: bool = False, squeeze: float = 0.35, covered: dict = {}) -> dict {
    desire: dict = {};
    for i in items {
        d = effective_budget(i);
        d = max(0.0, d - covered.get(i.name, 0.0));
        if exam_week and i.kind == InterestKind.HOBBY {
            d = d * squeeze;
        }
        desire[i.name] = d;
    }
    alloc: dict = {i.name: 0.0 for i in items};
    remaining = max(0.0, free_h);

    # reserve downtime
    hobbies = sorted([i for i in items if i.kind == InterestKind.HOBBY], key=lambda i: Interest : -priority(i));
    if hobbies {
        full_hobby = sum([effective_budget(i) for i in hobbies]);
        floor_h = min(min_hobby_h, full_hobby, remaining);
        for i in hobbies {
            if floor_h <= 0 {
                break;
            }
            cap = max(desire[i.name], min(floor_h, effective_budget(i)));
            give = min(floor_h, cap);
            alloc[i.name] = give;
            desire[i.name] = max(desire[i.name], give);
            floor_h -= give;
            remaining -= give;
        }
    }

    # water-filling allocation
    active = [i for i in items if desire[i.name] - alloc[i.name] > 1e-6];
    while active and remaining > 1e-6 {
        total = sum([priority(i) for i in active]);
        saturated: list = [];
        spent = 0.0;
        for i in active {
            share = remaining * priority(i) / total;
            room = desire[i.name] - alloc[i.name];
            give = min(share, room);
            alloc[i.name] += give;
            spent += give;
            if room - give <= 1e-6 {
                saturated.append(i);
            }
        }
        remaining -= spent;
        if not saturated {
            break;
        }
        active = [i for i in active if i not in saturated];
    }
    out: dict = {};
    for (k, v) in alloc.items() {
        r = round_half(v);
        if r == 0 and v >= 0.2 {
            r = 0.5;
        }
        out[k] = r;
    }
    return out;
}

"""Sample data: a student taking STATS 413 / EECS 442, writing a paper, and into running."""

import from datetime { timedelta }
import from user.user { User, set_current_user }
import from interests.pool { Interest, InterestKind, Has }
import from tasks.task { Task, TaskKind, TaskStatus }
import from tasks.planner { plan_task, plan_week, default_pref }
import from tasks.slots { find_slot }
import from ai.llm { set_offline }
import from common.graph { bootstrap, pool_of, board_of, attach_task, blocks_of, tasks_of_interest, interests_of, tasks_of, delete_task }
import from sync.events { queue_of, pending_events }
import from common.timeutil { fmt_dt, at, week_monday }

"""For tests / demos: a clean world not attached to root, with the LLM switched off."""
def make_world(clock: str = "2026-09-28 08:00", offline: bool = True) -> User {
    if offline {
        set_offline(True);
    }
    return bootstrap("Tester", False, clock);
}

def add_interest(u: User, name: str, kind: InterestKind, weight: float, heat: float = 0.0, mastery: float = 0.5, budget: float = 0.0, pref: str = "", weak: list[str] = [], aliases: list[str] = []) -> Interest {
    now_s = u.now_str();
    i = Interest(
        name=name, kind=kind, weight=weight, heat=heat, mastery=mastery, weekly_budget_h=budget,
        budget_weight=weight, preferred_time=pref, weak_points=list(weak), aliases=list(aliases),
        created=now_s, last_active=now_s, heat_log=[[now_s[:10], heat]]
    );
    pool_of(u) +>:Has:+> i;
    return i;
}

def add_task(u: User, i: Interest | None, title: str, kind: TaskKind, due: str, est: float = 0.0, scope: str = "", plan: bool = True) -> Task {
    t = Task(id=board_of(u).new_id("t"), title=title, kind=kind, due=due, est_hours=est, scope=scope, created=u.now_str());
    attach_task(u, t, i);
    if plan {
        t spawn plan_task(quiet=True);
    }
    return t;
}

def seed_demo(u: User) -> None {
    now = u.now();
    today = now.date();
    d = lambda n: int : fmt_dt(at(today + timedelta(days=n), 23, 59));

    stats = add_interest(u, "STATS 413", InterestKind.STUDY, 0.8, heat=0.45, mastery=0.55);
    eecs = add_interest(u, "EECS 442", InterestKind.STUDY, 0.7, heat=0.3, mastery=0.45, budget=2.0, weak=["convolution"]);
    paper = add_interest(u, "Paper submission", InterestKind.WORK, 0.6, heat=0.2, budget=3.0, aliases=["paper"]);
    run = add_interest(u, "Running", InterestKind.HOBBY, 0.5, heat=0.3, budget=2.0, pref="evening", aliases=["run"]);
    words = add_interest(u, "Vocab practice", InterestKind.HABIT, 0.6, heat=0.5, budget=1.75, pref="morning", aliases=["vocab", "vocabulary"]);
    phd = add_interest(u, "PhD applications", InterestKind.GOAL, 0.7, heat=0.25, budget=2.0, aliases=["PhD application", "PhD"]);

    # running: heat has dropped for 3 weeks, no run in 5 days
    run.heat_log = [
        [(today - timedelta(days=21)).isoformat(), 0.7],
        [(today - timedelta(days=14)).isoformat(), 0.55],
        [(today - timedelta(days=7)).isoformat(), 0.4],
        [today.isoformat(), 0.3]
    ];
    run.last_active = fmt_dt(now - timedelta(days=5));

    add_task(u, stats, "STATS 413 HW3", TaskKind.ASSIGNMENT, d(2), est=3.0);
    add_task(u, eecs, "EECS 442 Project milestone", TaskKind.PROJECT, d(12), est=10.0);
    add_task(u, paper, "Group meeting: diffusion model progress", TaskKind.MEETING, fmt_dt(at(today + timedelta(days=3), 14)));
    add_task(u, paper, "Read the diffusion model survey", TaskKind.ASSIGNMENT, d(4), est=2.0);

    p = u spawn plan_week();
    u.last_plan_week = week_monday(today).isoformat();
    u.last_decay_day = today.isoformat();

    # make sure there is a run tonight (for the "cancel tonight's run" demo)
    runs = [t for t in tasks_of_interest(run) if t.is_open()];
    if runs and not [b for t in runs for b in blocks_of(t) if b.start[:10] == today.isoformat()] {
        b = blocks_of(runs[0])[0];
        slot = find_slot(u, today, int(round(b.hours() * 60)), "evening", now);
        if slot is not None {
            b.start = fmt_dt(slot[0]);
            b.end = fmt_dt(slot[1]);
        }
    }
    # events produced by the seed data need no processing
    for e in pending_events(queue_of(u)) {
        e.processed = True;
    }
}

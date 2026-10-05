"""Loop prevention: event batching, replanning only the future, locks win, derived interests need confirmation."""

import from data.seed { make_world, add_interest, add_task }
import from interests.pool { Interest, InterestKind, InterestStatus, Has }
import from interests.discover { find_new_topics_fallback }
import from tasks.task { TaskKind, TaskStatus }
import from tasks.planner { plan_week }
import from sync.sync { sync }
import from sync.events { emit_event, queue_of, pending_events }
import from user.actions { update_interest }
import from common.graph { tasks_of, tasks_of_interest, blocks_of, pool_of }

def flex_tasks(i: Interest) -> list {
    return [t for t in tasks_of_interest(i) if t.origin == "PLANNER" and t.is_open()];
}

test "events are processed exactly once and replanning does not loop" {
    u = make_world();
    add_interest(u, "Guitar", InterestKind.HOBBY, 0.6, budget=3.0);
    s1 = u spawn sync();
    assert s1.replanned;                      # first sync of the week: plan
    s2 = u spawn sync();
    assert not s2.replanned;                  # plan_week only emits system events, which never trigger again
    assert len(pending_events(queue_of(u))) == 0;
}

test "small weight changes wait, large ones trigger one replan" {
    u = make_world();
    g = add_interest(u, "Guitar", InterestKind.HOBBY, 0.6, budget=3.0);
    u spawn sync();
    emit_event("interest_changed", "Guitar", {"field": "weight", "before": 0.6, "after": 0.55});
    assert not (u spawn sync()).replanned;
    emit_event("interest_changed", "Guitar", {"field": "weight", "before": 0.6, "after": 0.5});
    emit_event("interest_changed", "Guitar", {"field": "weight", "before": 0.5, "after": 0.4});
    s = u spawn sync();
    assert s.replanned and s.processed >= 2;
}

test "replanning only touches future unlocked tasks" {
    u = make_world("2026-09-28 08:00");
    g = add_interest(u, "Guitar", InterestKind.HOBBY, 0.6, budget=3.0);
    u spawn plan_week();
    tasks = sorted(flex_tasks(g), key=lambda t: any : blocks_of(t)[0].start);
    assert len(tasks) == 3;
    (first, second) = (tasks[0], tasks[1]);
    second.locked = True;
    u.clock = blocks_of(first)[0].end;       # move time to the end of the first session
    first.status = TaskStatus.DONE;
    kept_start = blocks_of(second)[0].start;
    u spawn plan_week();
    assert first.status == TaskStatus.DONE and blocks_of(first);       # finished ones stay
    assert blocks_of(second)[0].start == kept_start;                    # locked ones stay
    total = sum([blocks_of(t)[0].hours() for t in tasks_of_interest(g) if t.status != TaskStatus.CANCELLED]);
    assert abs(total - 3.0) < 0.01;                                     # the week still totals 3h
}

test "paused and unconfirmed derived interests are not planned" {
    u = make_world();
    run = add_interest(u, "Running", InterestKind.HOBBY, 0.5, budget=2.0);
    d = Interest(name="Diffusion model", kind=InterestKind.WORK, weekly_budget_h=2.0, source="DERIVED", confirmed=False);
    pool_of(u) +>:Has:+> d;
    u spawn update_interest(op="pause", name="Running");
    u spawn sync();
    assert flex_tasks(run) == [];
    assert flex_tasks(d) == [];
    u spawn update_interest(op="confirm", name="Diffusion model");
    u spawn sync();
    assert len(flex_tasks(d)) > 0;
}

test "exam week squeezes hobbies but keeps at least 1h" {
    u = make_world("2026-09-28 08:00");
    g = add_interest(u, "Guitar", InterestKind.HOBBY, 0.6, budget=3.0);
    s = add_interest(u, "STATS 413", InterestKind.STUDY, 0.8, mastery=0.55);
    u spawn plan_week();
    assert abs(g.planned["2026-09-28"] - 3.0) < 1e-9;
    add_task(u, s, "STATS 413 Midterm", TaskKind.EXAM, "2026-10-01 15:00");
    p = u spawn plan_week();
    assert abs(p.alloc["Guitar"] - 1.0) < 1e-9;
    # exam-week downtime is placed after the exam
    assert all([blocks_of(t)[0].start > "2026-10-01" for t in flex_tasks(g)]);
}

test "derived topic discovery needs three mentions" {
    texts = ["Read the diffusion model survey", "Group meeting: diffusion model progress", "Submit the diffusion model lab report", "STATS 413 HW3"];
    assert find_new_topics_fallback(texts, ["Paper submission", "STATS 413"])[0] == "Diffusion model";
    assert find_new_topics_fallback(texts[:2], ["Paper submission"]) == [];
    assert find_new_topics_fallback(texts, ["Diffusion model"]) == [];
}

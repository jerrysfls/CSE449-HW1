"""Feedback: task status changes flow back into the interest pool along Feeds edges."""

import from data.seed { make_world, add_interest, add_task }
import from interests.pool { InterestKind, InterestStatus }
import from tasks.task { TaskKind, TaskStatus }
import from sync.feedback { feedback }
import from user.actions { task_action }
import from ai.classify { CancelReason }
import from common.graph { blocks_of, interest_of, add_block }

test "completing a task raises heat and study mastery" {
    u = make_world();
    i = add_interest(u, "STATS 413", InterestKind.STUDY, 0.8, heat=0.2, mastery=0.5);
    t = add_task(u, i, "STATS 413 HW3", TaskKind.ASSIGNMENT, "2026-09-30 23:59", est=3.0);
    t spawn task_action(action="done");
    assert t.status == TaskStatus.DONE;
    assert abs(i.heat - 0.35) < 1e-9;
    assert abs(i.mastery - 0.53) < 1e-9;
}

test "quiz score updates mastery and weak points" {
    u = make_world();
    i = add_interest(u, "STATS 413", InterestKind.STUDY, 0.8, mastery=0.55);
    t = add_task(u, i, "STATS 413 Midterm", TaskKind.EXAM, "2026-10-01 15:00");
    w = t spawn task_action(action="quiz", score=0.8, wrong_topics=["multicollinearity", "residual diagnostics"]);
    assert abs(i.mastery - 0.675) < 1e-9;
    assert i.weak_points == ["multicollinearity", "residual diagnostics"];
    # weak points are written into the next review block
    nxt = [b for b in blocks_of(t) if not b.done][0];
    assert "multicollinearity" in nxt.focus;
}

test "cancel because busy keeps interest and reschedules" {
    u = make_world();
    run = add_interest(u, "Running", InterestKind.HOBBY, 0.5, budget=2.0);
    t = add_task(u, run, "Running: easy run", TaskKind.HOBBY, "", plan=False);
    t.origin = "PLANNER";
    b = add_block(u, t, "2026-09-28 19:00", "2026-09-28 20:00", "Running");
    w = t spawn task_action(action="cancel", reason_text="too busy this week");
    assert w.result == "BUSY";
    assert run.weight == 0.5;
    assert t.status == TaskStatus.SCHEDULED;
    assert b.start > "2026-09-28 23:59";
}

test "cancel because lost interest lowers weight" {
    u = make_world();
    g = add_interest(u, "Guitar", InterestKind.HOBBY, 0.6, budget=3.0);
    t = add_task(u, g, "Guitar: strumming", TaskKind.HOBBY, "", plan=False);
    w = t spawn task_action(action="cancel", reason_text="don't want to practice anymore");
    assert w.result == "LOST_INTEREST";
    assert t.status == TaskStatus.CANCELLED;
    assert abs(g.weight - 0.5) < 1e-9;
}

test "cancel because not needed archives the interest" {
    u = make_world();
    i = add_interest(u, "Japanese", InterestKind.STUDY, 0.5);
    t = add_task(u, i, "Japanese homework", TaskKind.ASSIGNMENT, "2026-10-03 23:59", est=1.0);
    t spawn task_action(action="cancel", reason=CancelReason.NOT_NEEDED);
    assert i.status == InterestStatus.ARCHIVED;
}

test "bad estimate updates calibration" {
    u = make_world();
    i = add_interest(u, "EECS 442", InterestKind.STUDY, 0.7);
    t = add_task(u, i, "EECS 442 HW2", TaskKind.ASSIGNMENT, "2026-10-04 23:59", est=4.0);
    t spawn task_action(action="cancel", reason_text="took longer than I expected, underestimated it");
    assert u.calib_of("ASSIGNMENT") > 1.0;
    t2 = add_task(u, i, "EECS 442 HW3", TaskKind.ASSIGNMENT, "2026-10-04 23:59", est=2.0);
    t2 spawn task_action(action="done", actual_h=3.0);
    assert u.calib_of("ASSIGNMENT") > 1.1;
}

test "skips decay heat and locked interests are untouched" {
    u = make_world();
    i = add_interest(u, "Running", InterestKind.HOBBY, 0.5, heat=0.5);
    t = add_task(u, i, "Running", TaskKind.HOBBY, "", plan=False);
    t spawn feedback(event="skip");
    assert abs(i.heat - 0.35) < 1e-9 and i.skip_streak == 1;
    i.locked = True;
    t spawn feedback(event="done");
    assert abs(i.heat - 0.35) < 1e-9;
}

test "finishing the last exam lowers weight, finishing a final archives" {
    u = make_world();
    i = add_interest(u, "STATS 413", InterestKind.STUDY, 0.8);
    t = add_task(u, i, "STATS 413 Midterm", TaskKind.EXAM, "2026-10-01 15:00");
    t spawn task_action(action="done");
    assert abs(i.weight - 0.7) < 1e-9 and i.status == InterestStatus.ACTIVE;
    f = add_task(u, i, "STATS 413 Final", TaskKind.EXAM, "2026-12-10 10:00");
    f spawn task_action(action="done");
    assert i.status == InterestStatus.ARCHIVED;
}

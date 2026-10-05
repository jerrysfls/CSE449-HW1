"""Session layer (shared by the CLI and the web): follow-up questions, derived-interest confirmation, slash commands."""

import from data.seed { make_world, add_interest, add_task }
import from interests.pool { InterestKind }
import from tasks.task { TaskKind, TaskStatus }
import from user.session { Turn, handle_turn }
import from common.graph { add_block }

def text_of(t: Turn) -> str {
    return "\n".join(["\n".join(s.lines) for s in t.segments]);
}

test "cancel without a reason asks, and the next input is the answer" {
    u = make_world();
    run = add_interest(u, "Running", InterestKind.HOBBY, 0.5, budget=2.0);
    t = add_task(u, run, "Running: easy run", TaskKind.HOBBY, "", plan=False);
    t.origin = "PLANNER";
    b = add_block(u, t, "2026-09-28 19:00", "2026-09-28 20:00", "Running");
    t1 = handle_turn(u, f"/cancel {b.id}");
    assert t1.asking;
    assert u.pending["type"] == "cancel_reason";
    t2 = handle_turn(u, "Too busy this week");
    assert not t2.asking;
    assert u.pending == {};
    assert "too busy" in text_of(t2).lower();
    assert abs(run.weight - 0.5) < 1e-9;      # too busy: weight unchanged
}

test "natural-language cancel asks for a reason that feeds back into the pool" {
    u = make_world();
    run = add_interest(u, "Running", InterestKind.HOBBY, 0.5, budget=2.0, aliases=["run"]);
    t = add_task(u, run, "Running: easy run", TaskKind.HOBBY, "", plan=False);
    t.origin = "PLANNER";
    add_block(u, t, "2026-09-28 19:00", "2026-09-28 20:00", "Running");
    assert handle_turn(u, "Cancel tonight's run").asking;
    handle_turn(u, "Lost interest");
    assert run.weight < 0.5;                 # lost interest: weight goes down
}

test "skipping the reason question counts as busy" {
    u = make_world();
    run = add_interest(u, "Running", InterestKind.HOBBY, 0.5, budget=2.0);
    t = add_task(u, run, "Running: easy run", TaskKind.HOBBY, "", plan=False);
    t.origin = "PLANNER";
    b = add_block(u, t, "2026-09-28 19:00", "2026-09-28 20:00", "Running");
    handle_turn(u, f"/cancel {b.id}");
    handle_turn(u, "skip");
    assert abs(run.weight - 0.5) < 1e-9;
    assert t.status == TaskStatus.SCHEDULED;
}

test "derived interests are confirmed or rejected by a short reply" {
    u = make_world();
    i = add_interest(u, "Diffusion model", InterestKind.WORK, 0.5);
    i.source = "DERIVED";
    i.confirmed = False;
    u.derived = ["Diffusion model"];
    handle_turn(u, "yes");
    assert i.confirmed;
    assert u.derived == [];

    j = add_interest(u, "Transformers", InterestKind.WORK, 0.5);
    j.source = "DERIVED";
    j.confirmed = False;
    u.derived = ["Transformers"];
    handle_turn(u, "Not now");
    assert not j.confirmed;
    assert u.derived == [];
}

test "slash commands: name, unknown and quit" {
    u = make_world();
    handle_turn(u, "/name Alex");
    assert u.name == "Alex";
    assert "Unknown command" in text_of(handle_turn(u, "/foo"));
    assert handle_turn(u, "/quit").quit;
}

test "done by block id marks the block and reports it" {
    u = make_world();
    i = add_interest(u, "STATS 413", InterestKind.STUDY, 0.8);
    t = add_task(u, i, "STATS 413 HW3", TaskKind.ASSIGNMENT, "2026-09-30 23:59", est=3.0);
    t.status = TaskStatus.SCHEDULED;
    b = add_block(u, t, "2026-09-28 09:00", "2026-09-28 10:00", "STATS 413 HW3 (1/2)");
    out = text_of(handle_turn(u, f"/done {b.id}"));
    assert b.done;
    assert "Done" in out;
}

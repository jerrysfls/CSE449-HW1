"""Rule engine: duration estimates, reminder chains, review allocation, natural-language parsing, cancel-reason classification."""

import from datetime { datetime }
import from tasks.rules { estimate_hours, reminder_chain, exam_review_plan, split_chunks, quiz_review_hours }
import from interests.dynamics { allocate_hours }
import from interests.pool { Interest, InterestKind }
import from ai.parse { rule_route, IntentKind, InterestOp, parse_score, derive_aliases }
import from ai.classify { rule_classify_cancel, CancelReason }
import from ai.llm { set_offline }
import from tasks.task { TaskKind }
import from common.timeutil { parse_when, to_dt }

glob NOW = datetime(2026, 9, 28, 8, 0);

test "exam estimate adds time when mastery is low" {
    # 6.5h x difficulty 1.0 x calibration 1.0 x (1 + 0.2) x (1.3 - 0.5 x 0.55) ~ 8h
    h = estimate_hours(6.5, 3, 1.0, 0.2, 0.55);
    assert h == 8.0;
    assert estimate_hours(6.5, 3, 1.0, 0.2, 0.9) < h;
    assert estimate_hours(4.0, 5, 1.0, 0.2) > estimate_hours(4.0, 2, 1.0, 0.2);
}

test "exam review plan follows T-5 pattern" {
    plan = exam_review_plan(8.0, 5);
    days = [s for s in plan if s.stage != "glance"];
    assert [s.offset for s in days] == [5, 4, 3, 2, 1];
    assert [s.hours for s in days] == [1.5, 1.5, 2.0, 1.5, 1.5];
    assert "quiz" in days[-1].focus;
    glance = [s for s in plan if s.stage == "glance"];
    assert len(glance) == 1 and glance[0].offset == 0 and glance[0].hours == 0.25;
}

test "exam review plan keeps practice and quiz when time is short" {
    plan = exam_review_plan(6.0, 3, ["convolution"]);
    stages = [s.stage for s in plan];
    assert stages == ["practice", "weak", "quiz", "glance"];
    assert "convolution" in plan[1].focus;
}

test "exam reminder chain T-5 T-3 T-1 and morning" {
    due = datetime(2026, 10, 3, 15, 0);
    rs = reminder_chain("EXAM", "STATS Midterm", due, NOW, 8);
    ats = [r.at for r in rs];
    assert ats == ["2026-09-28 20:00", "2026-09-30 20:00", "2026-10-02 20:00", "2026-10-03 08:00"];
}

test "quiz reminders T-2 T-1 and past ones are dropped" {
    due = datetime(2026, 9, 29, 10, 0);
    rs = reminder_chain("QUIZ", "quiz", due, NOW, 8);
    assert [r.at for r in rs] == ["2026-09-28 20:00"];
    assert 0.5 <= quiz_review_hours(0.6) <= 0.75;
}

test "assignment chunks are at most 2h" {
    chunks = split_chunks(5.0, 2.0);
    assert len(chunks) == 3;
    assert all([c <= 2.0 for c in chunks]);
    assert abs(sum(chunks) - 5.0) < 0.26;
}

test "allocation favours high weight and low heat and protects hobby time" {
    a = Interest(name="TOEFL", kind=InterestKind.STUDY, weight=0.9, heat=0.1, weekly_budget_h=6.0);
    b = Interest(name="Guitar", kind=InterestKind.HOBBY, weight=0.6, heat=0.8, weekly_budget_h=3.0);
    alloc = allocate_hours([a, b], 4.0, 1.0);
    assert alloc["TOEFL"] > alloc["Guitar"];
    assert alloc["Guitar"] >= 1.0;
    # exam week: guitar is squeezed from 3h to 1h, but never to 0
    exam = allocate_hours([b], 20.0, 1.0, True, 0.35);
    assert exam["Guitar"] == 1.0;
}

test "weight drop shrinks the weekly allocation" {
    g = Interest(name="Guitar", kind=InterestKind.HOBBY, weight=0.6, weekly_budget_h=3.0, budget_weight=0.6);
    assert allocate_hours([g], 20.0)["Guitar"] == 3.0;
    g.weight = 0.5;
    assert allocate_hours([g], 20.0)["Guitar"] == 2.0;
}

test "parse dates and clocks" {
    assert parse_when("STATS 413 midterm 10/1 3pm", NOW) == "2026-10-01 15:00";
    assert parse_when("group meeting tomorrow at 8:30pm", NOW) == "2026-09-29 20:30";
    assert parse_when("meeting next Tue 14:00", NOW) == "2026-10-06 14:00";
    assert parse_when("homework due Friday", NOW) == "2026-10-02 23:59";
    assert parse_when("quiz Oct 3 at 10am", NOW) == "2026-10-03 10:00";
    assert parse_when("run tonight at 8", NOW) == "2026-09-28 20:00";
    assert parse_when("dentist in 3 days at noon", NOW) == "2026-10-01 12:00";
    assert parse_when("I like guitar", NOW) == "";
    assert parse_when("monitor my month", NOW) == "";
}

test "rule router understands the README examples" {
    set_offline(True);
    it = rule_route("I'm learning guitar, want to practice 3 hours a week, evenings are best", NOW, []);
    assert it.kind == IntentKind.ADD_INTEREST;
    assert it.interest.name == "Guitar" and it.interest.kind == InterestKind.HOBBY;
    assert it.interest.weekly_budget_h == 3.0 and it.interest.preferred_time == "evening";

    it = rule_route("STATS 413 midterm 10/1 3pm, covers lecture 1-6", NOW, ["STATS 413"]);
    assert it.kind == IntentKind.ADD_TASK;
    assert it.task.kind == TaskKind.EXAM and it.task.title == "STATS 413 Midterm";
    assert it.task.scope == "lecture 1-6" and it.task.due == "2026-10-01 15:00";

    it = rule_route("Quiz done, 8/10, missed multicollinearity and residual plots", NOW, []);
    assert it.kind == IntentKind.QUIZ_RESULT;
    assert abs(it.score - 0.8) < 1e-9;
    assert it.wrong_topics == ["multicollinearity", "residual plots"];

    it = rule_route("Cancel tonight's run", NOW, ["Running", "run"]);
    assert it.kind == IntentKind.CANCEL_TASK and it.reason == "";

    it = rule_route("Cancel tonight's run, too busy", NOW, ["Running", "run"]);
    assert it.kind == IntentKind.CANCEL_TASK and it.reason == "too busy";

    it = rule_route("Pause running this month", NOW, ["Running", "run"]);
    assert it.kind == IntentKind.UPDATE_INTEREST and it.update.op == InterestOp.PAUSE;

    it = rule_route("Prioritize TOEFL this semester", NOW, ["TOEFL"]);
    assert it.kind == IntentKind.UPDATE_INTEREST and it.update.op == InterestOp.WEIGHT_UP;

    it = rule_route("I want to memorize vocab 15 minutes every morning", NOW, []);
    assert it.kind == IntentKind.ADD_INTEREST and it.interest.kind == InterestKind.HABIT;
    assert it.interest.weekly_budget_h == 1.75;
}

test "rule router: tasks, completion, views" {
    set_offline(True);
    it = rule_route("STATS 413 quiz 10/3 2pm", NOW, ["STATS 413"]);
    assert it.kind == IntentKind.ADD_TASK and it.task.kind == TaskKind.QUIZ;
    assert it.task.due == "2026-10-03 14:00";

    it = rule_route("Group meeting Thursday 2pm to present diffusion progress", NOW, []);
    assert it.kind == IntentKind.ADD_TASK and it.task.kind == TaskKind.MEETING;
    assert it.task.title == "Group meeting to present diffusion progress";

    it = rule_route("HW3 done, took 3 hours", NOW, []);
    assert it.kind == IntentKind.COMPLETE_TASK and it.actual_hours == 3.0;

    it = rule_route("Postpone tomorrow's guitar by 2 days", NOW, ["Guitar"]);
    assert it.kind == IntentKind.POSTPONE_TASK and it.days == 2;

    assert rule_route("What's on today?", NOW, []).kind == IntentKind.SHOW_BRIEF;
    assert rule_route("Give me some advice", NOW, []).kind == IntentKind.SHOW_DIGEST;
    assert rule_route("show my interest pool", NOW, []).kind == IntentKind.SHOW_POOL;
    assert rule_route("what's my schedule this week", NOW, []).kind == IntentKind.SHOW_WEEK;
    assert rule_route("hello there", NOW, []).kind == IntentKind.CHAT;
}

test "aliases derived from interest names" {
    assert derive_aliases("TOEFL prep") == ["TOEFL"];
    assert derive_aliases("Running") == ["run"];
    assert derive_aliases("Guitar") == [];
}

test "score parsing" {
    assert parse_score("8/10") == 0.8;
    assert parse_score("got 85 points") == 0.85;
    assert parse_score("scored 90%") == 0.9;
    assert parse_score("no score yet") == -1.0;
}

test "cancel reasons are classified by rules" {
    assert rule_classify_cancel("Too busy this week") == CancelReason.BUSY;
    assert rule_classify_cancel("Don't want to run anymore") == CancelReason.LOST_INTEREST;
    assert rule_classify_cancel("Dropped the class, no longer needed") == CancelReason.NOT_NEEDED;
    assert rule_classify_cancel("Took longer than I expected, underestimated it") == CancelReason.BAD_ESTIMATE;
}

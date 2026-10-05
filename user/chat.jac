"""chat: the conversation entry point. Parses the intent (LLM / rules), then routes to the matching walker."""

import re;
import from datetime { timedelta }
import from user.user { User }
import from interests.pool { Interest, InterestKind }
import from tasks.task { Task, StudyBlock, TaskKind, TaskStatus }
import from tasks.planner { plan_task }
import from user.actions { task_action, update_interest, complete_today }
import from sync.feedback { feedback }
import from sync.events { emit_event }
import from notify.brief { daily_brief, profile_digest, render_pool, render_week }
import from ai.parse { route, IntentKind, InterestOp, InterestDraft }
import from ai.llm { ai_enabled }
import from common.graph { board_of, tasks_of, blocks_of, interests_of, interest_of, find_interest, attach_task, resolve_target, tasks_of_interest }
import from common.timeutil { to_dt, fmt_dt, pretty, hm }

glob HELP_HINT: list = [
    "I'm not quite sure what you mean 🤔 You can say things like:",
    "  · I'm learning guitar, want to practice 3 hours a week, evenings are best",
    "  · STATS 413 midterm 10/1 3pm, covers lecture 1-6",
    "  · Quiz done, 8/10, missed multicollinearity and residual plots",
    "  · Cancel tonight's run / Postpone tomorrow's guitar / HW3 done, took 3 hours",
    "  · Prioritize TOEFL this semester / Pause running this month",
    "  · What's on today? / Show my interest pool / Give me some advice",
    "Or type /help to see every command"
];

glob OP_MAP: dict = {
    "WEIGHT_UP": "weight_up", "WEIGHT_DOWN": "weight_down", "SET_WEIGHT": "set_weight", "SET_BUDGET": "budget",
    "PAUSE": "pause", "RESUME": "resume", "ARCHIVE": "archive", "SET_TIME": "time"
};

def alias_names(u: User) -> list[str] {
    out: list[str] = [];
    for i in interests_of(u) {
        out += [i.name] + i.aliases;
    }
    return out;
}

"""When a quiz score does not name the course: find the nearest quiz block / quiz / upcoming exam."""
def guess_quiz_target(u: User, text: str) -> tuple {
    (t, b) = resolve_target(u, text);
    if t is not None {
        return (t, b, interest_of(t));
    }
    now = u.now();
    lo = fmt_dt(now - timedelta(days=1));
    hi = fmt_dt(now + timedelta(days=1));
    best = None;
    for x in tasks_of(u) {
        for blk in blocks_of(x) {
            if "quiz" in blk.focus.lower() and lo <= blk.start <= hi {
                if best is None or abs((to_dt(blk.start) - now).total_seconds()) < abs((to_dt(best[1].start) - now).total_seconds()) {
                    best = (x, blk);
                }
            }
        }
    }
    if best is not None {
        return (best[0], best[1], interest_of(best[0]));
    }
    rigid = sorted([x for x in tasks_of(u) if x.is_open() and x.kind.name in ["QUIZ", "EXAM"] and x.due], key=lambda x: Task : x.due);
    if rigid {
        return (rigid[0], None, interest_of(rigid[0]));
    }
    for i in interests_of(u) {
        if i.kind == InterestKind.STUDY and i.matches(text) {
            return (None, None, i);
        }
    }
    return (None, None, None);
}

walker chat {
    has text: str,
        out: list[str] = [],
        ask: dict = {};          # set when a follow-up question is needed, e.g. {"type": "cancel_reason", "task": "t3"}

    can talk with User entry {
        u = here;
        now = u.now();
        open_tasks = [f"{t.id} {t.title}" for t in tasks_of(u) if t.is_open()][:40];
        it = route(self.text, now, alias_names(u), open_tasks);
        k = it.kind;

        if k == IntentKind.ADD_INTEREST {
            w = u spawn update_interest(op="add", draft=it.interest);
            self.out += w.out;
        } elif k == IntentKind.UPDATE_INTEREST {
            upd = it.update;
            i = find_interest(u, upd.name, True);
            name = i.name if i is not None else upd.name;
            w = u spawn update_interest(op=OP_MAP[upd.op.name], name=name, value=upd.value, text=upd.text);
            self.out += w.out;
            if w.related {
                self.ask = {"type": "archive_related", "ids": w.related, "name": name};
                self.out.append(f"\"{name}\" still has {len(w.related)} upcoming task(s). Cancel them too? (y/N)");
            }
        } elif k == IntentKind.ADD_TASK {
            self.add_task(u, it.task);
        } elif k == IntentKind.COMPLETE_TASK and re.search(r"\b(all|everything)\b.{0,25}\b(today|tonight)\b|\b(today|tonight)\b.{0,25}\b(all|everything)\b", self.text.lower()) {
            self.out += complete_today(u);
        } elif k == IntentKind.COMPLETE_TASK {
            (t, b) = resolve_target(u, it.target or self.text);
            if t is None {
                self.out.append("I couldn't tell which task you mean. Use /tasks to see the ids, then /done <id>");
                disengage;
            }
            whole = not t.is_rigid() or re.search(r"took the (exam|midterm|final|test|quiz)|(exam|midterm|final|test) (is )?(done|over)|submitted|turned in|handed in|(hw|homework|assignment|project|essay|report).{0,25}(done|finished|complete)|finished (the |my )?(hw|homework|assignment|project|essay|report)", self.text.lower()) is not None or b is None;
            w = t spawn task_action(action="done", block_id="" if whole else b.id, actual_h=it.actual_hours);
            self.out += w.out;
        } elif k == IntentKind.CANCEL_TASK {
            (t, b) = resolve_target(u, it.target or self.text);
            if t is None {
                self.out.append("I couldn't tell which task you mean. Use /tasks to see the ids, then /cancel <id>");
                disengage;
            }
            if not it.reason {
                self.ask = {"type": "cancel_reason", "task": t.id};
                self.out.append("OK. Mind telling me why? (too busy / lost interest / no longer needed / other, or just press Enter to skip)");
                disengage;
            }
            w = t spawn task_action(action="cancel", reason_text=it.reason);
            self.out += w.out;
        } elif k == IntentKind.POSTPONE_TASK {
            (t, b) = resolve_target(u, it.target or self.text);
            if t is None {
                self.out.append("I couldn't tell which task you mean. Use /tasks to see the ids, then /postpone <id> [days]");
                disengage;
            }
            w = t spawn task_action(action="postpone", days=it.days, block_id=b.id if b is not None else "");
            self.out += w.out;
        } elif k == IntentKind.QUIZ_RESULT {
            (t, b, i) = guess_quiz_target(u, self.text);
            if t is None and i is None {
                self.out.append("Which course was the quiz for? E.g. STATS 413 quiz 8/10, missed multicollinearity");
                disengage;
            }
            if t is not None {
                is_quiz_block = b is not None and "quiz" in b.focus.lower();
                w = t spawn task_action(action="quiz", score=it.score, wrong_topics=it.wrong_topics, block_id=b.id if is_quiz_block else "");
                self.out += w.out;
            } else {
                fb = i spawn feedback(event="quiz", score=it.score, wrong_topics=it.wrong_topics);
                self.out += fb.out;
            }
        } elif k == IntentKind.SHOW_BRIEF {
            self.out += (u spawn daily_brief()).out;
        } elif k == IntentKind.SHOW_DIGEST {
            self.out += (u spawn profile_digest()).out;
        } elif k == IntentKind.SHOW_POOL {
            self.out += render_pool(u);
        } elif k == IntentKind.SHOW_WEEK {
            self.out += render_week(u);
        } else {
            if it.reply {
                self.out.append(it.reply);
            } else {
                self.out += HELP_HINT;
            }
        }
    }

    """Record a rigid task: link it to (or create) an interest, then let plan_task work back to review blocks and reminders."""
    def add_task(u: User, d: any) -> None {
        i = find_interest(u, d.interest_name) if d.interest_name else None;
        if i is None {
            i = find_interest(u, d.title);
        }
        if i is None and d.interest_name {
            ik = InterestKind.STUDY if d.kind.name in ["EXAM", "QUIZ", "ASSIGNMENT"] else InterestKind.WORK;
            w = u spawn update_interest(op="add", draft=InterestDraft(name=d.interest_name, kind=ik, weekly_budget_h=0.0, weight=0.7));
            i = w.interest;
            self.out += w.out;
        }
        t = Task(
            id=board_of(u).new_id("t"), title=d.title, kind=d.kind, due=d.due, scope=d.scope,
            difficulty=max(1, min(5, int(d.difficulty or 3))), est_hours=float(d.est_hours or 0.0),
            created=u.now_str(), topics=list(d.topics or [])
        );
        attach_task(u, t, i);
        link = "";
        if i is not None {
            mast = f" (mastery {i.mastery:.2f})" if i.kind == InterestKind.STUDY else "";
            link = f", linked to {i.label()}{mast}";
        }
        self.out.append(f"Saved {t.icon()} {t.title} ({pretty(t.due)}){link}");
        p = t spawn plan_task();
        self.out += p.out;
        emit_event("task_added", t.id, {"rigid": t.is_rigid(), "kind": t.kind.name});
    }
}

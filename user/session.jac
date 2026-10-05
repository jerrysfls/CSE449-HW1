"""Session layer: the "one conversation turn" logic shared by the CLI (main.jac) and the web (services/companion.jac).

A turn's input can be a slash command, natural language, or the answer to the previous follow-up question. Output comes in segments:
    say   the assistant's reply (the CLI prefixes the first line with 🧭 and indents the rest)
    more  changes caused by sync / cascading adjustments (indented in the CLI)
    raw   reminders, help, etc., printed as is
Follow-up questions (cancel reason, whether to cancel related tasks) live in User.pending, and the next input is the answer;
derived interests awaiting confirmation live in User.derived and are handled when the user says "yes / not now".
"""

import from datetime { timedelta }
import from user.user { User, CTX, set_current_user }
import from user.chat { chat }
import from user.actions { task_action, update_interest, complete_today }
import from tasks.task { StudyBlock }
import from tasks.planner { plan_week }
import from sync.sync { sync }
import from notify.brief { daily_brief, profile_digest, render_pool, render_week, render_tasks }
import from notify.reminders { check_reminders }
import from ai.llm { ai_status }
import from ai.parse { parse_score }
import from ai.tutor { make_quiz, review_outline }
import from ai.classify { CancelReason }
import from data.seed { seed_demo }
import from common.graph { bootstrap, wipe_user, find_by_id, find_interest, task_of_block, interest_of }
import from common.timeutil { to_dt, fmt_dt }

glob HELP: list = [
    "Just talk to me in plain English, for example:",
    "  I'm learning guitar, want to practice 3 hours a week / STATS 413 midterm 10/1 3pm / Cancel tonight's run",
    "",
    "View       /brief today's brief   /week [days] week view   /why week view with reasons   /tasks tasks   /pool interest pool   /digest profile",
    "Tasks      /done <id> [actual hours]   /done today   /cancel <id> [reason]   /postpone <id> [days]",
    "           /quiz <id> <score like 8/10> [missed topics...]   /quizgen <id|interest> [count]   /outline <interest>",
    "           /lock <id|interest>   /unlock <id|interest>",
    "Interests  /weight <interest> <0-1>   /budget <interest> <hours/week>   /when <interest> morning|afternoon|evening",
    "           /short <interest> <minutes>   /pause /resume /archive <interest>   /confirm /reject <derived interest>",
    "System     /plan replan this week   /sync   /time [YYYY-MM-DD HH:MM | +3h | +1d | now]   /name <name>   /ai   /seed   /reset   /quit"
];

glob YES: list = ["y", "yes", "yeah", "yep", "sure", "ok", "okay", "cancel", "cancel them"],
     CONFIRM: list = ["yes", "y", "add", "add it", "sure", "ok", "okay", "yeah", "yep"],
     REJECT: list = ["not now", "no", "n", "nope", "no thanks", "skip"],
     SKIP: list = ["", "skip", "-", "pass"],
     CANCEL_ASK: str = "Mind telling me why? (too busy / lost interest / no longer needed / other, or just press Enter to skip)";

obj Segment {
    has style: str, lines: list[str] = [];
}

obj Turn {
    has segments: list[Segment] = [],
        user: User | None = None,      # replaced by the new user after /seed or /reset
        quit: bool = False,
        asking: bool = False;          # this turn asked a follow-up question; the next input is the answer

    def add(style: str, lines: list[str]) -> None {
        if lines {
            self.segments.append(Segment(style=style, lines=list(lines)));
        }
    }

    def say(lines: list[str]) -> None {
        self.add("say", lines);
    }

    def more(lines: list[str]) -> None {
        self.add("more", lines);
    }

    def raw(lines: list[str]) -> None {
        self.add("raw", lines);
    }
}

"""After every turn: batch sync (one turn = one batch of events) + check reminders."""
def after_turn(u: User, t: Turn) -> None {
    s = u spawn sync();
    t.more(s.out);
    u.derived = u.derived + [n for n in s.suggested if n not in u.derived];
    r = u spawn check_reminders();
    t.raw(r.out);
}

def ask(u: User, t: Turn, pend: dict, question: str = "") -> None {
    u.pending = pend;
    t.asking = True;
    if question {
        t.say([question]);
    }
}

def resolve_obj(u: User, ident: str) -> tuple {
    o = find_by_id(u, ident);
    if isinstance(o, StudyBlock) {
        return (task_of_block(o), o);
    }
    return (o, None);
}

def cancel_ids(u: User, ids: list[str], t: Turn) -> None {
    for tid in ids {
        (tk, b) = resolve_obj(u, tid);
        if tk is not None {
            w = tk spawn task_action(action="cancel", reason=CancelReason.OTHER);
            t.more(w.out);
        }
    }
}

"""Interest commands. Returns True when this turn asked a follow-up question."""
def cmd_interest(u: User, op: str, rest: str, with_value: bool, t: Turn) -> bool {
    value = 0.0;
    text = "";
    name = rest.strip();
    if with_value {
        parts = rest.rsplit(" ", 1);
        if len(parts) < 2 {
            t.say([f"Usage: /{op} <interest> <value>"]);
            return False;
        }
        (name, raw_v) = (parts[0].strip(), parts[1].strip());
        if op == "time" {
            text = raw_v;
        } else {
            try {
                value = float(raw_v);
            } except ValueError {
                t.say([f"\"{raw_v}\" is not a number"]);
                return False;
            }
        }
    }
    i = find_interest(u, name, True);
    if i is None {
        t.say([f"\"{name}\" is not in your interest pool. Try /pool"]);
        return False;
    }
    w = u spawn update_interest(op=op, name=i.name, value=value, text=text);
    t.say(w.out);
    if op in ["confirm", "reject"] {
        u.derived = [n for n in u.derived if n != i.name];
    }
    if w.related {
        ask(u, t, {"type": "archive_related", "ids": w.related, "name": i.name}, f"\"{i.name}\" still has {len(w.related)} upcoming task(s). Cancel them too? (y/N)");
        return True;
    }
    return False;
}

"""Answer the previous follow-up question."""
def answer_pending(u: User, pend: dict, line: str, t: Turn) -> None {
    kind = pend.get("type", "");
    if kind == "cancel_reason" {
        (tk, b) = resolve_obj(u, pend.get("task", ""));
        if tk is not None {
            reason = "" if line.strip().lower() in SKIP else line;
            w = tk spawn task_action(action="cancel", reason_text=reason);
            t.say(w.out);
        }
    } elif kind == "archive_related" {
        if line.strip().lower() in YES {
            cancel_ids(u, pend.get("ids", []), t);
        }
    }
}

"""Slash commands."""
def run_command(u: User, line: str, t: Turn) -> None {
    parts = line[1:].split(" ", 1);
    cmd = parts[0].lower();
    rest = parts[1].strip() if len(parts) > 1 else "";
    args = rest.split();

    if cmd in ["quit", "exit", "q"] {
        t.quit = True;
        return;
    } elif cmd in ["help", "h", "?"] {
        t.raw(HELP);
        return;
    } elif cmd == "brief" {
        t.say((u spawn daily_brief()).out);
    } elif cmd == "digest" {
        t.say((u spawn profile_digest()).out);
    } elif cmd == "pool" {
        t.say(render_pool(u));
    } elif cmd == "week" {
        n = int(args[0]) if args and args[0].isdigit() else 7;
        t.say(render_week(u, n, "why" in args));
    } elif cmd == "why" {
        t.say(render_week(u, 7, True));
    } elif cmd == "tasks" {
        t.say(render_tasks(u));
    } elif cmd == "done" and args and args[0].lower() == "today" {
        t.say(complete_today(u));
    } elif cmd in ["done", "cancel", "postpone", "lock", "unlock", "quiz"] and args {
        (tk, b) = resolve_obj(u, args[0]);
        if tk is None {
            if cmd in ["lock", "unlock"] {
                if not cmd_interest(u, cmd, rest, False, t) {
                    after_turn(u, t);
                }
                return;
            }
            t.say([f"No item with id {args[0]}. Try /tasks"]);
            return;
        }
        bid = b.id if b is not None else "";
        if cmd == "done" {
            h = float(args[1]) if len(args) > 1 else 0.0;
            w = tk spawn task_action(action="done", block_id=bid, actual_h=h);
        } elif cmd == "cancel" {
            reason = " ".join(args[1:]);
            if not reason {
                ask(u, t, {"type": "cancel_reason", "task": tk.id}, CANCEL_ASK);
                return;
            }
            w = tk spawn task_action(action="cancel", reason_text=reason);
        } elif cmd == "postpone" {
            days = int(args[1]) if len(args) > 1 and args[1].isdigit() else 0;
            w = tk spawn task_action(action="postpone", block_id=bid, days=days);
        } elif cmd == "quiz" {
            if len(args) < 2 {
                t.say(["Usage: /quiz <id> <score like 8/10> [missed topics...]"]);
                return;
            }
            sc = parse_score(args[1]);
            if sc < 0 {
                try {
                    sc = float(args[1]);
                } except ValueError {
                    sc = 0.0;
                }
            }
            w = tk spawn task_action(action="quiz", block_id=bid, score=sc, wrong_topics=args[2:]);
        } else {
            w = tk spawn task_action(action=cmd);
        }
        t.say(w.out);
    } elif cmd in ["quizgen", "outline"] and rest {
        (tk, b) = resolve_obj(u, args[0]);
        i = interest_of(tk) if tk is not None else find_interest(u, rest);
        if i is None {
            t.say([f"Couldn't find \"{rest}\""]);
            return;
        }
        scope = tk.scope if tk is not None else "";
        if cmd == "quizgen" {
            n = int(args[-1]) if len(args) > 1 and args[-1].isdigit() else 5;
            qs = make_quiz(i.name, scope, i.weak_points, n);
            lines = [f"🧪 {i.name} self-test (when you're done, tell me your score and what you missed, e.g. quiz 8/10, missed xxx)"];
            for (k, q) in enumerate(qs) {
                lines.append(f"  {k + 1}. {q.question}  [{q.topic}]");
            }
            t.say(lines);
        } else {
            t.say([f"📋 {i.name} review outline"] + [f"  · {x}" for x in review_outline(i.name, scope, i.weak_points)]);
        }
    } elif cmd in ["weight", "budget", "short"] {
        op = "set_weight" if cmd == "weight" else cmd;
        if cmd_interest(u, op, rest, True, t) {
            return;
        }
    } elif cmd == "when" {
        if cmd_interest(u, "time", rest, True, t) {
            return;
        }
    } elif cmd in ["pause", "resume", "archive", "confirm", "reject"] and rest {
        if cmd_interest(u, cmd, rest, False, t) {
            return;
        }
    } elif cmd == "plan" {
        p = u spawn plan_week(verbose=True);
        t.say(["🧭 Replanned this week from your current interest pool:"] + p.out);
    } elif cmd == "sync" {
        s = u spawn sync();
        t.say(s.out or ["🧭 No pending changes"]);
        return;
    } elif cmd == "time" {
        if not rest or rest == "now" {
            u.clock = "";
        } elif rest.startswith("+") {
            n = float(rest[1:-1] or "1");
            unit = rest[-1];
            delta = timedelta(days=n) if unit == "d" else (timedelta(hours=n) if unit == "h" else timedelta(minutes=n));
            u.clock = fmt_dt(u.now() + delta);
        } else {
            try {
                u.clock = fmt_dt(to_dt(rest));
            } except ValueError {
                t.say(["Time format: YYYY-MM-DD HH:MM, or +3h / +1d / now"]);
                return;
            }
        }
        t.say([f"🕒 It is now {u.now_str()}" + (" (simulated time)" if u.clock else "")]);
    } elif cmd == "name" and rest {
        u.name = rest[:20];
        t.say([f"Got it, I'll call you {u.name} from now on"]);
        return;
    } elif cmd == "ai" {
        t.say([ai_status()]);
        return;
    } elif cmd in ["seed", "reset"] {
        name = u.name;
        wipe_user(u);
        CTX["user"] = None;
        nu = bootstrap(name);
        if cmd == "seed" {
            seed_demo(nu);
            t.say(["🧭 Sample data loaded"]);
        } else {
            t.say(["🧭 All data cleared"]);
        }
        t.user = nu;
        return;
    } else {
        t.say([f"Unknown command /{cmd}. Type /help to see the list"]);
        return;
    }
    after_turn(u, t);
}

"""Sync on page open / periodic refresh: time passing, missed blocks, reminders. Returns (sync output, reminder output)."""
def refresh_state(u: User) -> tuple {
    set_current_user(u);
    s = u spawn sync();
    u.derived = u.derived + [n for n in s.suggested if n not in u.derived];
    r = u spawn check_reminders();
    return (list(s.out), list(r.out));
}

def digest_lines(u: User) -> list[str] {
    set_current_user(u);
    return list((u spawn profile_digest()).out);
}

"""Handle one line of input (a CLI turn / one web send)."""
def handle_turn(u: User, line: str) -> Turn {
    set_current_user(u);
    t = Turn(user=u);
    line = line.strip();
    if u.pending {
        pend = u.pending;
        u.pending = {};
        answer_pending(u, pend, line, t);
        after_turn(u, t);
        return t;
    }
    if not line {
        return t;
    }
    if line.startswith("/") {
        run_command(u, line, t);
        return t;
    }
    # confirming a derived interest: [yes] [not now]
    ans = line.lower().rstrip(".!");
    if u.derived and (ans in CONFIRM or ans in REJECT) {
        name = u.derived[0];
        u.derived = u.derived[1:];
        op = "confirm" if ans in CONFIRM else "reject";
        if not cmd_interest(u, op, name, False, t) {
            after_turn(u, t);
        }
        return t;
    }
    c = u spawn chat(text=line);
    t.say(c.out);
    if c.ask.get("type") in ["cancel_reason", "archive_related"] {
        ask(u, t, dict(c.ask));
        return t;
    }
    after_turn(u, t);
    return t;
}

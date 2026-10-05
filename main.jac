"""Jac Companion - command-line entry point.

    jac run main.jac               interactive chat (data is persisted automatically in .jac/)
    jac run main.jac --demo        run every example from the README with a built-in script (nothing is persisted)
    jac run main.jac --offline     force the rule engine; never call the LLM
    jac run main.jac --reset       wipe the data and start over
    jac run main.jac --now "2026-09-28 08:00"   use a simulated time
"""

import sys;
import from user.user { User, CTX, current_user, set_current_user }
import from user.session { Turn, handle_turn }
import from sync.sync { sync }
import from notify.brief { daily_brief }
import from notify.reminders { check_reminders }
import from ai.llm { ai_status, set_offline }
import from data.seed { seed_demo }
import from common.graph { bootstrap, wipe_user }

glob RAW_PREFIX: list = ["☀️", "📊", "📅", "🗂️", "🧭", "⏰", "Just talk", "I'm not quite sure"];

"""Print a reply: the first line gets 🧭, the rest are indented."""
def say(lines: list[str]) -> None {
    if not lines {
        return;
    }
    raw = any([lines[0].startswith(p) for p in RAW_PREFIX]);
    for (k, line) in enumerate(lines) {
        if raw {
            print(line);
        } elif k == 0 {
            print(f"🧭 {line}");
        } else {
            print(f"   {line}" if line else "");
        }
    }
}

def more(lines: list[str]) -> None {
    for line in lines {
        print(f"   {line}");
    }
}

def show(t: Turn) -> None {
    for seg in t.segments {
        if seg.style == "say" {
            say(seg.lines);
        } elif seg.style == "more" {
            more(seg.lines);
        } else {
            for line in seg.lines {
                print(line);
            }
        }
    }
}

def read_line(prompt: str) -> str | None {
    try {
        return input(prompt);
    } except (EOFError, KeyboardInterrupt) {
        return None;
    }
}

def startup(u: User) -> None {
    set_current_user(u);
    print(f"{ai_status()} · type /help for commands, /quit to exit");
    s = u spawn sync();
    r = u spawn check_reminders();
    if u.last_brief_day != u.now().date().isoformat() {
        print("");
        say((u spawn daily_brief()).out);
    }
    if s.out or r.out {
        print("");
        for line in s.out + r.out {
            print(line);
        }
    }
    u.derived = list(s.suggested);
}

def onboarding() -> User {
    print("👋 Hi! I'm Jac Companion, a personal assistant that sticks with you and gets to know you better over time.");
    name = read_line("What should I call you? > ");
    name = (name or "").strip() or "friend";
    ans = read_line("Load some sample data (courses, a paper, running, vocab...) to try things out? (Y/n) > ");
    u = bootstrap(name);
    if ans is None or ans.strip().lower() not in ["n", "no", "nope"] {
        seed_demo(u);
        print("🧭 Sample data loaded.");
    } else {
        print("🧭 OK! Start by telling me what you're learning, what keeps you busy, and what you enjoy.");
    }
    return u;
}

glob DEMO_SCRIPT: list = [
    "I'm learning guitar, want to practice 3 hours a week, evenings are best",
    "Cancel the next guitar session",
    "Don't want to practice anymore, lost interest",
    "Cancel tonight's run",
    "Too busy this week",
    "STATS 413 midterm 10/1 3pm, covers lecture 1-6",
    "/week 3 why",
    "/time 2026-09-28 23:30",
    "All done for today",
    "/time 2026-09-29 23:30",
    "All done for today",
    "/time 2026-09-30 21:40",
    "Quiz done, 8/10, missed multicollinearity and residual plots",
    "STATS 413 HW3 done, took 4 hours",
    "Submit the diffusion model lab report by 10/5",
    "yes",
    "/time 2026-10-02 08:00",
    "/digest",
    "/pool"
];

"""--demo: run through the README examples in order, in a temporary world that is not persisted."""
def run_demo() -> None {
    u = bootstrap("Jerry", False, "2026-09-28 08:00");
    seed_demo(u);
    print("🎬 Demo mode: simulated time Mon 2026-09-28 08:00, sample data loaded\n");
    startup(u);
    asking = False;
    for line in DEMO_SCRIPT {
        if not asking {
            print("");
        }
        print(f"You > {line}");
        t = handle_turn(u, line);
        show(t);
        asking = t.asking;
        if t.user is not None {
            u = t.user;
        }
    }
}

with entry {
    try {
        sys.stdout.reconfigure(encoding="utf-8");
    } except Exception {}
    argv = sys.argv[1:];
    if "--offline" in argv {
        set_offline(True);
    }
    if "--demo" in argv {
        run_demo();
    } else {
        u = current_user();
        if u is not None and "--reset" in argv {
            wipe_user(u);
            CTX["user"] = None;
            u = None;
        }
        if u is None {
            u = onboarding();
        }
        if "--now" in argv {
            idx = argv.index("--now");
            if idx + 1 < len(argv) {
                u.clock = argv[idx + 1];
            }
        }
        startup(u);
        asking = False;
        while True {
            if not asking {
                print("");
            }
            line = read_line("You > ");
            if line is None {
                break;
            }
            t = handle_turn(u, line);
            show(t);
            if t.quit {
                break;
            }
            asking = t.asking;
            if t.user is not None {
                u = t.user;
            }
        }
        print("👋 Bye! Your data is saved.");
    }
}

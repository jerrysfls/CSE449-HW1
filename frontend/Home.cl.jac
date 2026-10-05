"""Main screen (stateful shell): owns all state and server calls, and passes data and callbacks down to each page.

Every action ends up as one line of "input" (natural language or a /command) sent via send_message.
The server returns the reply plus the latest Dashboard, so the UI always behaves exactly like the CLI.
"""

import from react { useEffect }
import from "@jac/runtime" { jacLogout }
import from .views.Common { NavItem, joined }
import from .views.Today { TodayView }
import from .views.Week { WeekView }
import from .views.Pool { PoolView }
import from .views.Chat { ChatView }
import from .views.Me { MeView }
import from .views.Sheet { ItemSheet }

sv import from ..services.companion {
    Dashboard, Reply, Msg, ItemView, get_dashboard, send_message, get_digest, setup_profile
}

glob _NL: str = chr(10);

glob TABS: list = [
    {"id": "today", "label": "Today", "icon": "☀️"},
    {"id": "week", "label": "This week", "icon": "📅"},
    {"id": "pool", "label": "Interests", "icon": "🎯"},
    {"id": "chat", "label": "Chat", "icon": "💬"},
    {"id": "me", "label": "Me", "icon": "🙂"}
];

def:pub Home(onLogout: Callable[[], None]) -> JsxElement {
    has dash: Dashboard | None = None,
        tab: str = "today",
        log: list[dict] = [],
        busy: bool = False,
        toast: str = "",
        digest: list[str] = [],
        sheet: ItemView | None = None,
        error: str = "";

    async def refresh() -> None {
        d: Dashboard | None = None;
        try {
            d = await get_dashboard();
            dash = d;
            error = "";
        } except Exception as ex {
            if "UNAUTHORIZED" in str(ex) or "401" in str(ex) {
                jacLogout();
                onLogout();
                return;
            }
            error = "Can't reach the server. Please try again later.";
        }
    }

    # Load on mount, then sync every minute (clock advance, reminders)
    useEffect(lambda {
        refresh();
        timer = setInterval(lambda { refresh(); }, 60000);
        return lambda { clearInterval(timer); };
    }, []);

    def show_toast(msgs: list[Msg]) -> None {
        lines: list[str] = [];
        for m in msgs {
            lines = lines + m.lines;
        }
        toast = joined(lines[:8], _NL) + ("…" if len(lines) > 8 else "");
        setTimeout(lambda { toast = ""; }, 6000);
    }

    """Send a message or command. quiet=True skips the toast (the reply is already visible in Chat)."""
    async def run(text: str, quiet: bool = False) -> None {
        r: Reply | None = None;
        if not text.strip() or busy {
            return;
        }
        busy = True;
        mine = {"who": "me", "text": text};
        pending_log = log + [mine];
        log = pending_log;
        try {
            r = await send_message(text);
        } except Exception as ex {
            busy = False;
            error = "Couldn't send. Check your connection.";
            return;
        }
        busy = False;
        if r is not None {
            if r.dash is not None {
                dash = r.dash;
            }
            log = pending_log + [{"who": "bot", "msgs": r.messages, "asking": r.asking}];
            if not quiet and r.messages {
                show_toast(r.messages);
            }
        }
    }

    def run_cmd(text: str) -> None {
        run(text, tab == "chat");
    }

    def ask_in_chat(text: str) -> None {
        tab = "chat";
        run(text, True);
    }

    async def load_digest() -> None {
        lines: list[str] = [];
        try {
            lines = await get_digest();
            digest = lines;
        } except Exception as ex {
            digest = ["Couldn't load your profile summary"];
        }
    }

    async def do_setup(name: str, demo: bool) -> None {
        d: Dashboard | None = None;
        busy = True;
        try {
            d = await setup_profile(name, demo);
            dash = d;
        } except Exception as ex {
            error = "Couldn't save";
        }
        busy = False;
    }

    def logout() -> None {
        jacLogout();
        onLogout();
    }

    def open_item(item: ItemView) -> None {
        sheet = item;
    }

    def done_item(item: ItemView) -> None {
        run("/done " + item.id);
    }

    page = <div className="loading">{error or "Loading…"}</div>;
    if dash is not None {
        if tab == "week" {
            page = <WeekView dash={dash} onOpen={open_item} onDone={done_item} onRun={run_cmd} />;
        } elif tab == "pool" {
            page = <PoolView dash={dash} busy={busy} onRun={run_cmd} onAsk={ask_in_chat} onTab={lambda t: str { tab = t; }} />;
        } elif tab == "me" {
            page = <MeView dash={dash} digest={digest} busy={busy} onLoadDigest={load_digest} onRun={run_cmd} onLogout={logout} />;
        } else {
            page = <TodayView
                dash={dash}
                busy={busy}
                onOpen={open_item}
                onDone={done_item}
                onRun={run_cmd}
                onTab={lambda t: str { tab = t; }}
                onSetup={do_setup}
            />;
        }
    }

    return <div className={"app on-chat" if tab == "chat" else "app"}>
        <nav className="nav">
            <div className="nav-brand">
                🧭 Jac Companion
                <small>{dash.name if dash is not None else ""}</small>
            </div>
            {for t in TABS {
                <NavItem
                    key={t["id"]}
                    id={t["id"]}
                    label={t["label"]}
                    icon={t["icon"]}
                    active={tab == t["id"]}
                    onPick={lambda v: str { tab = v; }}
                />
            }}
        </nav>
        <main className="main">
            {error and dash is not None and <div className="banner warn">⚠️ {error}</div>}
            {page}
        </main>
        <aside className="chat-panel">
            <ChatView
                log={log}
                busy={busy}
                question={dash.question if dash is not None else ""}
                derived={dash.derived if dash is not None else []}
                onSend={lambda text: str { run(text, True); }}
            />
        </aside>
        {sheet is not None and <ItemSheet
            item={sheet}
            onClose={lambda { sheet = None; }}
            onRun={run_cmd}
            onAsk={ask_in_chat}
        />}
        {toast and <div className="toast">
            <button className="x" onClick={lambda e: MouseEvent { toast = ""; }}>✕</button>
            {toast}
        </div>}
    </div>;
}

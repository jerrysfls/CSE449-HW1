"""Chat: just like the CLI, talk in plain language or use /commands. Pinned to the right side on desktop."""

import from .Common { joined }

sv import from ...services.companion { Msg }

glob _NL: str = chr(10);

glob SUGGEST: list[str] = [
    "What's on today?",
    "I'm learning guitar, want to practice 3 hours a week, evenings are best",
    "EECS 442 midterm 10/10 3pm, covers lecture 1-8",
    "Cancel tonight's run",
    "Quiz done, 8/10, missed convolution",
    "Give me some advice",
    "/help"
];

def:pub Bubble(row: dict) -> JsxElement {
    if row["who"] == "me" {
        return <div className="bubble me">{row["text"]}</div>;
    }
    msgs = (row["msgs"] or []) as list[Msg];
    return <div className="bubble bot">
        {len(msgs) == 0 and <span className="muted">(Nothing to update)</span>}
        {for (k, m) in enumerate(msgs) {
            <div key={str(k)} className={"" if m.style == "say" else m.style}>{joined(m.lines, _NL)}</div>
        }}
    </div>;
}

def:pub ChatView(
    log: list[dict],
    busy: bool,
    question: str,
    derived: list[str],
    onSend: Callable[[str], None]
) -> JsxElement {
    has draft: str = "";

    # Scroll to the bottom when new messages arrive
    can with (log, busy) entry {
        el: any = document.querySelector(".chat-log");
        if el {
            el.scrollTop = el.scrollHeight;
        }
    }

    def send(e: FormEvent) -> None {
        e.preventDefault();
        text = draft.strip();
        if question and not text {
            onSend("skip");
            return;
        }
        if text {
            onSend(text);
            draft = "";
        }
    }

    def suggest(text: str) -> None {
        onSend(text);
    }

    hint = "Answer the question above (send empty to skip)" if question else "Say something, or type /help";

    return <div className="chat">
        <div className="chat-head">
            <div className="avatar">🧭</div>
            <div>
                <b>Companion</b>
                <div className="muted small">{"Thinking…" if busy else "Just talk, or use /commands"}</div>
            </div>
        </div>
        <div className="chat-log">
            <div className="bubble bot">
                Hi! Just tell me what's going on, for example:{_NL}
                · I'm learning guitar, want to practice 3 hours a week{_NL}
                · STATS 413 midterm 10/1 3pm{_NL}
                · Cancel tonight's run / All done for today{_NL}
                I'll fit things into your schedule and tune your interests based on your feedback.
            </div>
            {for (k, row) in enumerate(log) {
                <Bubble key={str(k)} row={row} />
            }}
            {busy and <div className="bubble bot typing">…</div>}
        </div>
        {question and <div className="banner" style={{"margin": "0 12px 8px"}}>❓ {question}</div>}
        <div className="chat-suggest">
            {for name in derived {
                <button key={"y" + name} className="chip brand" onClick={lambda e: MouseEvent { suggest("yes"); }}>Add "{name}"</button>
            }}
            {for name in derived {
                <button key={"n" + name} className="chip" onClick={lambda e: MouseEvent { suggest("not now"); }}>Not now: "{name}"</button>
            }}
            {question and <button className="chip brand" onClick={lambda e: MouseEvent { suggest("Too busy"); }}>Too busy</button>}
            {question and <button className="chip brand" onClick={lambda e: MouseEvent { suggest("Lost interest"); }}>Lost interest</button>}
            {question and <button className="chip brand" onClick={lambda e: MouseEvent { suggest("No longer needed"); }}>No longer needed</button>}
            {not question and len(derived) == 0 and [
                <button key={s} className="chip" onClick={lambda e: MouseEvent { suggest(s); }}>{s}</button>
                for s in SUGGEST
            ]}
        </div>
        <form className="chat-input" onSubmit={send}>
            <input
                className="input"
                placeholder={hint}
                value={draft}
                onChange={lambda e: ChangeEvent { draft = e.target.value; }}
            />
            <button className="btn primary" type="submit" disabled={busy}>Send</button>
        </form>
    </div>;
}

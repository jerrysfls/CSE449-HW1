"""Action sheet shown when you tap a schedule item: done / postpone / cancel (with a reason) / log quiz / lock."""

sv import from ...services.companion { ItemView }

glob REASONS: list[str] = ["Too busy", "Lost interest", "No longer needed", "Other"];

def:pub ItemSheet(
    item: ItemView,
    onClose: Callable[[], None],
    onRun: Callable[[str], None],
    onAsk: Callable[[str], None]
) -> JsxElement {
    has step: str = "main",
        score: str = "",
        topics: str = "";

    def act(text: str) -> None {
        onRun(text);
        onClose();
    }

    def ask(text: str) -> None {
        onAsk(text);
        onClose();
    }

    def stop(e: MouseEvent) -> None {
        e.stopPropagation();
    }

    def submit_quiz(e: FormEvent) -> None {
        e.preventDefault();
        if score.strip() {
            act("/quiz " + item.id + " " + score.strip() + (" " + topics.strip().replace(",", " ") if topics.strip() else ""));
        }
    }

    is_block = item.kind == "block";
    open_ = not item.done and not item.skipped;
    target = item.id if is_block else item.task_id;
    when = item.time + ("–" + item.end + " · " + item.duration if is_block else "");

    body = <div />;
    if step == "cancel" {
        body = <div>
            <p className="muted">Why cancel? Your reason shapes your interests: "Lost interest" lowers its priority, "Too busy" just moves things around.</p>
            <div className="reasons">
                {for r in REASONS {
                    <button key={r} className="btn" onClick={lambda e: MouseEvent { act("/cancel " + target + " " + r); }}>{r}</button>
                }}
            </div>
            <div className="actions"><button className="btn ghost" onClick={lambda e: MouseEvent { step = "main"; }}>← Back</button></div>
        </div>;
    } elif step == "quiz" {
        body = <form onSubmit={submit_quiz}>
            <p className="muted">Your score updates mastery. Missed topics become weak spots and get extra review later.</p>
            <input className="input" placeholder="Score, e.g. 8/10" value={score} onChange={lambda e: ChangeEvent { score = e.target.value; }} />
            <input
                className="input"
                style={{"marginTop": "8px"}}
                placeholder="Missed topics (space-separated, optional)"
                value={topics}
                onChange={lambda e: ChangeEvent { topics = e.target.value; }}
            />
            <div className="actions">
                <button className="btn ghost" type="button" onClick={lambda e: MouseEvent { step = "main"; }}>← Back</button>
                <button className="btn primary" type="submit">Save</button>
            </div>
        </form>;
    } else {
        body = <div>
            {item.why and <div className="why">💡 {item.why}</div>}
            <div className="actions">
                {open_ and <button className="btn ok" onClick={lambda e: MouseEvent { act("/done " + target); }}>✅ Done</button>}
                {open_ and is_block and <button className="btn" onClick={lambda e: MouseEvent { act("/postpone " + target); }}>⏭ Postpone</button>}
                {open_ and <button className="btn danger" onClick={lambda e: MouseEvent { step = "cancel"; }}>✖ Cancel</button>}
                {open_ and item.quiz and <button className="btn" onClick={lambda e: MouseEvent { step = "quiz"; }}>🧪 Log quiz</button>}
                {item.interest and <button className="btn" onClick={lambda e: MouseEvent { ask("/quizgen " + item.task_id); }}>🧪 Practice quiz</button>}
                {item.interest and <button className="btn" onClick={lambda e: MouseEvent { ask("/outline " + item.task_id); }}>📋 Review outline</button>}
                <button className="btn" onClick={lambda e: MouseEvent { act(("/unlock " if item.locked else "/lock ") + item.task_id); }}>
                    {"🔓 Unlock" if item.locked else "🔒 Lock (no auto-changes)"}
                </button>
                <button className="btn ghost" onClick={lambda e: MouseEvent { onClose(); }}>Close</button>
            </div>
        </div>;
    }

    return <div className="sheet-mask" onClick={lambda e: MouseEvent { onClose(); }}>
        <div className="sheet" onClick={stop}>
            <div className="row">
                <span style={{"fontSize": "26px"}}>{item.icon}</span>
                <div style={{"flex": "1", "minWidth": "0"}}>
                    <h3>{item.title}</h3>
                    <div className="muted small">
                        {when}
                        {item.interest and " · " + item.interest}
                        {item.done and " · ✅ Done"}
                        {item.skipped and " · Skipped"}
                    </div>
                </div>
            </div>
            {body}
        </div>
    </div>;
}

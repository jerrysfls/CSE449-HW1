"""Today: greeting, today's progress, open questions, alerts, timeline and upcoming deadlines."""

import from .Common { ItemRow, Bar, joined }

sv import from ...services.companion { Dashboard, ItemView, TaskView }

"""First sign-in: set a name and choose whether to load sample data."""
def:pub Welcome(busy: bool, onSetup: Callable[[str, bool], None]) -> JsxElement {
    has name: str = "";

    return <div className="card">
        <div className="card-title">👋 Welcome! Let's get to know you</div>
        <p className="muted small" style={{"marginTop": 0}}>
            I'll plan your schedule around your interests (what you're learning, working on and enjoy) and tasks (exams, assignments, meetings).
            Everything you finish, cancel or postpone feeds back into your interests.
        </p>
        <input
            className="input"
            placeholder="What should I call you?"
            value={name}
            onChange={lambda e: ChangeEvent { name = e.target.value; }}
        />
        <div className="row" style={{"marginTop": "10px"}}>
            <button className="btn primary" disabled={busy} onClick={lambda e: MouseEvent { onSetup(name, True); }}>
                Try with sample data
            </button>
            <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onSetup(name, False); }}>
                Start fresh
            </button>
        </div>
    </div>;
}

def:pub Deadline(t: TaskView) -> JsxElement {
    hot = t.days_left <= 2;
    return <div className="deadline">
        <div className={"days hot" if hot else "days"}>
            <b>{"Today" if t.days_left <= 0 else str(t.days_left)}</b>
            {"" if t.days_left <= 0 else ("day" if t.days_left == 1 else "days")}
        </div>
        <div style={{"flex": "1", "minWidth": "0"}}>
            <div>{t.icon} {t.title}</div>
            <div className="muted small">
                {t.due_label}
                {t.blocks_left > 0 and " · " + str(t.blocks_left) + (" prep session left" if t.blocks_left == 1 else " prep sessions left")}
            </div>
        </div>
    </div>;
}

def:pub TodayView(
    dash: Dashboard,
    busy: bool,
    onOpen: Callable[[ItemView], None],
    onDone: Callable[[ItemView], None],
    onRun: Callable[[str], None],
    onTab: Callable[[str], None],
    onSetup: Callable[[str, bool], None]
) -> JsxElement {
    total = dash.today_total;
    ratio = dash.today_done / total if total > 0 else 0.0;
    now_hm = dash.now[-5:];

    return <div>
        <div className="hero">
            <div className="row">
                <h1>{dash.greeting}</h1>
                <span className="spacer" />
                {dash.simulated and <span className="chip">🕒 Simulated time</span>}
            </div>
            <div className="when">{dash.now_label} · {"🤖 AI on" if dash.ai_on else "🧩 Offline rule mode"}</div>
            <div className="stats">
                <div className="stat"><b>{str(dash.today_done)}/{str(total)}</b><span>Done today</span></div>
                <div className="stat"><b>{dash.week_h}</b><span>This week</span></div>
                <div className="stat"><b>{str(dash.completion)}%</b><span>2-week rate</span></div>
            </div>
            <Bar value={ratio} />
        </div>

        {dash.fresh and <Welcome busy={busy} onSetup={onSetup} />}

        {dash.question and <div className="banner">
            <span>❓</span>
            <span style={{"flex": "1"}}>{dash.question}</span>
            <button className="btn" onClick={lambda e: MouseEvent { onTab("chat"); }}>Answer</button>
        </div>}

        {for name in dash.derived {
            <div className="banner" key={"d-" + name}>
                <span>💡</span>
                <span style={{"flex": "1"}}>Add "{name}" to your interests?</span>
                <button className="btn primary" disabled={busy} onClick={lambda e: MouseEvent { onRun("/confirm " + name); }}>Add</button>
                <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onRun("/reject " + name); }}>Not now</button>
            </div>
        }}

        {for (k, a) in enumerate(dash.alerts) {
            <div className="banner warn" key={"a-" + str(k)}><span>⚠️</span><span>{a}</span></div>
        }}

        {for (k, m) in enumerate(dash.notices) {
            <div className="banner ok" key={"n-" + str(k)}>
                <span>🔔</span>
                <span style={{"whiteSpace": "pre-wrap"}}>{joined(m.lines, chr(10))}</span>
            </div>
        }}

        <div className="card">
            <div className="card-title">
                <span>📌 Today's plan</span>
                <span className="aside">{dash.week[0].hours if dash.week else ""}</span>
            </div>
            {len(dash.today) == 0 and <div className="empty">Nothing planned today. Enjoy the break 🌿</div>}
            <ul className="timeline">
                {for it in dash.today {
                    <ItemRow
                        key={it.kind + it.id}
                        item={it}
                        onOpen={onOpen}
                        onDone={onDone}
                        isNow={it.kind == "block" and it.time <= now_hm and now_hm < it.end and not it.done}
                    />
                }}
            </ul>
            {total > dash.today_done and <div className="row" style={{"marginTop": "10px"}}>
                <span className="muted small">Or report it all at once tonight</span>
                <span className="spacer" />
                <button className="btn ok" disabled={busy} onClick={lambda e: MouseEvent { onRun("/done today"); }}>
                    ✓ All done today
                </button>
            </div>}
        </div>

        <div className="card">
            <div className="card-title">
                <span>⏰ Coming up</span>
                <button className="btn ghost small" onClick={lambda e: MouseEvent { onTab("week"); }}>This week →</button>
            </div>
            {len(dash.upcoming) == 0 and <div className="empty">No deadlines in the next 7 days</div>}
            {for t in dash.upcoming {
                <Deadline key={t.id} t={t} />
            }}
        </div>
    </div>;
}

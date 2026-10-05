"""Me: profile summary, workload, time travel (simulated clock), data and account."""

import from .Common { Bar }

sv import from ...services.companion { Dashboard }

def:pub MeView(
    dash: Dashboard,
    digest: list[str],
    busy: bool,
    onLoadDigest: Callable[[], None],
    onRun: Callable[[str], None],
    onLogout: Callable[[], None]
) -> JsxElement {
    has name: str = "",
        clock: str = "";

    can with entry {
        onLoadDigest();
    }

    def confirm_run(text: str, question: str) -> None {
        if window.confirm(question) {
            onRun(text);
        }
    }

    load = dash.load_pct / 100.0;

    return <div>
        <div className="page-title">{dash.name}</div>
        <p className="page-sub">{dash.ai}</p>

        <div className="card">
            <div className="card-title"><span>📊 Workload</span><span className="aside">{dash.week_h} / {dash.comfort_h}</span></div>
            <Bar value={load} tone={"warn" if dash.load_pct >= 100 else ""} />
            <div className="row muted small" style={{"marginTop": "8px"}}>
                <span>{dash.week_h} this week</span>
                <span className="spacer" />
                <span>2-week completion {str(dash.completion)}%</span>
            </div>
        </div>

        <div className="card">
            <div className="card-title">
                <span>🧭 About you</span>
                <button className="btn ghost" onClick={lambda e: MouseEvent { onLoadDigest(); }}>Refresh</button>
            </div>
            {len(digest) == 0 and <div className="empty">Generating…</div>}
            <div style={{"whiteSpace": "pre-wrap", "fontSize": "13px"}}>
                {for (k, line) in enumerate(digest[1:]) {
                    <div key={str(k)} className={"" if line.startswith("  ·") or line.startswith("💬") else "muted"}>{line}</div>
                }}
            </div>
        </div>

        <div className="card">
            <div className="card-title">
                <span>🕒 Clock</span>
                <span className="aside">{dash.now_label}{" · simulated" if dash.simulated else ""}</span>
            </div>
            <p className="muted small" style={{"marginTop": 0}}>
                Move the clock forward to watch missed tasks get skipped, interest heat fade, and reminders fire (for demos).
            </p>
            <div className="row wrap">
                <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onRun("/time +3h"); }}>+3 hours</button>
                <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onRun("/time +1d"); }}>+1 day</button>
                <button className="btn" disabled={busy or not dash.simulated} onClick={lambda e: MouseEvent { onRun("/time now"); }}>Back to now</button>
            </div>
            <div className="row" style={{"marginTop": "8px"}}>
                <input
                    className="input"
                    placeholder="2026-10-02 08:00"
                    value={clock}
                    onChange={lambda e: ChangeEvent { clock = e.target.value; }}
                />
                <button className="btn" disabled={busy or not clock.strip()} onClick={lambda e: MouseEvent { onRun("/time " + clock.strip()); }}>Go</button>
            </div>
        </div>

        <div className="card">
            <div className="card-title"><span>⚙️ Settings</span></div>
            <div className="row">
                <input
                    className="input"
                    placeholder={"Your name (now: " + dash.name + ")"}
                    value={name}
                    onChange={lambda e: ChangeEvent { name = e.target.value; }}
                />
                <button className="btn" disabled={busy or not name.strip()} onClick={lambda e: MouseEvent { onRun("/name " + name.strip()); }}>Save</button>
            </div>
            <div className="row wrap" style={{"marginTop": "10px"}}>
                <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onRun("/plan"); }}>🔄 Replan week</button>
                <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { confirm_run("/seed", "Clear your current data and load sample data?"); }}>📦 Load sample data</button>
                <button className="btn danger" disabled={busy} onClick={lambda e: MouseEvent { confirm_run("/reset", "Clear all your data? This can't be undone."); }}>Clear data</button>
            </div>
        </div>

        <button className="btn block" onClick={lambda e: MouseEvent { onLogout(); }}>Sign out</button>
        <p className="muted small" style={{"textAlign": "center", "marginTop": "16px"}}>
            Jac Companion · EECS 449 · Built full-stack with Jac (Web / PWA / Android)
        </p>
    </div>;
}

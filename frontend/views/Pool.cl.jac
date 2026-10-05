"""Interests: view and tune each interest's priority, heat, mastery, weekly hours and preferred time.

Every tweak becomes a command (/weight, /budget, /when, /pause, ...) and the server replans with the same rules.
"""

import from .Common { Bar }

sv import from ...services.companion { Dashboard, InterestView }

glob TIME_LABEL: dict = {"": "Any time", "morning": "Morning", "afternoon": "Afternoon", "evening": "Evening"};

def fmt1(x: float) -> str {
    return f"{x:.1f}";
}

def fmt2(x: float) -> str {
    return f"{x:.2f}";
}

def:pub InterestCard(
    i: InterestView,
    busy: bool,
    onRun: Callable[[str], None],
    onAsk: Callable[[str], None]
) -> JsxElement {
    def cmd(op: str, value: str = "") -> None {
        onRun("/" + op + " " + i.name + (" " + value if value else ""));
    }

    def pick_time(e: ChangeEvent) -> None {
        v = e.target.value;
        if v {
            cmd("when", v);
        }
    }

    w_down = fmt1(max(0.0, i.weight - 0.1));
    w_up = fmt1(min(1.0, i.weight + 0.1));
    b_down = fmt1(max(0.0, i.budget_h - 0.5));
    b_up = fmt1(i.budget_h + 0.5);
    active = i.status == "ACTIVE";
    cls = "card interest";
    if i.status == "PAUSED" {
        cls = cls + " paused";
    }
    if i.status == "ARCHIVED" {
        cls = cls + " archived";
    }
    if i.pending {
        cls = cls + " pending";
    }
    idle_note = "";
    if active and i.idle_days >= 4 and i.kind in ["HOBBY", "HABIT"] {
        idle_note = "Idle " + str(i.idle_days) + (" day" if i.idle_days == 1 else " days");
    }

    return <div className={cls}>
        <div className="head">
            <div className="emoji">{i.icon}</div>
            <div style={{"flex": "1", "minWidth": "0"}}>
                <div className="name">{i.name} {i.locked and "🔒"}</div>
                <div className="row wrap" style={{"gap": "4px"}}>
                    <span className="chip">{i.kind_label}</span>
                    {i.status == "PAUSED" and <span className="chip warn">Paused</span>}
                    {i.status == "ARCHIVED" and <span className="chip">Archived</span>}
                    {i.pending and <span className="chip brand">Pending</span>}
                    {idle_note and <span className="chip bad">{idle_note}</span>}
                </div>
            </div>
            <span title="Heat">{i.flames}</span>
        </div>

        {i.pending and <div className="row">
            <span className="muted small" style={{"flex": "1"}}>Spotted in your recent tasks. It won't be scheduled until you add it.</span>
            <button className="btn primary" disabled={busy} onClick={lambda e: MouseEvent { cmd("confirm"); }}>Add</button>
            <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { cmd("reject"); }}>No thanks</button>
        </div>}

        <div className="metric"><span>Heat</span><Bar value={i.heat} tone="heat" /><b>{fmt2(i.heat)}</b></div>
        {i.is_study and <div className="metric"><span>Mastery</span><Bar value={i.mastery} tone="ok" /><b>{fmt2(i.mastery)}</b></div>}
        {len(i.weak_points) > 0 and <div className="row wrap" style={{"gap": "4px"}}>
            <span className="muted small">Weak spots</span>
            {for wp in i.weak_points {
                <span className="chip bad" key={wp}>{wp}</span>
            }}
        </div>}

        <div className="setting">
            <span>Priority</span>
            <div className="stepper">
                <button className="btn icon" disabled={busy or i.locked} onClick={lambda e: MouseEvent { cmd("weight", w_down); }}>−</button>
                <b>{fmt2(i.weight)}</b>
                <button className="btn icon" disabled={busy or i.locked} onClick={lambda e: MouseEvent { cmd("weight", w_up); }}>+</button>
            </div>
        </div>
        <div className="setting">
            <span>Weekly hours {i.budget and i.budget_h > 0 and "(actual " + i.budget + ")"}</span>
            <div className="stepper">
                <button className="btn icon" disabled={busy or i.locked} onClick={lambda e: MouseEvent { cmd("budget", b_down); }}>−</button>
                <b>{fmt1(i.budget_h) + "h" if i.budget_h > 0 else "Auto"}</b>
                <button className="btn icon" disabled={busy or i.locked} onClick={lambda e: MouseEvent { cmd("budget", b_up); }}>+</button>
            </div>
        </div>
        <div className="setting">
            <span>Preferred time</span>
            <select className="select" value={i.preferred_time} disabled={busy or i.locked} onChange={pick_time}>
                <option value="">{TIME_LABEL[""]}</option>
                <option value="morning">{TIME_LABEL["morning"]}</option>
                <option value="afternoon">{TIME_LABEL["afternoon"]}</option>
                <option value="evening">{TIME_LABEL["evening"]}</option>
            </select>
        </div>

        <div className="row wrap" style={{"gap": "6px"}}>
            <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { cmd("pause" if active else "resume"); }}>
                {"⏸ Pause" if active else "▶️ Resume"}
            </button>
            <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { cmd("unlock" if i.locked else "lock"); }}>
                {"🔓 Unlock" if i.locked else "🔒 Lock"}
            </button>
            {i.is_study and <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onAsk("/quizgen " + i.name); }}>🧪 Quiz me</button>}
            {i.is_study and <button className="btn" disabled={busy} onClick={lambda e: MouseEvent { onAsk("/outline " + i.name); }}>📋 Outline</button>}
            <span className="spacer" />
            {i.status != "ARCHIVED" and <button className="btn ghost" disabled={busy} onClick={lambda e: MouseEvent { onAsk("/archive " + i.name); }}>Archive</button>}
        </div>
    </div>;
}

def:pub PoolView(
    dash: Dashboard,
    busy: bool,
    onRun: Callable[[str], None],
    onAsk: Callable[[str], None],
    onTab: Callable[[str], None]
) -> JsxElement {
    return <div>
        <div className="row">
            <div>
                <div className="page-title">Interests</div>
                <p className="page-sub">Priority × heat × mastery decides how your week is split</p>
            </div>
            <span className="spacer" />
            <button className="btn primary" onClick={lambda e: MouseEvent { onTab("chat"); }}>+ Add</button>
        </div>
        {len(dash.interests) == 0 and <div className="card empty">
            No interests yet. Head to Chat and tell me something like:<br />
            "I'm learning guitar, want to practice 3 hours a week, evenings are best"
        </div>}
        <div className="pool">
            {for i in dash.interests {
                <InterestCard key={i.name} i={i} busy={busy} onRun={onRun} onAsk={onAsk} />
            }}
        </div>
    </div>;
}

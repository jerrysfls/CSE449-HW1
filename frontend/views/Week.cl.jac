"""This week: the next 7 days of schedule, optionally showing "why it's here" for each time block."""

import from .Common { ItemRow }

sv import from ...services.companion { Dashboard, ItemView, DayView }

def:pub WeekView(
    dash: Dashboard,
    onOpen: Callable[[ItemView], None],
    onDone: Callable[[ItemView], None],
    onRun: Callable[[str], None]
) -> JsxElement {
    has showWhy: bool = False;

    return <div>
        <div className="row">
            <div>
                <div className="page-title">This week</div>
                <p className="page-sub">{dash.week_h} scheduled · comfort range {dash.comfort_h}</p>
            </div>
            <span className="spacer" />
            <div className="toggle">
                <button className={"" if showWhy else "on"} onClick={lambda e: MouseEvent { showWhy = False; }}>Simple</button>
                <button className={"on" if showWhy else ""} onClick={lambda e: MouseEvent { showWhy = True; }}>Why?</button>
            </div>
        </div>
        {for day in dash.week {
            <div key={day.date}>
                <div className={"day-head today" if day.is_today else "day-head"}>
                    <b>{day.label}{" · Today" if day.is_today else ""}</b>
                    <span className="muted small">{day.hours}</span>
                </div>
                <div className="card" style={{"padding": "6px 10px"}}>
                    {len(day.items) == 0 and <div className="empty">Free 🌿</div>}
                    <ul className="timeline">
                        {for it in day.items {
                            <ItemRow key={it.kind + it.id} item={it} onOpen={onOpen} onDone={onDone} showWhy={showWhy} />
                        }}
                    </ul>
                </div>
            </div>
        }}
        <div className="row" style={{"justifyContent": "center", "marginTop": "8px"}}>
            <button className="btn" onClick={lambda e: MouseEvent { onRun("/plan"); }}>🔄 Replan week from interests</button>
        </div>
    </div>;
}

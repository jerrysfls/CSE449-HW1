"""Small components shared across pages."""

sv import from ...services.companion { ItemView }

"""Join strings. The jaclang 0.16 client runtime lacks sep.join(list), so we do it by hand."""
def:pub joined(parts: list[str], sep: str) -> str {
    out = "";
    for (k, p) in enumerate(parts) {
        out = out + (sep if k > 0 else "") + p;
    }
    return out;
}

def:pub NavItem(id: str, label: str, icon: str, active: bool, onPick: Callable[[str], None]) -> JsxElement {
    def pick(e: MouseEvent) -> None {
        onPick(id);
    }
    cls = "nav-item" + (" active" if active else "") + (" chat-tab" if id == "chat" else "");
    return <button className={cls} onClick={pick}>
        <span className="nav-icon">{icon}</span>
        <span>{label}</span>
    </button>;
}

"""Progress bar; value ranges from 0 to 1."""
def:pub Bar(value: float, tone: str = "") -> JsxElement {
    pct = max(0.0, min(1.0, value)) * 100;
    return <div className={"bar " + tone}><span style={{"width": str(pct) + "%"}} /></div>;
}

"""One schedule row: a time block or a deadline. Tap to open the action sheet; tap the circle on the right to check it off."""
def:pub ItemRow(
    item: ItemView,
    onOpen: Callable[[ItemView], None],
    onDone: Callable[[ItemView], None],
    showWhy: bool = False,
    isNow: bool = False
) -> JsxElement {
    def open_it(e: MouseEvent) -> None {
        onOpen(item);
    }

    def tick(e: MouseEvent) -> None {
        e.stopPropagation();
        if not item.done and not item.skipped {
            onDone(item);
        }
    }

    cls = "item";
    if item.done {
        cls = cls + " done";
    }
    if item.skipped {
        cls = cls + " skipped";
    }
    if item.kind == "due" {
        cls = cls + " due";
    }
    if isNow {
        cls = cls + " now";
    }
    parts: list[str] = [];
    if item.kind == "due" {
        parts.append("Due" if "due" in item.title.lower() else "Event");
    } else {
        parts.append(item.time + "–" + item.end + " · " + item.duration);
    }
    if item.interest {
        parts.append(item.interest);
    }
    if item.skipped {
        parts.append("Skipped");
    }
    if item.locked {
        parts.append("🔒");
    }
    mark = "✓" if item.done else ("–" if item.skipped else "");

    return <li className={cls} onClick={open_it}>
        <span className="time">{item.time}</span>
        <span className="icon">{item.icon}</span>
        <div className="body">
            <div className="title">{item.title}</div>
            <div className="meta">{joined(parts, " · ")}</div>
            {showWhy and item.why and <div className="why">↳ {item.why}</div>}
        </div>
        {item.kind == "block" and <button
            className={"check on" if item.done else "check"}
            onClick={tick}
            aria-label="Mark done"
        >
            {mark}
        </button>}
    </li>;
}

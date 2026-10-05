"""Event bus: every change is first written as an Event and processed in batches by the sync walker (prevents update loops)."""

import from user.user { User, Owns, current_user }

node EventQueue {
    has next_seq: int = 1;
}

node Event {
    has seq: int,
        kind: str,          # interest_added / interest_changed / interest_status / task_added /
                            # task_finished / reschedule / ask_importance / derived_suggested / planned
        subject: str,
        data: dict = {},
        created: str = "",
        processed: bool = False,
        origin: str = "user";    # user: caused by a user action; system: produced by the planner itself (never triggers a replan)
}

edge Queued {}

def queue_of(u: User) -> EventQueue | None {
    qs = [u ->:Owns:->][?:EventQueue];
    return qs[0] if qs else None;
}

"""Append an event to the current user's queue."""
def emit_event(kind: str, subject: str, data: dict = {}, origin: str = "user") -> Event | None {
    u = current_user();
    if u is None {
        return None;
    }
    q = queue_of(u);
    if q is None {
        return None;
    }
    e = Event(seq=q.next_seq, kind=kind, subject=subject, data=dict(data), created=u.now_str(), origin=origin);
    q.next_seq += 1;
    q +>:Queued:+> e;
    return e;
}

def pending_events(q: EventQueue) -> list[Event] {
    evs = [e for e in [q ->:Queued:->][?:Event] if not e.processed];
    return sorted(evs, key=lambda e: Event : e.seq);
}

"""Prune old processed events so the graph does not grow forever."""
def prune_events(q: EventQueue, keep: int = 200) -> None {
    done = sorted([e for e in [q ->:Queued:->][?:Event] if e.processed], key=lambda e: Event : e.seq);
    for e in done[:max(0, len(done) - keep)] {
        del e;
    }
}

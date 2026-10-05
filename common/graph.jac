"""Graph helpers: navigate between User / InterestPool / TaskBoard / EventQueue.

    root ─▶ User ─[Owns]─▶ InterestPool ─[Has]─▶ Interest
                 ├[Owns]─▶ TaskBoard    ─[Has]─▶ Task ─[PlannedAs]─▶ StudyBlock
                 │                                   └[RemindAt]──▶ Reminder
                 └[Owns]─▶ EventQueue   ─[Queued]─▶ Event
    Interest ─[Drives]─▶ Task,   Task ─[Feeds]─▶ Interest
"""

import re;
import from datetime { timedelta }
import from user.user { User, Owns, set_current_user }
import from interests.pool { InterestPool, Interest, InterestStatus, Has, Drives, Feeds }
import from tasks.task { TaskBoard, Task, StudyBlock, Reminder, PlannedAs, RemindAt, TaskStatus }
import from sync.events { EventQueue, queue_of }
import from common.timeutil { to_dt }

"""Create a user and its three subgraphs. attach=True hangs it off root (so it is persisted)."""
def bootstrap(name: str = "friend", attach: bool = True, clock: str = "") -> User {
    u = User(name=name, clock=clock);
    if attach {
        root ++> u;
    }
    u +>:Owns:+> InterestPool();
    u +>:Owns:+> TaskBoard();
    u +>:Owns:+> EventQueue();
    set_current_user(u);
    return u;
}

def pool_of(u: User) -> InterestPool {
    return [u ->:Owns:->][?:InterestPool][0];
}

def board_of(u: User) -> TaskBoard {
    return [u ->:Owns:->][?:TaskBoard][0];
}

def interests_of(u: User, include_archived: bool = False) -> list[Interest] {
    items = [pool_of(u) ->:Has:->][?:Interest];
    if include_archived {
        return items;
    }
    return [i for i in items if i.status != InterestStatus.ARCHIVED];
}

def tasks_of(u: User) -> list[Task] {
    return [board_of(u) ->:Has:->][?:Task];
}

def blocks_of(t: Task) -> list[StudyBlock] {
    return sorted([t ->:PlannedAs:->][?:StudyBlock], key=lambda b: StudyBlock : b.start);
}

def reminders_of(t: Task) -> list[Reminder] {
    return [t ->:RemindAt:->][?:Reminder];
}

def interest_of(t: Task) -> Interest | None {
    items = [t ->:Feeds:->][?:Interest];
    return items[0] if items else None;
}

def tasks_of_interest(i: Interest) -> list[Task] {
    return [i ->:Drives:->][?:Task];
}

def task_of_block(b: StudyBlock) -> Task | None {
    ts = [b <-:PlannedAs:<-][?:Task];
    return ts[0] if ts else None;
}

"""All (task, block) pairs."""
def all_blocks(u: User) -> list[tuple] {
    out: list[tuple] = [];
    for t in tasks_of(u) {
        for b in blocks_of(t) {
            out.append((t, b));
        }
    }
    return out;
}

"""Look up an interest by name / alias (exact match first, then "the text mentions it")."""
def find_interest(u: User, text: str, include_archived: bool = False) -> Interest | None {
    if not text {
        return None;
    }
    items = interests_of(u, include_archived);
    key = text.strip().lower();
    for i in items {
        if i.name.lower() == key or key in [a.lower() for a in i.aliases] {
            return i;
        }
    }
    hits = [i for i in items if i.matches(text)];
    if hits {
        return sorted(hits, key=lambda i: Interest : -len(i.name))[0];
    }
    return None;
}

def find_by_id(u: User, ident: str) -> Task | StudyBlock | None {
    ident = ident.strip().lower();
    for t in tasks_of(u) {
        if t.id == ident {
            return t;
        }
        for b in blocks_of(t) {
            if b.id == ident {
                return b;
            }
        }
    }
    return None;
}

"""Attach a task to the board and link it to its interest with Drives / Feeds edges."""
def attach_task(u: User, t: Task, i: Interest | None) -> Task {
    board_of(u) +>:Has:+> t;
    if i is not None {
        i +>:Drives:+> t;
        t +>:Feeds:+> i;
    }
    return t;
}

def add_block(u: User, t: Task, start: str, end: str, focus: str, why: str = "") -> StudyBlock {
    b = StudyBlock(id=board_of(u).new_id("b"), start=start, end=end, focus=focus, why=why);
    t +>:PlannedAs:+> b;
    return b;
}

def add_reminder(t: Task, fire_at: str, message: str) -> Reminder {
    r = Reminder(fire_at=fire_at, message=message);
    t +>:RemindAt:+> r;
    return r;
}

"""Delete a task's future, unfinished blocks and unsent reminders ("only replan the future")."""
def clear_future(t: Task, now_s: str) -> float {
    removed = 0.0;
    for b in blocks_of(t) {
        if not b.done and not b.skipped and b.start > now_s {
            removed += b.hours();
            del b;
        }
    }
    for r in reminders_of(t) {
        if not r.sent and r.fire_at > now_s {
            del r;
        }
    }
    return removed;
}

"""Delete a task completely (including its blocks and reminders)."""
def delete_task(t: Task) -> None {
    for b in blocks_of(t) {
        del b;
    }
    for r in reminders_of(t) {
        del r;
    }
    del t;
}

"""A user utterance -> the open task / block it most likely refers to."""
def resolve_target(u: User, text: str) -> tuple {
    m = re.search(r"\b([tb]\d+)\b", text.lower());
    if m {
        obj_ = find_by_id(u, m.group(1));
        if isinstance(obj_, StudyBlock) {
            return (task_of_block(obj_), obj_);
        }
        if obj_ is not None {
            return (obj_, None);
        }
    }
    now = u.now();
    today = now.date();
    best = None;
    best_block = None;
    best_score = 0.0;
    for t in tasks_of(u) {
        if not t.is_open() {
            continue;
        }
        score = 0.0;
        i = interest_of(t);
        if i is not None and i.matches(text) {
            score += 3;
        }
        title_core = re.split(r"[:(]", t.title)[0];
        if len(title_core) >= 2 and title_core.lower().replace(" ", "") in text.lower().replace(" ", "") {
            score += 3;
        }
        for tp in t.topics {
            if tp and tp.lower() in text.lower() {
                score += 1;
            }
        }
        if score <= 0 {
            continue;
        }
        blocks = [b for b in blocks_of(t) if not b.done and not b.skipped];
        target_day = None;
        low = text.lower();
        if "tonight" in low or "today" in low or "this evening" in low {
            target_day = today;
        } elif "tomorrow" in low {
            target_day = today + timedelta(days=1);
        }
        chosen = None;
        for b in blocks {
            if target_day is not None and to_dt(b.start).date() == target_day {
                chosen = b;
                score += 2;
                break;
            }
        }
        if chosen is None and blocks {
            chosen = blocks[0];
        }
        if chosen is not None {
            # the closer a block is, the more likely it is the one the user means
            gap_h = abs((to_dt(chosen.start) - now).total_seconds()) / 3600.0;
            score += max(0.0, 1.0 - gap_h / 168.0);
        }
        if score > best_score {
            (best, best_block, best_score) = (t, chosen, score);
        }
    }
    return (best, best_block);
}

"""Delete all of a user's data (/reset)."""
def wipe_user(u: User) -> None {
    for t in tasks_of(u) {
        delete_task(t);
    }
    for i in [pool_of(u) ->:Has:->][?:Interest] {
        del i;
    }
    q = queue_of(u);
    if q is not None {
        for e in [q -->] {
            del e;
        }
        del q;
    }
    pl = pool_of(u);
    bd = board_of(u);
    del pl;
    del bd;
    del u;
}

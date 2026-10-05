"""Coordinator: processes events in batches, decides whether to replan, and prevents task <-> interest-pool update loops.

Four rules that prevent loops:
1. event bus + batching: every change is written as an event first, and sync handles a whole batch at once;
2. only replan the future: plan_week only touches tasks that have not started;
3. the user wins: automatic logic may not modify locked tasks / interests;
4. derived interests need confirmation: unconfirmed DERIVED interests are not planned.
Also, events produced by plan_week are marked origin = "system" and never trigger another replan.
"""

import from datetime { datetime, timedelta }
import from user.user { User }
import from interests.pool { InterestStatus }
import from interests.dynamics { decay_heat }
import from interests.discover { discover_interest }
import from tasks.task { TaskStatus, TaskKind }
import from tasks.planner { plan_week }
import from tasks.slots { EVENT_MINUTES }
import from sync.events { queue_of, pending_events, prune_events }
import from sync.feedback { feedback }
import from common.graph { tasks_of, blocks_of, interests_of, interest_of }
import from common.timeutil { to_dt, fmt_dt, week_monday }
import from common.config { cfg }

"""Time passing: heat decays, blocks missed by their time are marked SKIPPED, past exams / meetings are completed automatically."""
def tick(u: User, now: datetime) -> list[str] {
    msgs: list[str] = [];
    today = now.date().isoformat();
    if not u.last_decay_day {
        u.last_decay_day = today;
    } elif u.last_decay_day < today {
        days = (now.date() - datetime.fromisoformat(u.last_decay_day).date()).days;
        for i in interests_of(u) {
            decay_heat(i, days, float(cfg("heat_decay_per_day")), today);
        }
        u.last_decay_day = today;
    }
    # today's blocks wait until the day is over before being reported; only missed blocks from earlier days count as SKIPPED
    grace = fmt_dt(datetime(now.year, now.month, now.day, 0, 0));
    skipped: dict = {};
    now_s = fmt_dt(now);
    for t in tasks_of(u) {
        if not t.is_open() {
            continue;
        }
        if t.kind.name in EVENT_MINUTES and t.due and fmt_dt(to_dt(t.due) + timedelta(minutes=EVENT_MINUTES[t.kind.name])) <= now_s {
            t.status = TaskStatus.DONE;
            for b in blocks_of(t) {
                if not b.done and b.end <= now_s {
                    b.skipped = True;
                }
            }
            ev = "finished" if t.kind == TaskKind.EXAM else "done";
            fb = t spawn feedback(event=ev);
            msgs.append(f"📌 {t.title} is over");
            msgs += fb.out;
            continue;
        }
        missed = [b for b in blocks_of(t) if not b.done and not b.skipped and b.end <= grace];
        for b in missed {
            b.skipped = True;
        }
        if missed {
            if not t.is_rigid() and not [b for b in blocks_of(t) if not b.done and not b.skipped] {
                t.status = TaskStatus.SKIPPED;
            }
            fb = t spawn feedback(event="skip");
            i = interest_of(t);
            key = i.name if i is not None else t.title;
            skipped[key] = skipped.get(key, 0) + len(missed);
        }
    }
    if skipped {
        parts = [f"{k}×{v}" if v > 1 else k for (k, v) in skipped.items()];
        msgs.append(f"⏭️ Missed (marked skipped, related interest heat ↓): {', '.join(parts)}");
    }
    return msgs;
}

walker sync {
    has force: bool = True,
        out: list[str] = [],
        replanned: bool = False,
        processed: int = 0,
        suggested: list[str] = [];      # derived interests found in this batch, awaiting confirmation

    can run with User entry {
        u = here;
        now = u.now();
        now_s = fmt_dt(now);
        if not self.force and u.last_sync and (now - to_dt(u.last_sync)) < timedelta(minutes=int(cfg("batch_interval_min"))) {
            disengage;
        }
        self.out += tick(u, now);

        q = queue_of(u);
        evs = pending_events(q);
        for e in evs {
            e.processed = True;
        }
        self.processed = len(evs);
        user_evs = [e for e in evs if e.origin == "user"];

        need = False;
        asked: list[str] = [];
        added: list[str] = [];
        weight_delta: dict = {};
        discover = False;
        for e in user_evs {
            if e.kind in ["interest_added", "interest_status", "budget_changed"] {
                need = True;
                if e.kind == "interest_added" {
                    added.append(e.subject);
                }
            } elif e.kind == "interest_changed" and e.data.get("field") == "weight" {
                weight_delta[e.subject] = weight_delta.get(e.subject, 0.0) + (e.data["after"] - e.data["before"]);
            } elif e.kind in ["task_added", "task_status"] {
                if e.data.get("rigid") {
                    need = True;
                }
                discover = True;
            } elif e.kind == "ask_importance" and e.subject not in asked {
                asked.append(e.subject);
                self.out.append(f"🤔 You've skipped \"{e.subject}\" {e.data.get('streak', 3)} times in a row. Does it still matter to you? Try /weight {e.subject} 0.3, /short {e.subject} 20 or /pause {e.subject}");
            }
        }
        for (name, d) in weight_delta.items() {
            if abs(d) >= float(cfg("replan_threshold")) - 1e-9 {
                need = True;
            }
        }
        monday = week_monday(now.date()).isoformat();
        if u.last_plan_week != monday {
            need = True;
        }

        if discover {
            dz = u spawn discover_interest();
            self.out += dz.out;
            self.suggested += dz.suggested;
        }
        if need {
            p = u spawn plan_week(focus_names=added);
            self.out += p.out;
            u.last_plan_week = monday;
            self.replanned = True;
            # on weekends, plan next week too
            if now.weekday() >= 5 {
                nxt = (week_monday(now.date()) + timedelta(days=7)).isoformat();
                p2 = u spawn plan_week(week_start=nxt);
            }
        }
        u.last_sync = now_s;
        prune_events(q);
    }
}

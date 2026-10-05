"""REST API entry: `jac start api.jac`; every walker:pub becomes a POST endpoint.

    POST /walker/say          {"text": "I'm learning guitar, want to practice 3 hours a week"}
    POST /walker/cancel_task  {"task_id": "t12", "reason": "too busy this week"}
    POST /walker/brief | week | pool | digest | load_demo
"""

import from user.user { User, current_user, set_current_user }
import from user.chat { chat }
import from user.actions { task_action }
import from sync.sync { sync }
import from notify.reminders { check_reminders }
import from notify.brief { daily_brief, profile_digest, render_pool, render_week }
import from data.seed { seed_demo }
import from common.graph { bootstrap, find_by_id, task_of_block }
import from tasks.task { StudyBlock }

"""The user under the current root; created on the first call."""
def ensure_user() -> User {
    users = [root -->][?:User];
    if users {
        set_current_user(users[0]);
        return users[0];
    }
    return bootstrap("friend");
}

"""Batch step after every action: sync + reminders."""
def settle(u: User) -> dict {
    s = u spawn sync();
    r = u spawn check_reminders();
    return {"updates": s.out, "reminders": r.out, "suggested": s.suggested};
}

walker:pub say {
    has text: str;

    can go with Root entry {
        u = ensure_user();
        c = u spawn chat(text=self.text);
        report {"reply": c.out, "ask": c.ask} | settle(u);
    }
}

walker:pub cancel_task {
    has task_id: str, reason: str = "";

    can go with Root entry {
        u = ensure_user();
        o = find_by_id(u, self.task_id);
        t = task_of_block(o) if isinstance(o, StudyBlock) else o;
        if t is None {
            report {"error": f"{self.task_id} not found"};
            disengage;
        }
        w = t spawn task_action(action="cancel", reason_text=self.reason);
        report {"reply": w.out, "reason": w.result} | settle(u);
    }
}

walker:pub brief {
    can go with Root entry {
        u = ensure_user();
        report {"lines": (u spawn daily_brief()).out};
    }
}

walker:pub week {
    has days: int = 7;

    can go with Root entry {
        report {"lines": render_week(ensure_user(), self.days, True)};
    }
}

walker:pub pool {
    can go with Root entry {
        report {"lines": render_pool(ensure_user())};
    }
}

walker:pub digest {
    can go with Root entry {
        report {"lines": (ensure_user() spawn profile_digest()).out};
    }
}

walker:pub load_demo {
    can go with Root entry {
        u = ensure_user();
        seed_demo(u);
        report {"ok": True};
    }
}

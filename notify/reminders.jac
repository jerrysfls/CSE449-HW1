"""Reminders (task -> user): rule-generated Reminders are pushed when they come due."""

import from datetime { timedelta }
import from user.user { User }
import from common.graph { tasks_of, reminders_of }
import from common.timeutil { fmt_dt, pretty }

walker check_reminders {
    has out: list[str] = [],
        stale: int = 0;

    can run with User entry {
        now = here.now();
        now_s = fmt_dt(now);
        stale_s = fmt_dt(now - timedelta(hours=24));
        due: list = [];
        for t in tasks_of(here) {
            for r in reminders_of(t) {
                if not r.sent and r.fire_at <= now_s {
                    r.sent = True;
                    if not t.is_open() {
                        continue;
                    }
                    if r.fire_at >= stale_s {
                        due.append(r);
                    } else {
                        self.stale += 1;
                    }
                }
            }
        }
        for r in sorted(due, key=lambda r: any : r.fire_at) {
            self.out.append(f"⏰ {r.message}");
        }
        if self.stale {
            self.out.append(f"({self.stale} more expired reminder(s) skipped)");
        }
    }
}

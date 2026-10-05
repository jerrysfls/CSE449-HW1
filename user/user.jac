"""User module: the User node, profile, and personal calibration factors."""

import from datetime { datetime }
import from common.timeutil { resolve_now, fmt_dt }

# ---------- user ----------
node User {
    has name: str = "friend",
        wake_h: int = 8,
        sleep_h: int = 23,
        peak_hours: list[int] = [9, 10, 20, 21],
        max_focus_min: int = 90,
        calib: dict[str, float] = {},     # task kind -> moving average of actual / estimated
        comfort_week_h: float = 30.0,
        clock: str = "",                  # simulated time (demo / tests); empty = system time
        last_decay_day: str = "",
        last_sync: str = "",
        last_plan_week: str = "",
        last_brief_day: str = "",
        pending: dict = {},               # follow-up question awaiting an answer, e.g. {"type": "cancel_reason", "task": "t3"}
        derived: list[str] = [];          # derived interests awaiting confirmation ([yes] [not now])

    def now() -> datetime {
        return resolve_now(self.clock);
    }

    def now_str() -> str {
        return fmt_dt(self.now());
    }

    def calib_of(kind_name: str) -> float {
        return self.calib.get(kind_name, 1.0);
    }
}

edge Owns {}

# current session user (set explicitly by the CLI / tests; otherwise the first User under root)
glob CTX: dict = {"user": None};

def set_current_user(u: User) -> None {
    CTX["user"] = u;
}

def current_user() -> User | None {
    if CTX["user"] is not None {
        return CTX["user"];
    }
    users = [root -->][?:User];
    if users {
        CTX["user"] = users[0];
        return users[0];
    }
    return None;
}

"""Update the personal calibration factor with actual / estimated (exponential moving average); returns the new factor."""
def update_calibration(u: User, kind_name: str, est_h: float, actual_h: float, alpha: float = 0.3) -> float {
    if est_h <= 0 or actual_h <= 0 {
        return u.calib_of(kind_name);
    }
    ratio = max(0.5, min(2.5, actual_h / est_h));
    new_val = round((1 - alpha) * u.calib_of(kind_name) + alpha * ratio, 3);
    u.calib[kind_name] = new_val;
    return new_val;
}

"""Interest pool: InterestPool / Interest nodes, plus the Drives / Feeds edges between interests and tasks."""

enum InterestKind { STUDY, WORK, HOBBY, GOAL, HABIT }

enum InterestStatus { ACTIVE, PAUSED, ARCHIVED }

glob KIND_ICON: dict = {"STUDY": "📘", "WORK": "💼", "HOBBY": "🎨", "GOAL": "🎯", "HABIT": "🔁"},
     KIND_LABEL: dict = {"STUDY": "Study", "WORK": "Work", "HOBBY": "Hobby", "GOAL": "Goal", "HABIT": "Habit"};

node InterestPool {
    has rejected: list[str] = [];      # derived interests the user rejected; never suggested again
}

node Interest {
    has name: str,
        kind: InterestKind,
        weight: float = 0.5,           # how much the user cares (subjective)
        heat: float = 0.0,             # recent engagement
        mastery: float = 0.5,          # proficiency (study interests)
        mastery_prev: float = -1.0,
        weekly_budget_h: float = 0.0,
        budget_weight: float = 0.0,    # weight when the weekly budget was set; later weight changes scale the actual allocation
        session_min: int = 0,          # preferred session length (minutes), 0 = default
        planned: dict = {},            # Monday date -> hours allocated that week (for "adjusted from 3h to 2h")
        status: InterestStatus = InterestStatus.ACTIVE,
        source: str = "USER",          # USER / DERIVED
        confirmed: bool = True,        # DERIVED interests are planned only after the user confirms them
        weak_points: list[str] = [],
        locked: bool = False,          # when locked, automatic logic may not modify it
        preferred_time: str = "",      # morning / afternoon / evening / ""
        skip_streak: int = 0,
        last_active: str = "",
        heat_log: list[list] = [],     # [[date, heat], ...] for profile trends
        aliases: list[str] = [],
        created: str = "";

    def icon() -> str {
        return KIND_ICON[self.kind.name];
    }

    def label() -> str {
        return f"{self.icon()} {self.name}";
    }

    """Whether it takes part in planning: ACTIVE and not an unconfirmed derived interest."""
    def plannable() -> bool {
        return self.status == InterestStatus.ACTIVE and (self.source == "USER" or self.confirmed);
    }

    """Whether the text mentions this interest (ignoring case and spaces)."""
    def matches(text: str) -> bool {
        t = norm(text);
        for n in [self.name] + self.aliases {
            if n and norm(n) in t {
                return True;
            }
        }
        return False;
    }
}

edge Has {}
edge Drives {}      # Interest -> Task: where a task comes from
edge Feeds {}       # Task -> Interest: where completion / cancellation flows back to

def norm(s: str) -> str {
    return s.lower().replace(" ", "").replace("-", "");
}

def clamp01(x: float) -> float {
    return max(0.0, min(1.0, x));
}

"""Heat shown as flames."""
def flames(heat: float) -> str {
    if heat >= 0.66 {
        return "🔥🔥🔥";
    }
    if heat >= 0.33 {
        return "🔥🔥";
    }
    if heat > 0.05 {
        return "🔥";
    }
    return "💤";
}

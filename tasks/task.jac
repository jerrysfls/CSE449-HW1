"""Planned tasks: TaskBoard / Task / StudyBlock / Reminder."""

import from common.timeutil { to_dt, pretty, hm }

enum TaskKind { EXAM, QUIZ, ASSIGNMENT, PROJECT, HOBBY, HABIT, MEETING, PRACTICE }

enum TaskStatus { TODO, SCHEDULED, DOING, DONE, CANCELLED, SKIPPED }

glob TASK_ICON: dict = {
         "EXAM": "📝", "QUIZ": "❓", "ASSIGNMENT": "📚", "PROJECT": "🚀",
         "HOBBY": "🎨", "HABIT": "🔁", "MEETING": "👥", "PRACTICE": "📖"
     },
     TASK_LABEL: dict = {
         "EXAM": "Exam", "QUIZ": "Quiz", "ASSIGNMENT": "Assignment", "PROJECT": "Project",
         "HOBBY": "Hobby", "HABIT": "Habit", "MEETING": "Meeting", "PRACTICE": "Practice"
     },
     RIGID_KINDS: list = ["EXAM", "QUIZ", "ASSIGNMENT", "PROJECT", "MEETING"],
     OPEN_STATUS: list = ["TODO", "SCHEDULED", "DOING"];

node TaskBoard {
    has next_id: int = 1;

    def new_id(prefix: str) -> str {
        i = self.next_id;
        self.next_id += 1;
        return f"{prefix}{i}";
    }
}

node Task {
    has id: str,
        title: str,
        kind: TaskKind,
        due: str = "",
        scope: str = "",
        difficulty: int = 3,           # 1-5
        est_hours: float = 0.0,
        actual_hours: float = 0.0,
        status: TaskStatus = TaskStatus.TODO,
        locked: bool = False,
        origin: str = "USER",          # USER: entered by the user; PLANNER: generated from the interest pool
        created: str = "",
        topics: list[str] = [],
        note: str = "";

    def is_rigid() -> bool {
        return self.kind.name in RIGID_KINDS;
    }

    def is_open() -> bool {
        return self.status.name in OPEN_STATUS;
    }

    def icon() -> str {
        return TASK_ICON[self.kind.name];
    }

    def summary() -> str {
        due_txt = f" · due {pretty(self.due)}" if self.due else "";
        return f"[{self.id}] {self.icon()} {self.title}{due_txt} · {self.status.name}";
    }
}

node StudyBlock {
    has id: str,
        start: str,
        end: str,
        focus: str,
        why: str = "",                 # explainability: why it was scheduled here
        done: bool = False,
        skipped: bool = False;

    def hours() -> float {
        return (to_dt(self.end) - to_dt(self.start)).total_seconds() / 3600.0;
    }

    def summary() -> str {
        mark = " ✅" if self.done else (" ⏭️" if self.skipped else "");
        return f"[{self.id}] {pretty(self.start)}–{self.end[-5:]} {self.focus} ({hm(self.hours())}){mark}";
    }
}

node Reminder {
    has fire_at: str, message: str, sent: bool = False;
}

edge PlannedAs {}
edge RemindAt {}

"""Natural language -> structured intent (interest / task / action).

Uses the LLM first (`llm_route ... by llm()`); falls back to the `rule_route` rules when offline or on failure.
"""

import re;
import from datetime { datetime }
import from ai.llm { llm, ai_enabled, ai_failed, ai_ok }
import from interests.pool { InterestKind }
import from tasks.task { TaskKind }
import from common.timeutil { parse_when, to_dt, fmt_dt, MONTH_RE, WEEKDAY_RE }

enum IntentKind {
    ADD_INTEREST,       # describes what they study / work on, a hobby, goal or habit
    UPDATE_INTEREST,    # adjusts an existing interest: priority, weekly hours, pause, resume, archive
    ADD_TASK,           # a concrete, dated item: exam, quiz, assignment, project, meeting
    COMPLETE_TASK,      # finished something
    CANCEL_TASK,        # cancels something
    POSTPONE_TASK,      # postpones something
    QUIZ_RESULT,        # reports a quiz / self-test score
    SHOW_BRIEF,         # wants today's brief
    SHOW_DIGEST,        # wants the profile digest and advice
    SHOW_POOL,          # wants the interest pool
    SHOW_WEEK,          # wants this week's schedule
    CHAT                # small talk or unclassifiable
}

enum InterestOp { WEIGHT_UP, WEIGHT_DOWN, SET_WEIGHT, SET_BUDGET, PAUSE, RESUME, ARCHIVE, SET_TIME }

obj InterestDraft {
    has name: str,
        kind: InterestKind,
        weekly_budget_h: float = 0.0,
        weight: float = 0.6,
        preferred_time: str = "";      # morning / afternoon / evening / ""
}

obj InterestUpdate {
    has name: str,
        op: InterestOp,
        value: float = 0.0,            # SET_WEIGHT: 0-1; SET_BUDGET: hours / week
        text: str = "";                # SET_TIME: morning / afternoon / evening
}

obj TaskDraft {
    has title: str,
        kind: TaskKind,
        due: str = "",                 # "YYYY-MM-DD HH:MM"
        scope: str = "",
        difficulty: int = 3,           # 1-5
        interest_name: str = "",       # related interest (course or project name)
        est_hours: float = 0.0,        # base estimate from the user or AI; 0 = use the default
        topics: list[str] = [];
}

obj Intent {
    has kind: IntentKind,
        interest: InterestDraft | None = None,
        update: InterestUpdate | None = None,
        task: TaskDraft | None = None,
        target: str = "",              # the task the user refers to, in their own words
        score: float = -1.0,           # QUIZ_RESULT: score ratio 0-1
        wrong_topics: list[str] = [],  # QUIZ_RESULT: topics of the missed questions
        reason: str = "",              # CANCEL_TASK: reason given by the user
        actual_hours: float = 0.0,     # COMPLETE_TASK: actual time spent
        days: int = 0,                 # POSTPONE_TASK: days to postpone
        reply: str = "";               # CHAT: direct reply
}

"""You are the intent parser of a personal assistant. Decide which IntentKind the user's message is and fill in the matching fields:
- Describes what they are studying / doing / enjoy / a habit they want / a goal -> ADD_INTEREST, fill interest
  (kind: course or exam prep = STUDY, paper / internship / job = WORK, hobby = HOBBY, long-term goal = GOAL,
   something done every day / week = HABIT; weekly_budget_h is hours per week, "15 minutes a day" = 1.75)
- Adjusts an existing interest (priority, weekly hours, pause, resume, delete) -> UPDATE_INTEREST, name = the name in the interest pool
- An exam / quiz / assignment / project / meeting with a definite time -> ADD_TASK, due as "YYYY-MM-DD HH:MM" (infer year and weekday from now),
  title like "STATS 413 Midterm", interest_name = the course or project name
- Finished / cancels / postpones something -> the matching kind, target = the user's words for which item
- Reports a quiz score -> QUIZ_RESULT, score in 0-1, wrong_topics = normalized topic names
- Wants the brief / profile / interest pool / this week's schedule -> SHOW_*
- Anything else -> CHAT, with a short reply in English."""
def llm_route(text: str, now: str, interests: list[str], open_tasks: list[str]) -> Intent by llm();

"""Parse user input: the LLM when AI is available, otherwise (or on failure) the rules."""
def route(text: str, now: datetime, interests: list[str], open_tasks: list[str]) -> Intent {
    if ai_enabled() {
        try {
            it = llm_route(text, fmt_dt(now), interests, open_tasks);
            it = normalize_intent(it, text, now);
            if it is not None {
                ai_ok();
                return it;
            }
        } except Exception as e {
            ai_failed(e);
        }
    }
    return rule_route(text, now, interests);
}

"""Validate an LLM result; returns None when fields are missing so the rules take over."""
def normalize_intent(it: Intent, text: str, now: datetime) -> Intent | None {
    if it is None or not isinstance(it, Intent) {
        return None;
    }
    if it.kind == IntentKind.ADD_TASK {
        if it.task is None {
            return None;
        }
        try {
            to_dt(it.task.due);
        } except Exception {
            it.task.due = parse_when(text, now);
        }
        if not it.task.due {
            return None;
        }
    }
    if it.kind == IntentKind.ADD_INTEREST and it.interest is None {
        return None;
    }
    if it.kind == IntentKind.UPDATE_INTEREST and it.update is None {
        return None;
    }
    if it.kind in [IntentKind.COMPLETE_TASK, IntentKind.CANCEL_TASK, IntentKind.POSTPONE_TASK] and not it.target {
        it.target = text;
    }
    if it.kind == IntentKind.QUIZ_RESULT and it.score > 1.0 {
        it.score = it.score / 100.0 if it.score > 10 else it.score / 10.0;
    }
    return it;
}

# ======================= rule parser (offline fallback) =======================

glob HOBBY_WORDS: list = [
         "guitar", "piano", "ukulele", "drums", "violin", "singing", "running", "gym", "basketball", "soccer",
         "swimming", "badminton", "tennis", "yoga", "cycling", "hiking", "climbing", "cooking", "baking", "anime",
         "drawing", "painting", "photography", "gaming", "music", "chess", "calligraphy", "skateboarding",
         "skiing", "dancing", "knitting", "novels"
     ],
     EXAM_PREP_WORDS: list = ["TOEFL", "IELTS", "GRE", "GMAT", "MCAT", "LSAT", "LeetCode"],
     STUDY_WORDS: list = [
         "toefl", "ielts", "gre", "gmat", "leetcode", "class", "course", "review", "math", "programming",
         "algorithm", "machine learning", "deep learning", "statistics", "physics", "english", "spanish",
         "japanese", "french", "chinese", "korean", "german", "study", "learning", "learn"
     ],
     WORK_WORDS: list = ["paper", "thesis", "internship", "intern", "research", "job", "work", "lab", "submission", "manuscript", "startup"],
     GOAL_WORDS: list = ["goal", "apply", "applying", "application", "lose weight", "get into", "offer", "admission", "phd", "marathon"],
     HABIT_RE = r"every ?day|daily|each day|every (morning|night|evening)|a day\b|per day|habit|streak",
     COURSE_RE = r"\b([A-Za-z]{2,6})\s?-?(\d{3}[A-Za-z]?)\b",
     COURSE_STOP: list = [
         "at", "by", "in", "on", "for", "about", "around", "took", "spent", "over", "under", "than", "only",
         "just", "to", "of", "and", "or", "with", "the", "room", "page", "pages", "every", "score", "got", "is", "was"
     ];

"""Course code in the text, e.g. "eecs442" -> "EECS 442"; "" when there is none."""
def find_course(t: str) -> str {
    for m in re.finditer(COURSE_RE, t) {
        if m.group(1).lower() in COURSE_STOP {
            continue;
        }
        if re.match(r"\s*(min|minutes|hours?|hrs?|pages|%|points)", t[m.end():], re.I) {
            continue;
        }
        return f"{m.group(1).upper()} {m.group(2).upper()}";
    }
    return "";
}

def rule_route(text: str, now: datetime, interests: list[str]) -> Intent {
    t = text.strip();
    low = t.lower();
    if not t {
        return Intent(kind=IntentKind.CHAT, reply="");
    }
    mentioned = [n for n in interests if n.lower().replace(" ", "") in low.replace(" ", "")];
    due = parse_when(t, now);

    # 1. quiz score
    score = parse_score(low);
    if score >= 0 and re.search(r"quiz|test|self-test|practice|mock|missed|wrong|mistake", low)
       and (not due or re.search(r"got|scored?|done|finished|took|missed|wrong|mistake|result|graded|back", low)) {
        return Intent(kind=IntentKind.QUIZ_RESULT, score=score, wrong_topics=parse_wrong_topics(t), target=t);
    }
    # 2. cancel
    if re.search(r"\bcancel|\bskip(ping)?\b|call(ing)? off|not going to (do|go|make)|won't (go|do|make it)|can't make it", low) {
        (target, reason) = split_reason(t);
        return Intent(kind=IntentKind.CANCEL_TASK, target=target, reason=reason);
    }
    # 3. postpone
    if re.search(r"postpone|delay|push(ed)? (it |this |that )?back|reschedule|put off|move .{1,30} to\b", low) {
        m = re.search(r"(\d+)\s*days?", low);
        return Intent(kind=IntentKind.POSTPONE_TASK, target=t, days=int(m.group(1)) if m else 0);
    }
    # 4. complete
    if re.search(r"\bdone\b|finished|\bfinish\b|completed?|submitted|turned in|handed in|wrapped up|took the (exam|midterm|final|test)|\bdid (it|the|my)\b", low) {
        return Intent(kind=IntentKind.COMPLETE_TASK, target=t, actual_hours=parse_actual_hours(low));
    }
    # 5. adjust an existing interest
    upd = parse_interest_update(t, mentioned);
    if upd is not None {
        return Intent(kind=IntentKind.UPDATE_INTEREST, update=upd);
    }
    # 6. concrete task
    kind = task_kind_of(low);
    if kind is not None and due {
        return Intent(kind=IntentKind.ADD_TASK, task=parse_task(t, kind, due, mentioned));
    }
    # 7. views
    if re.search(r"\bbrief|what'?s (on|up|planned) (for )?today|today'?s (plan|schedule|agenda)|what do i have today|plan for today|morning report", low) {
        return Intent(kind=IntentKind.SHOW_BRIEF);
    }
    if re.search(r"digest|profile|advice|suggestion|how am i doing|analy[sz]e me|summary|summari[sz]e|recommend", low) {
        return Intent(kind=IntentKind.SHOW_DIGEST);
    }
    if re.search(r"interest pool|my interests|\bpool\b", low) {
        return Intent(kind=IntentKind.SHOW_POOL);
    }
    if parse_budget(low) == 0 and re.search(r"this week|next 7 days|^\s*(the )?week\s*\??$|(my|the|weekly) (week|schedule|agenda|calendar|plan)|show .{0,20}(week|schedule)|what'?s (on|planned) .{0,10}week", low) {
        return Intent(kind=IntentKind.SHOW_WEEK);
    }
    # 8. new interest
    if re.search(r"learn|study|studying|practic|playing|\bplay\b|\binto\b|\blove\b|\blike\b|enjoy|hobby|prepar|\bprep\b|every|daily|weekly|a week|habit|goal|plan to|want to|trying to|working on|writing|reading|training|picked up|started", low) {
        d = parse_interest(t);
        if d is not None {
            return Intent(kind=IntentKind.ADD_INTEREST, interest=d);
        }
    }
    # 9. has a date but no recognizable task type: treat it as an assignment / to-do
    if due and re.search(r"\bdue\b|deadline|\bby\b|before|have to|need to|submit", low) {
        return Intent(kind=IntentKind.ADD_TASK, task=parse_task(t, TaskKind.ASSIGNMENT, due, mentioned));
    }
    return Intent(kind=IntentKind.CHAT, reply="");
}

"""8/10, 8 out of 10, 80%, 80 points -> 0-1 score ratio; -1 when there is none."""
def parse_score(low: str) -> float {
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:/|out of)\s*(\d+(?:\.\d+)?)", low);
    if m and float(m.group(2)) > 0 {
        return min(1.0, float(m.group(1)) / float(m.group(2)));
    }
    m = re.search(r"(\d+(?:\.\d+)?)\s*%", low);
    if m {
        return min(1.0, float(m.group(1)) / 100.0);
    }
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:points?|pts)\b", low);
    if m {
        v = float(m.group(1));
        return min(1.0, v / 100.0 if v > 10 else v / 10.0);
    }
    return -1.0;
}

def parse_wrong_topics(t: str) -> list[str] {
    m = re.search(r"(?:missed|wrong on|got .{0,20}? wrong|mistakes? (?:on|in|with)|weak (?:on|at|in)|struggled (?:with|on)|messed up)\s*:?\s*(.+)$", t, re.I);
    if not m {
        return [];
    }
    body = re.split(r"[.!?](?:\s|$)", m.group(1))[0];
    parts = re.split(r"[,/;&]|\band\b|\bplus\b", body);
    out: list[str] = [];
    for p in parts {
        p = re.sub(r"^(also|the|on|in|some|a few|a|an)\s+", "", p.strip(), flags=re.I);
        p = re.sub(r"\s+(questions?|problems?|parts?|ones?|stuff|section)$", "", p, flags=re.I).strip();
        if p and len(p) <= 30 and p not in out {
            out.append(p);
        }
    }
    return out;
}

def split_reason(t: str) -> tuple {
    m = re.search(r"(?:\bbecause\b|\bsince\b|\bdue to\b|\bcause\b|\breason\s*:?)\s*(.+)$", t, re.I);
    if m {
        return (t[:m.start()].strip(" ,.;-"), m.group(1).strip(" ."));
    }
    parts = re.split(r"[,;.]|\s-\s", t, maxsplit=1);
    if len(parts) == 2 and parts[1].strip(" .") {
        return (parts[0].strip(), parts[1].strip(" ."));
    }
    return (t, "");
}

def parse_actual_hours(low: str) -> float {
    m = re.search(r"(?:took|spent|in|practiced|ran|worked|studied)\s*(?:me\s*)?(?:about\s*)?(\d+(?:\.\d+)?)\s*(?:h|hrs?|hours?)\b", low);
    if m {
        return float(m.group(1));
    }
    m = re.search(r"(?:took|spent|in|practiced|ran|worked|studied)\s*(?:me\s*)?(?:about\s*)?(\d+)\s*(?:m|mins?|minutes?)\b", low);
    if m {
        return int(m.group(1)) / 60.0;
    }
    return 0.0;
}

def task_kind_of(low: str) -> TaskKind | None {
    if re.search(r"\bquiz", low) {
        return TaskKind.QUIZ;
    }
    if re.search(r"midterm|\bfinals?\b|\bexam|\btest\b", low) {
        return TaskKind.EXAM;
    }
    if re.search(r"\bhw\s*\d*|homework|assignment|problem set|pset|lab report|\blab\s*\d+|essay", low) {
        return TaskKind.ASSIGNMENT;
    }
    if re.search(r"meeting|interview|office hours?|appointment|one-on-one|1:1|seminar|call with", low) {
        return TaskKind.MEETING;
    }
    if re.search(r"project|milestone|submission|deadline|\bpaper\b|proposal|presentation|\bdemo\b", low) {
        return TaskKind.PROJECT;
    }
    return None;
}

"""Strip date / time words so the rest of the sentence can serve as a title."""
def strip_when(t: str) -> str {
    pats = [
        r"\b\d{4}-\d{1,2}-\d{1,2}\b",
        r"(?<![\d.])\d{1,2}\s*/\s*\d{1,2}(?![\d.])",
        r"\b" + MONTH_RE + r"\s*\d{1,2}(?:st|nd|rd|th)?\b",
        r"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?" + MONTH_RE + r"\b",
        r"\b(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)\b",
        r"\b(?:at\s+)?\d{1,2}:\d{2}\b",
        r"\(?\b(?:next\s+)?" + WEEKDAY_RE[2:] + r"\)?",
        r"\b(?:day after tomorrow|tomorrow|today|tonight|this (?:morning|afternoon|evening)|in \d+ days?|at noon|noon)\b",
        r"\b(?:due|by|before|on|at)\s*$",
        r"^\s*(?:i\s+(?:have|got)|there'?s|i'?ve got|got)\s+(?:an?\s+)?",
        r"\b(?:is\s+)?due\b"
    ];
    s = t;
    for p in pats {
        s = re.sub(p, " ", s, flags=re.I);
    }
    s = re.sub(r"\b(?:on|at|by)\s*(?=[,;.]|$)", " ", s, flags=re.I);
    return re.sub(r"\s+", " ", s).strip(" ,.;:-");
}

def parse_task(t: str, kind: TaskKind, due: str, mentioned: list[str]) -> TaskDraft {
    low = t.lower();
    course = sorted(mentioned, key=lambda n: str : -len(n))[0] if mentioned else find_course(t);
    label = {"EXAM": "Exam", "QUIZ": "Quiz", "ASSIGNMENT": "Assignment", "PROJECT": "Project", "MEETING": "Meeting"}.get(kind.name, "");
    if kind == TaskKind.EXAM {
        if re.search(r"midterm", low) {
            label = "Midterm";
        } elif re.search(r"\bfinals?\b", low) {
            label = "Final";
        }
    }
    if kind == TaskKind.ASSIGNMENT {
        m = re.search(r"(?:hw|homework)\s*#?\s*(\d+)", low);
        if m {
            label = f"HW{m.group(1)}";
        }
    }
    if kind in [TaskKind.PROJECT, TaskKind.MEETING] or not course {
        # no course name: use the sentence minus the time words as the title
        core = re.split(r"[,;.]\s|[,;]", strip_when(t))[0].strip();
        if core and (not course or course.lower() not in core.lower()) {
            title = cap(core) if len(core) <= 48 else cap(core[:48].rsplit(" ", 1)[0]);
        } else {
            title = f"{course} {label}".strip();
        }
    } else {
        title = f"{course} {label}".strip();
    }
    scope = "";
    m = re.search(r"(?:covers?|covering|scope\s*:?|includes?|including)\s*:?\s*([^,.;]+)", t, re.I);
    if m and kind in [TaskKind.EXAM, TaskKind.QUIZ] {
        scope = m.group(1).strip();
    }
    diff = 3;
    if re.search(r"hard|difficult|tough|brutal", low) {
        diff = 4;
    } elif re.search(r"easy|simple|light", low) {
        diff = 2;
    }
    est = 0.0;
    m = re.search(r"(?:about|around|roughly|probably|need|needs|takes?|estimated?|maybe)\s*(\d+(?:\.\d+)?)\s*(?:h|hrs?|hours?)\b", low);
    if m {
        est = float(m.group(1));
    }
    return TaskDraft(title=title, kind=kind, due=due, scope=scope, difficulty=diff, interest_name=course, est_hours=est);
}

def parse_interest_update(t: str, mentioned: list[str]) -> InterestUpdate | None {
    low = t.lower();
    name = sorted(mentioned, key=lambda n: str : -len(n))[0] if mentioned else "";
    if not name {
        m = re.search(r"\b(?:remove|delete|archive)\s+(?:the\s+|my\s+)?([a-z][\w+#-]*(?:\s+[a-z0-9][\w+#-]*){0,2})", t, re.I);
        if m {
            return InterestUpdate(name=m.group(1).strip(), op=InterestOp.ARCHIVE);
        }
        return None;
    }
    if re.search(r"\bpause|take a break from|on hold|hold off|stop .{0,30} for (a while|now|this|the)|not .{0,20} for (a while|now|this month|this week)", low) {
        return InterestUpdate(name=name, op=InterestOp.PAUSE);
    }
    if re.search(r"resume|\bback to\b|restart|start .{0,20} again|pick .{0,20} back up|unpause", low) {
        return InterestUpdate(name=name, op=InterestOp.RESUME);
    }
    if re.search(r"archive|remove|delete|\bdrop\b|\bquit\b|give up|no longer|don't want .{0,20} anymore|course (is )?over", low) {
        return InterestUpdate(name=name, op=InterestOp.ARCHIVE);
    }
    m = re.search(r"weight\s*(?:to|=|of|at)?\s*(0?\.\d+|1(?:\.0)?)\b", low);
    if m {
        return InterestUpdate(name=name, op=InterestOp.SET_WEIGHT, value=float(m.group(1)));
    }
    if re.search(r"(raise|increase|higher|bump( up)?|boost)( the)? priority|priority (up|higher)|prioriti[sz]e|more important|focus (more )?on|top priority", low) {
        return InterestUpdate(name=name, op=InterestOp.WEIGHT_UP);
    }
    if re.search(r"(lower|decrease|reduce|drop)( the)? priority|priority (down|lower)|less important|deprioriti[sz]e|less time|spend less", low) {
        return InterestUpdate(name=name, op=InterestOp.WEIGHT_DOWN);
    }
    b = parse_budget(low);
    if b > 0 {
        return InterestUpdate(name=name, op=InterestOp.SET_BUDGET, value=b);
    }
    pt = parse_pref_time(low);
    if pt and re.search(r"\bmove|switch|\bput\b|better|prefer|instead|change", low) {
        return InterestUpdate(name=name, op=InterestOp.SET_TIME, text=pt);
    }
    return None;
}

"""Hours per week."""
def parse_budget(low: str) -> float {
    per_day = r"(?:a|per|each|every)\s*(?:day|night|morning|evening)|daily";
    per_week = r"(?:a|per|each|every)\s*week|/\s*(?:wk|week)|weekly";
    hours = r"(?:h|hrs?|hours?)\b";
    mins = r"(?:m|mins?|minutes?)\b";
    num = r"(\d+(?:\.\d+)?)\s*";
    m = re.search(num + mins + r"\s*(?:of\s+\w+\s*)?(?:" + per_day + ")", low) or re.search(r"(?:" + per_day + r")\D{0,20}?" + num + mins, low);
    if m {
        return round(float(m.group(1)) * 7 / 60.0, 2);
    }
    m = re.search(num + hours + r"\s*(?:of\s+\w+\s*)?(?:" + per_day + ")", low) or re.search(r"(?:" + per_day + r")\D{0,20}?" + num + hours, low);
    if m {
        return float(m.group(1)) * 7;
    }
    m = re.search(num + hours + r"\s*(?:of\s+\w+\s*)?(?:" + per_week + ")", low) or re.search(r"(?:" + per_week + r")\D{0,20}?" + num + hours, low);
    if m {
        return float(m.group(1));
    }
    m = re.search(r"(\d+)\s*times?\s*(?:a|per|each|every)\s*week", low);
    if m {
        return float(m.group(1));
    }
    if re.search(r"twice (a|per|each|every) week", low) {
        return 2.0;
    }
    if re.search(r"once (a|per|each|every) week", low) {
        return 1.0;
    }
    return 0.0;
}

def parse_pref_time(low: str) -> str {
    if re.search(r"evening|night|before bed|after dinner", low) {
        return "evening";
    }
    if re.search(r"morning|after (i )?wak|before class|early", low) {
        return "morning";
    }
    if re.search(r"afternoon|after lunch", low) {
        return "afternoon";
    }
    return "";
}

def has_word(low: str, words: list) -> bool {
    return any([re.search(r"\b" + re.escape(w.lower()) + r"\b", low) is not None for w in words]);
}

def guess_interest_kind(low: str) -> InterestKind {
    if find_course(low) {
        return InterestKind.STUDY;
    }
    if re.search(HABIT_RE, low) and not re.search(r"week", low) {
        return InterestKind.HABIT;
    }
    if has_word(low, GOAL_WORDS) {
        return InterestKind.GOAL;
    }
    if has_word(low, HOBBY_WORDS) {
        return InterestKind.HOBBY;
    }
    if has_word(low, WORK_WORDS) {
        return InterestKind.WORK;
    }
    if has_word(low, STUDY_WORDS) {
        return InterestKind.STUDY;
    }
    return InterestKind.HOBBY;
}

def cap(s: str) -> str {
    return s[0].upper() + s[1:] if s else s;
}

def extract_interest_name(t: str, kind: InterestKind) -> str {
    course = find_course(t);
    if course {
        return course;
    }
    low = t.lower();
    if kind != InterestKind.HABIT and kind != InterestKind.GOAL {
        for w in EXAM_PREP_WORDS {
            if re.search(r"\b" + w.lower() + r"\b", low) {
                return f"{w} prep" if re.search(r"prep", low) else w;
            }
        }
        for w in HOBBY_WORDS {
            if re.search(r"\b" + w + r"\b", low) {
                return cap(w);
            }
        }
    }
    stop = r"(?=\s*(?:[,.;!?]|$|\bevery\b|\beach\b|\bfor\b|\bat\b|\bin the\b|\bon\b|\bdaily\b|\bweekly\b|\brecently\b|\blately\b|\bthese days\b|\bnow\b|\babout\b|\baround\b|\d|\btwice\b|\bonce\b|\ba (?:day|week)\b|\bper\b|\bbefore\b|\bafter\b|\bso\b|\bbecause\b))";
    pats = [
        r"goal is (?:to\s+)?([a-z][\w'+#-]*(?:\s+[a-z0-9][\w'+#-]*){0,4}?)" + stop,
        r"(?:want to|trying to|plan to|going to|start(?:ed|ing)? to|need to|try to)\s+(?:get better at\s+|learn\s+|practice\s+|study\s+)?([a-z][\w'+#-]*(?:\s+[a-z0-9][\w'+#-]*){0,4}?)" + stop,
        r"(?:learning|learn|studying|study|practicing|practice|playing|into|love|enjoy|like|working on|writing|reading|training for|preparing for|prepping for|picked up|started)\s+(?:the\s+|some\s+|a\s+|my\s+)?([a-z][\w'+#-]*(?:\s+[a-z0-9][\w'+#-]*){0,3}?)" + stop
    ];
    for p in pats {
        m = re.search(p, t, re.I);
        if m {
            name = m.group(1).strip();
            name = re.sub(r"^(the|a|an|some|my|to)\s+", "", name, flags=re.I);
            name = re.sub(r"\s+(more|again|regularly|consistently|too|as well)$", "", name, flags=re.I).strip();
            if name and name.lower() not in ["it", "this", "that", "them", "something", "stuff"] {
                return cap(name);
            }
        }
    }
    return "";
}

def parse_interest(t: str) -> InterestDraft | None {
    low = t.lower();
    kind = guess_interest_kind(low);
    name = extract_interest_name(t, kind);
    if not name {
        return None;
    }
    budget = parse_budget(low);
    weight = 0.6;
    if re.search(r"very important|most important|top priority|\bpriority\b|really (want|need)|focus", low) {
        weight = 0.8;
    }
    return InterestDraft(name=name, kind=kind, weekly_budget_h=budget, weight=weight, preferred_time=parse_pref_time(low));
}

"""Aliases derived from an interest name: "TOEFL prep" -> "TOEFL"; "Learn guitar" -> "guitar"; "Running" -> "run"."""
def derive_aliases(name: str) -> list[str] {
    out: list[str] = [];
    core = re.sub(r"^(prep(are)? for|preparing for|learn(ing)?|practi[cs]e|study(ing)?|daily|every ?day)\s+", "", name, flags=re.I);
    core = re.sub(r"\s+(prep|practice|study|training)$", "", core, flags=re.I).strip();
    if core and core.lower() != name.lower() and len(core) >= 2 {
        out.append(core);
    }
    w = core.lower();
    if " " not in w and w.endswith("ing") and len(w) >= 6 {
        stem = w[:-3];
        if len(stem) >= 3 and stem[-1] == stem[-2] {
            stem = stem[:-1];
        }
        if len(stem) >= 3 and stem not in out {
            out.append(stem);
        }
    }
    return out;
}

"""Discovering new interests (task -> interest pool): find topics that keep showing up in tasks but are not in the pool yet.

Derived interests are added with source = DERIVED, confirmed = False. They are only "suggestions" and take no part in planning until the user confirms.
"""

import re;
import from datetime { timedelta }
import from ai.llm { llm, ai_enabled, ai_failed, ai_ok }
import from ai.parse { guess_interest_kind }
import from user.user { User }
import from interests.pool { Interest, InterestKind, InterestStatus, KIND_LABEL, KIND_ICON, Has }
import from tasks.task { Task, TaskStatus }
import from sync.events { emit_event }
import from common.graph { pool_of, tasks_of, interests_of }
import from common.timeutil { to_dt, fmt_dt }

"""From recent task titles, find topics that recur in at least 3 tasks but are not in the interest pool (pool) yet.
Return only concrete topic nouns (e.g. "diffusion models"), never course names or generic words like "homework" or "review". Return an empty list when there are none."""
def find_new_topics(recent_tasks: list[str], pool: list[str]) -> list[str] by llm();

glob STOP_EN: list = [
         "homework", "project", "lecture", "lectures", "exam", "quiz", "final", "midterm", "review", "paper", "meeting",
         "the", "and", "with", "for", "from", "into", "about", "report", "draft", "week", "chapter", "part",
         "reading", "read", "notes", "problem", "set", "lab", "assignment", "presentation", "slides", "code",
         "a", "an", "of", "on", "in", "to", "at", "by", "my", "our", "your", "is", "are", "be", "or", "vs",
         "group", "present", "progress", "prepare", "prep", "finish", "submit", "write", "survey", "milestone",
         "work", "study", "practice", "session", "next", "new", "first", "second", "update", "updates", "due"
     ];

def find_new_topics_fallback(texts: list[str], pool_names: list[str], min_count: int = 3) -> list[str] {
    counts: dict = {};
    shown: dict = {};
    for txt in texts {
        seen: set = set();
        words = re.findall(r"[A-Za-z][A-Za-z\-']*|\d+", txt);
        for n in range(1, 4) {
            for k in range(len(words) - n + 1) {
                gram = words[k:k + n];
                low = [w.lower() for w in gram];
                if low[0] in STOP_EN or low[-1] in STOP_EN or low[0].isdigit() or low[-1].isdigit() {
                    continue;
                }
                if n == 1 and len(low[0]) < 4 {
                    continue;
                }
                key = " ".join(low);
                seen.add(key);
                if key not in shown {
                    shown[key] = " ".join(gram);
                }
            }
        }
        for g in seen {
            counts[g] = counts.get(g, 0) + 1;
        }
    }
    pool_low = [p.lower().replace(" ", "") for p in pool_names];
    cands = [g for (g, c) in counts.items() if c >= min_count and not any([(g.replace(" ", "") in p or p in g.replace(" ", "")) for p in pool_low if p])];
    # at equal frequency prefer the longest phrase, and drop phrases contained in it
    cands = sorted(cands, key=lambda g: str : (-counts[g], -len(g)));
    out: list[str] = [];
    for g in cands {
        if not any([(g in o.lower()) for o in out]) {
            s = shown[g];
            out.append(s[0].upper() + s[1:]);
        }
    }
    return out;
}

walker discover_interest {
    has out: list[str] = [],
        suggested: list[str] = [];

    can run with User entry {
        u = here;
        now = u.now();
        lo = fmt_dt(now - timedelta(days=21));
        hi = fmt_dt(now + timedelta(days=30));
        recent = [t for t in tasks_of(u) if t.origin == "USER" and t.status != TaskStatus.CANCELLED and ((t.created and t.created >= lo) or (t.due and lo <= t.due <= hi))];
        if len(recent) < 3 {
            disengage;
        }
        texts = [" ".join([t.title, t.scope] + t.topics) for t in recent];
        pool = pool_of(u);
        names: list[str] = list(pool.rejected);
        for i in interests_of(u, True) {
            names += [i.name] + i.aliases;
        }
        topics: list[str] = [];
        if ai_enabled() {
            try {
                topics = [str(x) for x in find_new_topics(texts, names)];
                ai_ok();
            } except Exception as e {
                ai_failed(e);
                topics = find_new_topics_fallback(texts, names);
            }
        } else {
            topics = find_new_topics_fallback(texts, names);
        }
        for tp in topics[:1] {
            if not tp or any([tp.lower() == n.lower() for n in names]) {
                continue;
            }
            related = [x for x in texts if tp.lower() in x.lower()];
            kind = guess_interest_kind((tp + " " + " ".join(related)).lower());
            i = Interest(name=tp, kind=kind, weight=0.5, source="DERIVED", confirmed=False, created=u.now_str());
            pool +>:Has:+> i;
            self.suggested.append(tp);
            emit_event("derived_suggested", tp, {"count": len(related)});
            n_txt = f"{len(related)} of your recent tasks" if len(related) > 0 else "Several of your recent tasks";
            self.out.append(f"{n_txt[0].upper() + n_txt[1:]} involve \"{tp}\". Add it to your interest pool as {KIND_ICON[kind.name]} {KIND_LABEL[kind.name]}? [yes] [not now]");
        }
    }
}

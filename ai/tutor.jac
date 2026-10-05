"""Review outlines and quiz generation."""

import from ai.llm { llm, ai_enabled, ai_failed, ai_ok }

obj QuizQuestion {
    has question: str,
        answer: str,
        topic: str;          # the topic it covers; missed questions are written back to weak_points
}

"""Write n English self-test questions for this course's exam scope, covering weak_points first; keep answers short."""
def llm_make_quiz(course: str, scope: str, weak_points: list[str], n: int) -> list[QuizQuestion] by llm();

"""Write a short English review outline (5-8 items) for this course's exam scope, weak points first."""
def llm_review_outline(course: str, scope: str, weak_points: list[str]) -> list[str] by llm();

def make_quiz(course: str, scope: str, weak_points: list[str], n: int = 5) -> list[QuizQuestion] {
    if ai_enabled() {
        try {
            qs = llm_make_quiz(course, scope, weak_points, n);
            if qs {
                ai_ok();
                return qs[:n];
            }
        } except Exception as e {
            ai_failed(e);
        }
    }
    topics = weak_points + [scope or course, "core definitions", "typical problems", "common pitfalls"];
    templates = [
        "Explain \"{t}\" in your own words and give an example.",
        "How is \"{t}\" most often tested? Write out the solution steps.",
        "Which concepts are easy to confuse with \"{t}\"?",
        "Without notes, write down the key formulas / results for \"{t}\".",
        "If an exam had a multi-part problem on \"{t}\", how would you start?"
    ];
    out: list[QuizQuestion] = [];
    for k in range(n) {
        tp = topics[k % len(topics)];
        out.append(QuizQuestion(question=templates[k % len(templates)].format(t=tp), answer="(offline mode: check against your notes)", topic=tp));
    }
    return out;
}

def review_outline(course: str, scope: str, weak_points: list[str]) -> list[str] {
    if ai_enabled() {
        try {
            out = llm_review_outline(course, scope, weak_points);
            if out {
                ai_ok();
                return out;
            }
        } except Exception as e {
            ai_failed(e);
        }
    }
    items = [f"Go over the weak point: {w}" for w in weak_points];
    items += [f"List the key concepts of {scope or course}", "Pair each concept with one worked example", "Do a timed past exam", "Put together a cheat sheet"];
    return items;
}

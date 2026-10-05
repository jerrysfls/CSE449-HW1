"""Cancel-reason classification: different reasons affect the interest pool very differently."""

import re;
import from ai.llm { llm, ai_enabled, ai_failed, ai_ok }

enum CancelReason {
    BUSY,            # too busy / conflict -> pool unchanged, only reschedule
    LOST_INTEREST,   # don't want to / lost interest -> lower the weight
    NOT_NEEDED,      # no longer needed -> archive the interest
    BAD_ESTIMATE,    # bad estimate -> update the personal calibration factor
    OTHER
}

glob REASON_LABEL: dict = {
    "BUSY": "too busy / conflict",
    "LOST_INTEREST": "lost interest",
    "NOT_NEEDED": "no longer needed",
    "BAD_ESTIMATE": "bad time estimate",
    "OTHER": "other"
};

"""Classify the reason a user gave for cancelling a task.
BUSY: too busy, schedule conflict, something came up; LOST_INTEREST: don't want to, not interested, bored of it;
NOT_NEEDED: no longer needed, dropped the class, already done; BAD_ESTIMATE: underestimated, took longer than expected; anything else is OTHER."""
def llm_classify_cancel(task_title: str, reason: str) -> CancelReason by llm();

def classify_cancel(task_title: str, reason: str) -> CancelReason {
    if not reason.strip() {
        return CancelReason.BUSY;
    }
    r = rule_classify_cancel(reason);
    if r != CancelReason.OTHER or not ai_enabled() {
        return r;
    }
    try {
        out = llm_classify_cancel(task_title, reason);
        ai_ok();
        return out;
    } except Exception as e {
        ai_failed(e);
    }
    return r;
}

def rule_classify_cancel(reason: str) -> CancelReason {
    low = reason.lower();
    if re.search(r"underestimat|took (much )?longer|longer than (i )?(expected|thought)|takes too long|bad estimate|estimate was off", low) {
        return CancelReason.BAD_ESTIMATE;
    }
    if re.search(r"not needed|no longer|don't need|dont need|unnecessary|dropped|drop(ped)? the (class|course)|already (did|done|finished|learned|took)|cancell?ed|course (is )?over", low) {
        return CancelReason.NOT_NEEDED;
    }
    if re.search(r"lost interest|not interested|no interest|don't want|dont want|don't feel like|boring|bored|don't (like|enjoy)|tired of|sick of|lazy|meh", low) {
        return CancelReason.LOST_INTEREST;
    }
    if re.search(r"busy|conflict|no time|out of time|something came up|swamped|overtime|deadline|tired|exhausted|sick|\bill\b|clash", low) {
        return CancelReason.BUSY;
    }
    return CancelReason.OTHER;
}

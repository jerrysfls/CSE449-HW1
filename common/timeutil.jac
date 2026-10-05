"""Time helpers: times are stored as "YYYY-MM-DD HH:MM" strings; also parses English date/time expressions."""

import re;
import from datetime { datetime, timedelta, date }

glob FMT = "%Y-%m-%d %H:%M",
     WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
     WEEKDAY_RE = r"\b(mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b",
     MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"],
     MONTH_RE = r"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?";

def to_dt(s: str) -> datetime {
    return datetime.strptime(s, FMT);
}

def fmt_dt(d: datetime) -> str {
    return d.strftime(FMT);
}

"""Current time; a non-empty clock means simulated time (demo / tests)."""
def resolve_now(clock: str = "") -> datetime {
    if clock {
        return to_dt(clock);
    }
    return datetime.now().replace(second=0, microsecond=0);
}

def weekday_name(d: datetime | date) -> str {
    return WEEKDAYS[d.weekday()];
}

"""Tue 9/30 20:00"""
def pretty(s: str, with_time: bool = True) -> str {
    if not s {
        return "";
    }
    d = to_dt(s);
    base = f"{weekday_name(d)} {d.month}/{d.day}";
    return f"{base} {d.strftime('%H:%M')}" if with_time else base;
}

def pretty_day(d: date) -> str {
    return f"{weekday_name(d)} {d.month}/{d.day}";
}

def hm_of(s: str) -> str {
    return to_dt(s).strftime("%H:%M");
}

def day_of(s: str) -> date {
    return to_dt(s).date();
}

"""datetime at hour:minute on day d."""
def at(d: date, hour: int, minute: int = 0) -> datetime {
    return datetime(d.year, d.month, d.day, hour, minute);
}

def days_until(now: datetime, s: str) -> int {
    return (to_dt(s).date() - now.date()).days;
}

def round_q(h: float) -> float {
    return round(h * 4) / 4;
}

def round_half(h: float) -> float {
    return round(h * 2) / 2;
}

"""1.5h / 45min"""
def hm(h: float) -> str {
    if h < 1.0 {
        return f"{int(round(h * 60))}min";
    }
    txt = f"{h:.2f}".rstrip("0").rstrip(".");
    return f"{txt}h";
}

def week_monday(d: date) -> date {
    return d - timedelta(days=d.weekday());
}

"""Simple English plural: plural(2, "day") -> "2 days"."""
def plural(n: int, word: str) -> str {
    return f"{n} {word}" if n == 1 else f"{n} {word}s";
}

"""A date in the current year, rolled to next year if it is long past."""
def _md(now: datetime, mo: int, dd: int) -> date | None {
    if not (1 <= mo <= 12 and 1 <= dd <= 31) {
        return None;
    }
    try {
        day = date(now.year, mo, dd);
        if day < now.date() - timedelta(days=60) {
            day = date(now.year + 1, mo, dd);
        }
        return day;
    } except ValueError {
        return None;
    }
}

"""Parse a point in time from natural language; returns "YYYY-MM-DD HH:MM", or "" when no date is found.

Supports: 10/1, Oct 1, 1st October, 2026-10-01, today / tonight / tomorrow /
day after tomorrow, in 3 days, (next) Wednesday, plus 3pm, 15:00, 8:30pm,
noon, and "tonight at 8".
"""
def parse_when(text: str, now: datetime, default_hour: int = 23, default_minute: int = 59) -> str {
    t = text.lower();
    day: date | None = None;

    m = re.search(r"(\d{4})-(\d{1,2})-(\d{1,2})", t);
    if m {
        day = date(int(m.group(1)), int(m.group(2)), int(m.group(3)));
    }
    if day is None {
        m = re.search(r"(?<![\d.])(\d{1,2})\s*/\s*(\d{1,2})(?!\s*/)(?![\d.])", t);
        if m {
            day = _md(now, int(m.group(1)), int(m.group(2)));
        }
    }
    if day is None {
        m = re.search(r"\b" + MONTH_RE + r"\s*(\d{1,2})(?:st|nd|rd|th)?\b", t);
        if m {
            day = _md(now, MONTHS.index(m.group(1)[:3]) + 1, int(m.group(2)));
        } else {
            m = re.search(r"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?" + MONTH_RE + r"\b", t);
            if m {
                day = _md(now, MONTHS.index(m.group(2)[:3]) + 1, int(m.group(1)));
            }
        }
    }
    if day is None {
        m = re.search(r"\bin\s+(\d+)\s+days?\b", t);
        if "day after tomorrow" in t {
            day = now.date() + timedelta(days=2);
        } elif m {
            day = now.date() + timedelta(days=int(m.group(1)));
        } elif "tomorrow" in t {
            day = now.date() + timedelta(days=1);
        } elif re.search(r"\b(today|tonight|this (morning|afternoon|evening))\b", t) {
            day = now.date();
        }
    }
    if day is None {
        m = re.search(r"\b(next\s+)?(?:week\s+)?" + WEEKDAY_RE[2:], t);
        if m {
            target = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].index(m.group(2)[:3]);
            if m.group(1) {
                day = week_monday(now.date()) + timedelta(days=7 + target);
            } else {
                day = now.date() + timedelta(days=(target - now.weekday()) % 7);
            }
        }
    }
    if day is None {
        return "";
    }
    (hour, minute) = parse_clock(t);
    if hour < 0 {
        (hour, minute) = (default_hour, default_minute);
    }
    return fmt_dt(at(day, hour, minute));
}

"""Parse a clock time; returns (hour, minute), or (-1, 0) when there is none."""
def parse_clock(t: str) -> tuple {
    t = t.lower();
    m = re.search(r"(?<!\d)(\d{1,2}):(\d{2})\s*(am|pm)?", t);
    if m {
        h = int(m.group(1));
        if m.group(3) == "pm" and h < 12 {
            h += 12;
        } elif m.group(3) == "am" and h == 12 {
            h = 0;
        }
        return (h, int(m.group(2)));
    }
    m = re.search(r"(?<![\d/])(\d{1,2})\s*(am|pm)\b", t);
    if m {
        h = int(m.group(1)) % 12;
        if m.group(2) == "pm" {
            h += 12;
        }
        return (h, 0);
    }
    if re.search(r"\bnoon\b", t) {
        return (12, 0);
    }
    m = re.search(r"\bat\s+(\d{1,2})(?:\s*o'?clock)?(?![\d:/.])", t);
    if m {
        h = int(m.group(1));
        if h < 12 and re.search(r"tonight|evening|night|afternoon", t) {
            h += 12;
        }
        return (h, 0);
    }
    return (-1, 0);
}

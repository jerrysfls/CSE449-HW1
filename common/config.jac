"""Configuration: reads the [companion] section of jac.toml; defaults match the README."""

import os;
import tomllib;

glob DEFAULTS: dict = {
    "timezone": "America/New_York",
    "daily_brief_at": "08:00",
    "max_focus_min": 90,
    "exam_lead_days": 5,
    "quiz_lead_days": 1,
    "buffer_ratio": 0.2,
    "comfort_week_h": 30.0,
    "daily_cap_h": 6.0,
    "high_load_day_h": 5.0,
    "heat_decay_per_day": 0.05,
    "done_heat_gain": 0.15,
    "cancel_weight_drop": 0.1,
    "min_hobby_h_per_week": 1.0,
    "skip_ask_threshold": 3,
    "exam_week_hobby_ratio": 0.35,
    "quiz_mastery_alpha": 0.5,
    "batch_interval_min": 5,
    "replan_threshold": 0.1,
    "model": "gpt-4o-mini"
};

glob CFG: dict = {};

"""Project root (the directory containing jac.toml)."""
def project_root() -> str {
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
}

"""Read jac.toml and flatten [companion] and its sub-tables into one dict."""
def load_config(path: str = "") -> dict {
    merged = dict(DEFAULTS);
    toml_path = path or os.path.join(project_root(), "jac.toml");
    if os.path.exists(toml_path) {
        with open(toml_path, "rb") as f {
            data = tomllib.load(f);
        }
        comp = data.get("companion", {});
        for (k, v) in comp.items() {
            if isinstance(v, dict) {
                for (k2, v2) in v.items() {
                    merged[k2] = v2;
                }
            } else {
                merged[k] = v;
            }
        }
        model_sec = data.get("plugins", {}).get("byllm", {}).get("model", {});
        if model_sec.get("default_model") {
            merged["model"] = model_sec["default_model"];
        }
    }
    if os.environ.get("COMPANION_MODEL") {
        merged["model"] = os.environ["COMPANION_MODEL"];
    }
    CFG.clear();
    CFG.update(merged);
    return CFG;
}

"""Read one config value."""
def cfg(key: str) -> any {
    if not CFG {
        load_config();
    }
    return CFG.get(key, DEFAULTS.get(key));
}

"""For tests: temporarily override a config value."""
def set_cfg(key: str, value: any) -> None {
    if not CFG {
        load_config();
    }
    CFG[key] = value;
}

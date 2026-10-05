"""Model setup.

Every `by llm()` function shares the `llm` defined here. When no API key is found (or
COMPANION_OFFLINE=1 is set), ai_enabled() returns False and every AI function falls back to the rule engine,
so the app works fully offline. After 2 consecutive failures it also trips into offline mode.
"""

import os;
import from byllm.lib { Model }
import from common.config { cfg }

glob llm = Model(model_name=cfg("model"));

glob AI_STATE: dict = {"forced_off": False, "failures": 0, "last_error": ""};

glob KEY_ENVS: list = [
    "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
    "GROQ_API_KEY", "DEEPSEEK_API_KEY", "MISTRAL_API_KEY", "OPENROUTER_API_KEY",
    "TOGETHER_API_KEY", "XAI_API_KEY", "AZURE_API_KEY"
];

def ai_enabled() -> bool {
    if AI_STATE["forced_off"] or os.environ.get("COMPANION_OFFLINE", "") == "1" {
        return False;
    }
    if AI_STATE["failures"] >= 2 {
        return False;
    }
    model = str(cfg("model"));
    if model.startswith("ollama") or model.startswith("local:") or model == "mockllm" {
        return True;
    }
    return any([bool(os.environ.get(k)) for k in KEY_ENVS]);
}

def ai_failed(e: Exception) -> None {
    AI_STATE["failures"] = AI_STATE["failures"] + 1;
    AI_STATE["last_error"] = f"{type(e).__name__}: {str(e)[:160]}";
}

def ai_ok() -> None {
    AI_STATE["failures"] = 0;
}

def set_offline(flag: bool = True) -> None {
    AI_STATE["forced_off"] = flag;
}

def ai_status() -> str {
    if ai_enabled() {
        return f"🤖 AI mode: {cfg('model')}";
    }
    reason = f" (last error: {AI_STATE['last_error']})" if AI_STATE["last_error"] else " (no API key found)";
    return f"🧩 Offline rule mode{reason}";
}

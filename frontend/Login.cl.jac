"""Sign in / sign up. Each account has its own separate data graph on the server."""

import from "@jac/runtime" { jacLogin, jacSignup }

def:pub Login(onDone: Callable[[], None]) -> JsxElement {
    has mode: str = "login",
        username: str = "",
        password: str = "",
        error: str = "",
        busy: bool = False;

    async def submit(e: FormEvent) -> None {
        e.preventDefault();
        ok: bool = False;
        res: dict | None = None;
        name = username.strip();
        if not name or len(password) < 4 {
            error = "Enter a username and a password of at least 4 characters";
            return;
        }
        busy = True;
        error = "";
        try {
            if mode == "signup" {
                res = await jacSignup(name, password);
                if not res["success"] {
                    error = "Sign-up failed: that username may already be taken";
                    busy = False;
                    return;
                }
            }
            ok = await jacLogin(name, password);
        } except Exception as ex {
            ok = False;
        }
        busy = False;
        if ok {
            onDone();
        } else {
            error = "Sign-in failed: wrong username or password" if mode == "login" else "Account created, but auto sign-in failed. Please sign in.";
        }
    }

    def switch_mode(e: MouseEvent) -> None {
        mode = "signup" if mode == "login" else "login";
        error = "";
    }

    return <div className="auth">
        <div className="auth-card card">
            <div className="auth-logo">🧭</div>
            <h1>Jac Companion</h1>
            <p className="muted" style={{"margin": "4px 0 0"}}>A study & life assistant that learns you as you go</p>
            <form onSubmit={submit}>
                <input
                    className="input"
                    placeholder="Username"
                    autoComplete="username"
                    value={username}
                    onChange={lambda e: ChangeEvent { username = e.target.value; }}
                />
                <input
                    className="input"
                    type="password"
                    placeholder="Password"
                    autoComplete={"new-password" if mode == "signup" else "current-password"}
                    value={password}
                    onChange={lambda e: ChangeEvent { password = e.target.value; }}
                />
                {error and <div className="error">{error}</div>}
                <button className="btn primary block" type="submit" disabled={busy}>
                    {("Creating account…" if mode == "signup" else "Signing in…") if busy else ("Sign up & start" if mode == "signup" else "Sign in")}
                </button>
            </form>
            <div className="switch">
                {"Already have an account?" if mode == "signup" else "New here?"}
                <button type="button" onClick={switch_mode}>{"Sign in" if mode == "signup" else "Create an account"}</button>
            </div>
        </div>
    </div>;
}

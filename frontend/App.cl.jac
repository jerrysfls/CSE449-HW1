"""Top level: show the login page when signed out, the main app once signed in."""

import from "@jac/runtime" { jacIsLoggedIn }
import from .Login { Login }
import from .Home { Home }

def:pub App() -> JsxElement {
    has authed: bool = jacIsLoggedIn();

    def on_login() -> None {
        authed = True;
    }

    def on_logout() -> None {
        authed = False;
    }

    if authed {
        return <Home onLogout={on_logout} />;
    }
    return <Login onDone={on_login} />;
}

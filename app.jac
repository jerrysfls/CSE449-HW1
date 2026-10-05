"""Jac Companion - web / PWA / mobile app entry point (full stack).

    jac run                                     no filename: runs jac start app.jac --dev per jac.toml
    jac start app.jac                           server (web app at http://localhost:8000)
    jac build app.jac --client pwa              PWA you can install to a phone home screen
    jac build app.jac --client mobile -p android   Android app (Capacitor, see README)

Server endpoints live in services/companion.jac; the UI is in frontend/. The CLI entry is still main.jac.
"""

import from services.companion {
    Dashboard, Reply, Msg, ItemView, DayView, InterestView, TaskView,
    get_dashboard, send_message, get_digest, setup_profile
}

cl {
    import ".frontend/app.css";
    import from .frontend.App { App }

    def:pub app -> JsxElement {
        return <App />;
    }
}

# 🧭 Jac Companion (implementation)

An always-on personal assistant built in Jac from the design document in [`../README.md`](../README.md): **User × Interest Pool × Planned Tasks**. Interactions in all six directions are propagated by walkers along the edges of the graph.

## Running

Requires Python ≥ 3.11 (this machine uses 3.13; the system Python 3.10 only gets the very old jaclang 0.6).

```powershell
cd jac-companion
py -3.13 -m venv .venv
.venv\Scripts\pip install jaclang byllm      # verified: jaclang 0.16.7 + byllm 0.6.19

.venv\Scripts\jac run main.jac --demo        # demo: runs every example from the design doc in order (nothing is saved)
.venv\Scripts\jac run main.jac               # interactive chat; data is persisted automatically in .jac/data
.venv\Scripts\jac test -d tests              # 34 tests: rules / feedback / loop prevention / session
.venv\Scripts\jac start api.jac              # REST API: POST /walker/say {"text": "..."}
```

Note the explicit `main.jac`: a bare `jac run` (no filename) starts the website. For the web and mobile app, see [Web and mobile app](#web-and-mobile-app) below.

**LLM**: once `OPENAI_API_KEY` is set (or `ANTHROPIC_API_KEY` etc., with the model name changed in `jac.toml` or the `COMPANION_MODEL` environment variable), every `by llm()` function switches on. **Without a key the app falls back to the offline rule engine** (regex parsing of English input, template-generated content), and every feature still works; `--offline` forces offline mode.

Other flags: `--reset` wipes the data, `--now "2026-09-28 08:00"` uses a simulated time.

## Commands

Just talk in plain English ("I'm learning guitar, want to practice 3 hours a week", "STATS 413 midterm 10/1 3pm", "Cancel tonight's run", "Quiz done, 8/10, missed multicollinearity", "All done for today", ...), or use commands:

| Category | Commands |
|---|---|
| View | `/brief` `/week [days] [why]` `/why` `/tasks` `/pool` `/digest` |
| Tasks | `/done <id> [actual hours]` `/done today` `/cancel <id> [reason]` `/postpone <id> [days]` `/quiz <id> 8/10 [missed topics...]` `/quizgen` `/outline` `/lock` `/unlock` |
| Interests | `/weight <interest> 0.7` `/budget <interest> 3` `/when <interest> evening` `/short <interest> 20` `/pause` `/resume` `/archive` `/confirm` `/reject` |
| System | `/plan` `/sync` `/time +1d \| 2026-09-30 21:00 \| now` `/name <name>` `/ai` `/seed` `/reset` `/quit` |

Ids (`t12` for tasks, `b34` for time blocks) are shown in `/tasks` and `/week`.

The offline parser understands dates like `10/1`, `Oct 1`, `5th October`, `today`, `tonight`, `tomorrow`, `in 3 days`, `Friday`, `next Tue`, and times like `3pm`, `15:00`, `8:30pm`, `noon`, `tonight at 8`.

## Web and mobile app

The same Jac code is also a full-stack app: the entry is `app.jac`, server endpoints are in `services/companion.jac`, and the UI is in `frontend/` (`.cl.jac` files compiled to React by jac-client). Every button in the UI becomes the same command as in the CLI (`/done b12`, `/weight Guitar 0.7`, `/time +1d`, ...) and is handled by `user/session.jac`, so the CLI, web and mobile app behave exactly the same.

Requires Node.js (verified with v24) and jac-client installed in `.venv` (verified with 0.3.25). npm dependencies are installed automatically on first start:

```powershell
.venv\Scripts\pip install jac-client
$env:PYTHONIOENCODING = "utf-8"              # recommended on Windows consoles that are not UTF-8
.venv\Scripts\jac run                        # simplest: no filename, starts the website per jac.toml (same as jac start app.jac --dev)
.venv\Scripts\jac start app.jac              # production mode: web app and API both on http://localhost:8000
```

With no filename, `jac run` reads `[project] kind = "fullstack"` and `entry-point = "app.jac"` from `jac.toml` and runs `jac start app.jac --dev`. The web app is at http://localhost:8000 (Vite, with hot reload), the API is on 8001, and the page proxies requests to the API. If a port is taken the next free one is used; go by the `App:` address printed in the terminal. Edits to `.cl.jac` files hot-reload; after editing server-side `.jac` files, press Ctrl+C and run it again. `jac run main.jac` (with the filename) is still the CLI.

Register an account to get started. Each account has its own data graph on the server (separate from the CLI data); on first login you can load sample data with one click.

| Page | Contents |
|---|---|
| Today | Greeting and today's progress, pending questions, new-interest confirmations, reminders; timeline (tap the circle = done, tap the item = postpone / cancel with a reason / log a quiz / lock); upcoming deadlines |
| This week | Schedule for the next 7 days, with a "Why?" toggle (why each block was placed there); one-tap replan |
| Interests | Heat, mastery, weak points; adjust priority, weekly hours and preferred time directly; pause / resume / lock / archive; generate self-test questions and review outlines |
| Chat | Plain English or /commands, just like the CLI; follow-up questions (cancel reason, etc.) have quick replies |
| Me | Load, profile digest and suggestions, time travel (+3 hours / +1 day, for demos), change name, load sample data / clear data, sign out |

Phones get a bottom tab bar; desktops get a left sidebar plus an always-visible chat panel on the right; dark mode is supported.

### Install to a phone home screen (PWA, no Android SDK needed)

```powershell
.venv\Scripts\jac build app.jac --client pwa   # generates the manifest, service worker and icons (pwa_icons/)
.venv\Scripts\jac start app.jac                # detects the built PWA and serves the manifest automatically
```

With the phone and computer on the same Wi-Fi, open `http://<computer IP>:8000` in the phone's browser and choose "Add to Home Screen". Full offline caching and the install prompt need HTTPS, so either deploy to an HTTPS server or use it on localhost only.

- Don't use `jac start --client pwa`: in jaclang 0.16.7 it loads `main.jac` instead of `app.jac`.
- Run `jac build --client pwa` again after changing the UI. To go back to plain web mode, delete `.jac/client/dist`.

### Android app (Capacitor)

The `android/` project has already been generated (`jac setup mobile`), with the app's own icons and splash screen. The mobile app contains only the frontend; all data comes over HTTP from a running Jac server:

1. In `jac.toml`, uncomment `[plugins.client.api]` and set `base_url` to the server address (the server allows CORS by default).
2. Install JDK 21 and Android Studio (Android SDK).
3. Build:

   ```powershell
   .venv\Scripts\jac build app.jac --client mobile --platform android
   # output: android\app\build\outputs\apk\debug\app-debug.apk
   ```

   On Windows, jac-client 0.3.25 fails with "npx or bunx not found": it runs `npx` directly, but on Windows the file is `npx.cmd`. If you hit this, run the same three steps by hand:

   ```powershell
   .venv\Scripts\jac build app.jac                               # 1. bundle the frontend into .jac\client\dist
   node node_modules\@capacitor\cli\bin\capacitor sync android   # 2. copy it into the android project
   cd android; .\gradlew.bat assembleDebug                        # 3. build the APK (or open android/ in Android Studio)
   ```

- The app's pages run at `https://localhost`. To test against `http://<computer IP>:8000` on a LAN, add `"android": {"allowMixedContent": true}` to `capacitor.config.json` and `"cleartext": true` under `server`. For real use, deploy the server behind HTTPS.
- iOS needs macOS and Xcode: `jac setup mobile --platform ios`.

## Code layout

Matches the project structure in the design doc, plus `common/` (config, time parsing, graph helpers), `user/chat.jac` (conversation routing) and `api.jac` (REST entry).

| Walker in the design | Location |
|---|---|
| `update_interest` / `task_action` | `user/actions.jac` |
| `plan_week` / `plan_task` | `tasks/planner.jac` (rules in `tasks/rules.jac`, free time in `tasks/slots.jac`) |
| `feedback` | `sync/feedback.jac` |
| `discover_interest` | `interests/discover.jac` |
| `sync` (batching + loop prevention + time passing) | `sync/sync.jac`; the event bus is in `sync/events.jac` |
| `daily_brief` / `profile_digest` / `check_reminders` | `notify/` |
| `chat` | `user/chat.jac` (intent parsing in `ai/parse.jac`) |
| One turn of input (command / natural language / follow-up answer), shared by CLI and web | `user/session.jac` |
| Web / app endpoints (`get_dashboard`, `send_message`, `get_digest`, `setup_profile`) | `services/companion.jac` |
| UI | `app.jac` (entry), `frontend/Home.cl.jac` (state and interactions), `frontend/views/*.cl.jac` (pages), `frontend/app.css` |

## Differences from the design doc

- Jac 0.16 syntax: node type filters are written `[here -->][?:Interest]`; the REST server command is `jac start` (not `jac serve`).
- A "week" is a calendar week (Monday to Sunday); on weekends next week is planned too.
- Today's time blocks are only marked SKIPPED once the day is over, so you can report "All done for today" in one go in the evening.
- Weight changes affect the actual weekly allocation: `budget × (current weight / weight when the budget was set)²`, so "lost interest" takes guitar from 3h to 2h.
- `jac check`'s strict type checking still reports errors (mostly Optional / Any narrowing); they don't affect `jac run` or `jac test`. `app.jac`, `frontend/` and `services/` pass the check (warnings only).
- The jaclang 0.16.7 client runtime doesn't support `"sep".join(list)`, so the frontend joins strings with `joined()` in `frontend/views/Common.cl.jac`.

"""Feedback (task -> interest pool): update heat, weight, mastery and weak points along Feeds edges."""

import from user.user { current_user }
import from interests.pool { Interest, InterestKind, InterestStatus, clamp01, Feeds }
import from interests.dynamics { log_heat }
import from tasks.task { Task, TaskKind }
import from ai.classify { CancelReason }
import from common.config { cfg }
import from common.graph { tasks_of_interest }
import from sync.events { emit_event }

walker feedback {
    has event: str,                          # done | block_done | finished | cancel | skip | quiz
        reason: CancelReason | None = None,
        score: float = 0.0,
        wrong_topics: list[str] = [],
        task_title: str = "",
        out: list[str] = [],
        changes: list[dict] = [];

    can start with Task entry {
        self.task_title = here.title;
        visit [here ->:Feeds:->];
    }

    can update with Interest entry {
        if here.locked {
            self.out.append(f"🔒 {here.label()} is locked, so automatic updates leave it alone");
            disengage;
        }
        u = current_user();
        now_s = u.now_str() if u is not None else "";
        day_s = now_s[:10];
        before = {"weight": here.weight, "heat": here.heat, "mastery": here.mastery, "status": here.status.name};

        if self.event == "done" or self.event == "block_done" {
            here.heat = clamp01(here.heat + float(cfg("done_heat_gain")));
            if here.kind == InterestKind.STUDY {
                here.mastery_prev = here.mastery;
                here.mastery = round(clamp01(here.mastery + (0.03 if self.event == "done" else 0.01)), 3);
            }
            here.skip_streak = 0;
            here.last_active = now_s;
        } elif self.event == "finished" {
            # exam over / project delivered: if other rigid tasks remain only raise heat, otherwise archive or lower the weight
            here.heat = clamp01(here.heat + float(cfg("done_heat_gain")));
            here.last_active = now_s;
            others = [t for t in tasks_of_interest(here) if t.is_open() and t.is_rigid()];
            if not others {
                is_final = "final" in self.task_title.lower();
                if here.kind == InterestKind.WORK or is_final {
                    here.status = InterestStatus.ARCHIVED;
                    self.out.append(f"🏁 {here.label()} has wrapped up and was archived automatically");
                } else {
                    here.weight = round(clamp01(here.weight - 0.1), 3);
                    self.out.append(f"🏁 {self.task_title} is over; {here.label()} weight {before['weight']:.1f} → {here.weight:.1f}");
                }
            }
        } elif self.event == "quiz" {
            alpha = float(cfg("quiz_mastery_alpha"));
            here.mastery_prev = here.mastery;
            here.mastery = round(clamp01((1 - alpha) * here.mastery + alpha * self.score), 3);
            for w in self.wrong_topics {
                if w and w not in here.weak_points {
                    here.weak_points.append(w);
                }
            }
            here.heat = clamp01(here.heat + float(cfg("done_heat_gain")) / 2);
            here.last_active = now_s;
            self.out.append(f"{here.name} mastery {before['mastery']:.2f} → {here.mastery:.2f}");
            if self.wrong_topics {
                self.out.append(f"Weak points noted: {', '.join(self.wrong_topics)}");
            }
        } elif self.event == "cancel" {
            if self.reason == CancelReason.LOST_INTEREST {
                here.weight = round(clamp01(here.weight - float(cfg("cancel_weight_drop"))), 3);
                self.out.append(f"{here.label()} weight {before['weight']:.1f} → {here.weight:.1f}");
            } elif self.reason == CancelReason.NOT_NEEDED {
                here.status = InterestStatus.ARCHIVED;
                self.out.append(f"🗄️ {here.label()} archived");
            }
        } elif self.event == "skip" {
            here.heat = round(here.heat * 0.7, 3);
            here.skip_streak += 1;
            if here.skip_streak % int(cfg("skip_ask_threshold")) == 0 {
                emit_event("ask_importance", here.name, {"streak": here.skip_streak});
            }
        }

        log_heat(here, day_s);
        for f in ["weight", "heat", "mastery"] {
            after = getattr(here, f);
            if abs(after - before[f]) > 1e-9 {
                ch = {"interest": here.name, "field": f, "before": before[f], "after": after, "cause": self.event};
                self.changes.append(ch);
                emit_event("interest_changed", here.name, ch);
            }
        }
        if here.status.name != before["status"] {
            ch = {"interest": here.name, "field": "status", "before": before["status"], "after": here.status.name, "cause": self.event};
            self.changes.append(ch);
            emit_event("interest_status", here.name, ch);
        }
    }
}

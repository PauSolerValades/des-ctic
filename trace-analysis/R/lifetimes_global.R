library(survival)
library(survminer)
library(arrow)
library(dplyr)
library(tibble)
library(optparse)
library(ggplot2)

# ── 0. Paths & parameters ───────────────────────────────────────────────

option_list <- list(
  make_option("--data-dir", type = "character", default = "../data",
              help = "Path to dataset directory [default: %default]"),
  make_option("--out-dir",  type = "character", default = "output",
              help = "Output directory [default: %default]"),
  make_option("--warmup-cutoff", type = "double", default = 1000,
              help = "Drop posts with creation_time < this value [default: %default]")
)

opts <- parse_args(OptionParser(option_list = option_list))
DATA_DIR      <- opts[["data-dir"]]
OUT_DIR       <- opts[["out-dir"]]
WARMUP_CUTOFF <- opts[["warmup-cutoff"]]

cat(sprintf("DATA_DIR       = %s\n", DATA_DIR))
cat(sprintf("OUT_DIR        = %s\n", OUT_DIR))
cat(sprintf("WARMUP_CUTOFF  = %.0f\n", WARMUP_CUTOFF))

# ── 1. Load data ─────────────────────────────────────────────────────────

cat("\nLoading post_lifetime.parquet...\n")
lifetime <- read_parquet(file.path(DATA_DIR, "post_lifetime.parquet"))
cat(sprintf("post_lifetime: %d rows (all)\n", nrow(lifetime)))

# ── 2. Warmup filter ─────────────────────────────────────────────────────

lifetime <- lifetime %>% filter(creation_time >= WARMUP_CUTOFF)
cat(sprintf("After warmup filter (creation_time >= %.0f): %d rows\n",
            WARMUP_CUTOFF, nrow(lifetime)))

# ═══════════════════════════════════════════════════════════════════════════════
# NOTE: We intentionally exclude posts with zero reposts (total_reposts == 0).
# post_lifetime already only contains posts with ≥ 1 repost, so every row
# here is a cascade.
#
# This analysis measures cascade duration — the time from post creation to
# the last repost. A post that never received any repost has no cascade, so
# there is no cascade-lifetime to measure. Including them as "dead at time 0"
# would incorrectly imply their cascade ended instantly, when in reality no
# cascade ever began. They are simply out of scope for this question.
#
# If you are instead interested in "what fraction of posts ever get reposted",
# that is a binomial proportion, not a survival problem — see post_metrics.
#
# This is a GLOBAL analysis: all runs are pooled together. τ is computed
# once across the entire dataset, not per-run.
# ═══════════════════════════════════════════════════════════════════════════════

# ── 3. Compute duration & global censoring threshold τ ───────────────────

surv_data <- lifetime %>%
  mutate(duration = last_repost - creation_time)

tau <- quantile(surv_data$duration, probs = 0.99, na.rm = TRUE)
cat(sprintf("\nGlobal τ (99th percentile): %.2f\n", tau))

surv_data <- surv_data %>%
  mutate(
    dead      = duration <= tau,
    surv_time = ifelse(dead, duration, tau),
    event     = ifelse(dead, 1L, 0L)
  ) %>%
  select(run_id, post_id, surv_time, event, duration, total_reposts)

cat(sprintf("Cascades: %d total\n", nrow(surv_data)))
cat(sprintf("  Dead     (duration ≤ τ): %d (%.1f%%)\n",
            sum(surv_data$event == 1),
            sum(surv_data$event == 1) / nrow(surv_data) * 100))
cat(sprintf("  Censored (duration > τ): %d (%.1f%%)\n",
            sum(surv_data$event == 0),
            sum(surv_data$event == 0) / nrow(surv_data) * 100))

# ── 4. Kaplan-Meier (global, no stratification) ─────────────────────────

cat("\n── Global survival (Kaplan-Meier) ──\n")

fit <- survfit(Surv(surv_time, event) ~ 1, data = surv_data)
print(fit)

# ── 5. S(t) at key time points ──────────────────────────────────────────

cat("\n── S(t) at key time points ──\n")

event_times <- surv_data$surv_time[surv_data$event == 1]
times <- quantile(event_times, probs = c(0.25, 0.5, 0.75, 0.9, 0.99), na.rm = TRUE)
times <- round(times, 2)
cat(sprintf("Time points: %s\n", paste(times, collapse = ", ")))

st_summary <- summary(fit, times = times)
st_df <- data.frame(
  time  = st_summary$time,
  surv  = st_summary$surv,
  lower = st_summary$lower,
  upper = st_summary$upper
)
print(st_df)

# ── 6. Duration distribution summary ─────────────────────────────────────

cat("\n── Duration distribution (dead cascades only) ──\n")
dead_durations <- surv_data$duration[surv_data$event == 1]
print(summary(dead_durations))

# ── 7. Plot ──────────────────────────────────────────────────────────────

cat("\n── Plotting survival curve ──\n")

p <- ggsurvplot(
  fit,
  data = surv_data,
  conf.int = TRUE,
  palette = "#2E86AB",
  ggtheme = theme_minimal(),
  xlab = "Time (cascade duration)",
  ylab = "Survival probability S(t)",
  title = "Cascade lifetime survival — global (warmup excluded)",
  legend = "none",
  surv.median.line = "hv",
  break.time.by = 1000
)

ggsave(file.path(OUT_DIR, "global_survival_plot.png"),
       plot = p$plot, width = 8, height = 5, dpi = 150)
cat(sprintf("Saved plot to %s/global_survival_plot.png\n", OUT_DIR))

# ── 8. Save results ─────────────────────────────────────────────────────

dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

# S(t) at fixed times
write.csv(st_df, file.path(OUT_DIR, "global_st.csv"), row.names = FALSE)

# Full survival curve
surv_out <- data.frame(
  time  = fit$time,
  n.risk = fit$n.risk,
  n.event = fit$n.event,
  surv  = fit$surv,
  lower = fit$lower,
  upper = fit$upper
)
write.csv(surv_out, file.path(OUT_DIR, "global_surv_curve.csv"), row.names = FALSE)

cat(sprintf("\n── Results saved to %s/ ──\n", OUT_DIR))
cat("  global_st.csv             (S(t) at key time points)\n")
cat("  global_surv_curve.csv     (full survival curve)\n")
cat("  global_survival_plot.png  (Kaplan-Meier plot)\n")

cat("\nDone!\n")

library(survival)
library(survminer)
library(arrow)
library(dplyr)
library(tibble)

# ── 0. Paths ─────────────────────────────────────────────────────────────
library(optparse)

option_list <- list(
  make_option("--data-dir", type = "character", default = "../data",
              help = "Path to dataset directory [default: %default]"),
  make_option("--out-dir",  type = "character", default = "output",
              help = "Output directory [default: %default]")
)

opts <- parse_args(OptionParser(option_list = option_list))
DATA_DIR <- opts[["data-dir"]]
OUT_DIR  <- opts[["out-dir"]]


cat("Loading post_lifetime.parquet...\n")
lifetime <- read_parquet(file.path(DATA_DIR, "post_lifetime.parquet"))
cat(sprintf("post_lifetime: %d rows (all)\n", nrow(lifetime)))

# ── 1b. Drop warmup (creation_time < 1000) ────────────────────────────────────

warmup_cutoff <- 1000
lifetime <- lifetime %>% filter(creation_time >= warmup_cutoff)
cat(sprintf("post_lifetime: %d rows (creation_time >= %d, warmup removed)\n",
            nrow(lifetime), warmup_cutoff))

# ═══════════════════════════════════════════════════════════════════════════════
# NOTE: We intentionally exclude posts with zero reposts (total_reposts == 0).
#
# This analysis measures cascade duration — the time from post creation to
# the last repost. A post that never received any repost has no cascade, so
# there is no duration to measure. Including them as "dead at time 0" would
# incorrectly imply their cascade ended instantly, when in reality no cascade
# ever began. They are simply out of scope for this question.
#
# If you are instead interested in "what fraction of posts ever get reposted",
# that is a binomial proportion, not a survival problem — see post_metrics.
# ═══════════════════════════════════════════════════════════════════════════════

# ── 2. Compute duration & censoring threshold τ per run ───────────────────────

surv_data <- lifetime %>%
  mutate(duration = last_repost - creation_time) %>%
  group_by(run_id) %>%
  mutate(
    tau      = quantile(duration, probs = 0.99, na.rm = TRUE),
    dead     = duration <= tau,
    surv_time = ifelse(dead, duration, tau),
    event    = ifelse(dead, 1L, 0L)
  ) %>%
  ungroup() %>%
  select(run_id, post_id, surv_time, event, tau)

cat(sprintf("\nSurvival data: %d cascades\n", nrow(surv_data)))
cat(sprintf("  Dead  (duration ≤ τ): %d\n", sum(surv_data$event == 1)))
cat(sprintf("  Censored (duration > τ): %d\n", sum(surv_data$event == 0)))

# Show τ range across runs
tau_range <- surv_data %>%
  distinct(run_id, tau) %>%
  summarise(min_tau = min(tau), max_tau = max(tau), mean_tau = mean(tau))
cat(sprintf("τ range across runs: %.2f – %.2f (mean %.2f)\n",
            tau_range$min_tau, tau_range$max_tau, tau_range$mean_tau))

# ── 3. Overall S(t) — Kaplan-Meier ───────────────────────────────────────────

cat("\n── Overall survival ──\n")

fit_all <- survfit(Surv(surv_time, event) ~ 1, data = surv_data)
print(fit_all)

# ── 4. S(t) per run_id ───────────────────────────────────────────────────────

cat("\n── Per-run survival ──\n")

fit_run <- survfit(Surv(surv_time, event) ~ run_id, data = surv_data)

# Extract median survival per run
run_summary <- summary(fit_run)$table %>%
  as.data.frame() %>%
  tibble::rownames_to_column("run_label") %>%
  mutate(run_id = as.integer(gsub("run_id=", "", run_label)))

cat(sprintf("\nRuns: %d\n", nrow(run_summary)))
cat(sprintf("Median survival range: %.2f – %.2f\n",
            min(run_summary$median, na.rm = TRUE),
            max(run_summary$median, na.rm = TRUE)))

print(head(run_summary[, c("run_id", "records", "events", "median", "0.95LCL", "0.95UCL")], 10))

# ── 5. Survival probability at key time points per run ────────────────────────

cat("\n── S(t) at key time points (per run) ──\n")

# Summary at fixed quantiles of event times
event_times <- surv_data$surv_time[surv_data$event == 1]
times <- quantile(event_times, probs = c(0.25, 0.5, 0.75, 0.9, 0.99), na.rm = TRUE)
times <- round(times, 2)
cat(sprintf("Time points: %s\n", paste(times, collapse = ", ")))

st_summary <- summary(fit_run, times = times)
st_df <- data.frame(
  run_id = gsub("run_id=", "", st_summary$strata),
  time   = st_summary$time,
  surv   = st_summary$surv,
  lower  = st_summary$lower,
  upper  = st_summary$upper
)
print(head(st_df, 20))

# ── 6. Aggregate: mean S(t) across runs ──────────────────────────────────────

cat("\n── Aggregate S(t) across runs ──\n")

# Compute mean survival at each unique time point across all runs
agg_surv <- st_df %>%
  group_by(time) %>%
  summarise(
    mean_surv = mean(surv, na.rm = TRUE),
    sd_surv   = sd(surv, na.rm = TRUE),
    n_runs    = n(),
    .groups   = "drop"
  ) %>%
  arrange(time)

print(agg_surv, n = 30)

# ── 7. Save results ──────────────────────────────────────────────────────────

dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

# Per-run summary
write.csv(run_summary, file.path(OUT_DIR, "run_survival_summary.csv"), row.names = FALSE)

# Aggregate S(t)
write.csv(agg_surv, file.path(OUT_DIR, "aggregate_survival.csv"), row.names = FALSE)

# S(t) at fixed times per run
write.csv(st_df, file.path(OUT_DIR, "per_run_st_at_times.csv"), row.names = FALSE)

cat(sprintf("\n── Results saved to %s/ ──\n", OUT_DIR))
cat("  run_survival_summary.csv\n")
cat("  aggregate_survival.csv\n")
cat("  per_run_st_at_times.csv\n")

cat("\nDone!\n")

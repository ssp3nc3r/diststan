# Demonstration of {diststan}.  Run with:  Rscript inst/examples/dist_stan_demo.R
# (or, once installed, source(system.file("examples", "dist_stan_demo.R", package = "diststan")))
#
# Stage A runs immediately on THIS machine only (no SSH). To still exercise the
# multi-machine path -- in particular the GLOBAL chain-id blocks -- it uses two
# local "machines" (localhost + 127.0.0.1, distinct mirai profiles, both driven
# without SSH). Stage B is the real heterogeneous cross-machine run.

library(diststan)
library(cmdstanr)
# No set_cmdstan_path() needed: each machine (and each daemon) auto-detects its
# own CmdStan, as cmdstanr normally does. Set CMDSTAN or call set_cmdstan_path()
# only if yours is in a nonstandard location.

# The toy model ships in the package; copy it to a writable working dir so the
# (mount-transport) demo can stage data next to it.
work <- file.path(tempdir(), "diststan-demo")
dir.create(work, showWarnings = FALSE)
file.copy(list.files(system.file("stan", package = "diststan"), full.names = TRUE),
          work, overwrite = TRUE)

set.seed(1)
N   <- 300000
dat <- list(N = N, y = rnorm(N, mean = 10, sd = 3))   # truth: mu = 10, sigma = 3

# Per-machine grainsize from that machine's threads (mirrors real models that tie
# grainsize to threads_per_chain).
grain <- function(d, t) { d$grainsize <- max(1L, d$N %/% (t * 2L)); d }

# =============================================================================
# STAGE A -- local smoke test (two local "machines", 2 chains each, no SSH)
# =============================================================================
out_a <- file.path(work, "out_A")
message("\n=== STAGE A: 2 local machines x 2 chains ===")

cl_a <- dist_cluster(
  hosts             = c("localhost", "127.0.0.1"), # two distinct local profiles
  chains            = c(2, 2),                      # machine1 -> ids 1:2, machine2 -> 3:4
  threads_per_chain = 2,                            # scalar => same on both
  work_dir          = work
)

res_a <- dist_sample(
  stan_file         = "demo_reduce_sum.stan",      # relative to work_dir
  data              = dat,                          # in-memory; staged + cleaned
  cluster           = cl_a,
  output_dir        = out_a,
  user_header       = "demo_funcs.hpp",
  prep_data         = grain,
  iter_warmup = 500, iter_sampling = 500, seed = 2024, refresh = 200
)

cat("\nGathered CSVs (one row per chain, global ids):\n"); print(res_a)
fit_a <- as_cmdstan_fit(res_a$csv)                  # exactly as a single 4-chain run
cat("\nCombined posterior across the 4 distributed chains:\n")
print(fit_a$summary(c("mu", "sigma")))              # expect mu~10, sigma~3, rhat~1
message("=== STAGE A complete ===")

# =============================================================================
# STAGE B -- real heterogeneous cross-machine run (edit, then enable)
# =============================================================================
RUN_STAGE_B <- FALSE
if (RUN_STAGE_B) {
  # Prereqs: passwordless SSH to each host; cmdstan 2.39 at the same path on
  # each; {mirai}/{cmdstanr} installed on each; this project + output_dir
  # reachable at the SAME path on every host (your shared mount).
  proj <- "/Volumes/WORK_A/Projects/sas/nottingham"   # source on the shared mount
  cl_b <- dist_cluster(
    hosts             = c("scottspencer@talkingspoons",  # M3 Ultra = THIS machine (no SSH)
                          "scottspencer@bendingspoons",  # M5 Max
                          "scottspencer@talkingforks"),  # M2 Ultra
    chains            = c(2, 1, 1),         # 2 chains on the M3 Ultra, 1 each elsewhere
    threads_per_chain = NA,                 # NA => each host's cores / parallel_chains
    work_dir          = proj
    # url = "tcp://10.0.0.1:0"   # uncomment to force dial-back over 10GbE/TB5
  )
  res_b <- dist_sample(
    stan_file         = "models/demo_reduce_sum.stan",
    data              = dat,
    cluster           = cl_b,
    output_dir        = file.path(proj, "dist_demo_B"),
    user_header       = "models/demo_funcs.hpp",
    prep_data         = grain,
    iter_warmup = 1000, iter_sampling = 1000, seed = 2024, refresh = 100
  )
  print(res_b)
  fit_b <- as_cmdstan_fit(res_b$csv)
  print(fit_b$summary(c("mu", "sigma")))
}

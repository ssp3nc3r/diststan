# diststan

Run [cmdstanr](https://mc-stan.org/cmdstanr/) MCMC chains across a small
heterogeneous cluster of machines over SSH using
[mirai](https://mirai.r-lib.org/), gathering every chain's draws into one common
directory ready for post-processing.

Describe the cluster once with `dist_cluster()` — the hosts, how many chains each
runs, threads, transport, dial-back — then `dist_sample()` is a **drop-in for
`mod$sample()`** with one extra argument, `cluster=`. Per-machine settings
(`chains`, `threads_per_chain`, `parallel_chains`) are scalars (recycled to all
hosts) or vectors aligned to `hosts`; every other `$sample()` argument passes
straight through with cmdstanr's own names/defaults.

```r
library(diststan)
library(cmdstanr)

cl <- dist_cluster(
  hosts             = c("me@mac-studio",          # this machine (no SSH)
                        "me@mac-mini",
                        "me@macbook"),
  chains            = c(2, 1, 1),                 # per host; NA => one chain per host
  threads_per_chain = NA,                          # NA => that host's cores / parallel_chains
  work_dir          = "/Volumes/shared/project"   # same path on every host
)

out <- dist_sample(
  stan_file   = "models/model.stan",              # relative to work_dir
  data        = "data/dat.rds",                   # path on the shared mount (or an in-memory list)
  cluster     = cl,
  output_dir  = "/Volumes/shared/project/draws",
  user_header = "models/model.hpp",
  iter_warmup = 1000, iter_sampling = 1000, seed = 123   # plain cmdstanr args
)

fit <- as_cmdstan_fit(out$csv[out$status == "ok"])   # combine surviving chains
```

`dist_cluster()` returns an R6 object, so there's also an object-oriented form
that mirrors cmdstanr's `mod$sample()` — pick whichever reads better:

```r
out <- cl$sample(
  stan_file   = "models/model.stan",
  data        = "data/dat.rds",
  output_dir  = "/Volumes/shared/project/draws",
  user_header = "models/model.hpp",
  iter_warmup = 1000, iter_sampling = 1000, seed = 123
)
```

No shared filesystem and no VPN? Just SSH — push inputs out, pull draws back, and
tunnel the dial-back through SSH. It's the same call; only the cluster changes:

```r
cl <- dist_cluster(
  hosts     = c("me@box1", "me@box2", "me@box3"),
  chains    = c(2, 1, 1),
  transport = "copy",                            # push inputs, pull draws back
  tunnel    = TRUE                                # dial-back over SSH (no open ports/VPN)
)

out <- dist_sample(
  stan_file   = "models/model.stan",             # paths on THIS machine (the controller)
  data        = "data/dat.rds",
  cluster     = cl,
  output_dir  = "draws/run1",                    # controller-local; gathered draws land here
  user_header = "models/model.hpp",
  iter_warmup = 1000, iter_sampling = 1000, seed = 123
)
```

(The loose form — passing `hosts=`, `chains=`, … straight to `dist_sample()`
without a `cluster` — still works for one-off runs.)

## How it works

- **One ordinary cmdstanr call per machine.** `chains = c(2,1,1)` runs
  `sample(chains=2)` on machine 1 and `sample(chains=1)` on the others.
- **Global chain ids.** Each machine gets a contiguous id block (machine 1 →
  `1:2`, machine 2 → `3`, …) and a shared `seed`, so pooled draws have distinct
  ids and reproduce a single `sample(chains=N, seed=S)` run. Output files follow
  cmdstanr's convention (`<model>-<stamp>-<chain>.csv`).
- **Per-machine native compile.** Each host compiles its own binary to a local
  (by default temporary, auto-erased) `exe_dir`, so mixed Apple-Silicon
  generations each get a native build and nothing collides.
- **Fault tolerant.** A host that fails to compile, errors, or drops off the
  network doesn't take the run down or hang it: its real error is surfaced (the
  cmdstan message, streamed live and in the result), the other machines finish,
  and you get one row per chain with `status` ("ok"/"failed") + `error`. Combine
  the survivors with `as_cmdstan_fit(out$csv[out$status == "ok"])`.
- **Two transports.** `transport = "mount"` (default): `stan_file`/`data`/
  `output_dir` are paths on a shared filesystem at the same location on every
  host -- nothing is copied. `transport = "copy"`: those paths are on the
  *controller*; inputs are pushed to a per-host temp dir and each host's draws are
  pulled back into your local `output_dir` (compressed in transit). Use `"copy"`
  when there is no shared mount.
- **Dial-back, with or without a routable controller.** Workers connect back to
  the controller. By default that's a direct connection (works on a flat LAN, or
  pass `url=` for a specific address such as a Tailscale IP). Set `tunnel = TRUE`
  to route the dial-back through the SSH connection instead -- so it works on any
  plain-SSH network with no open ports, no Tailscale, no shared filesystem.
- **Combined live progress.** Each machine's native cmdstan output is streamed
  back as it arrives (read from the shared dir, or over SSH in `copy` mode), with
  cmdstan's per-run chain numbers rewritten to global ids.

## Functions

| function | role |
|---|---|
| `dist_cluster()` | describe the cluster once (hosts, chains, threads, transport, dial-back); reuse across fits |
| `dist_sample()` | one call: (optional push) → fit → live board → gathered CSVs |
| `dist_fit()` | non-blocking launch; returns a handle |
| `dist_progress()` | combined live board + teardown for a handle |
| `dist_push()` | rsync source + data to each host (used by `transport = "copy"`) |

## Requirements

- `mirai` (>= 2.6) and `cmdstanr` installed on **every** machine, with cmdstan at
  the same path.
- Passwordless SSH from the controller to each remote host.
- For `transport = "mount"` only: the project (`work_dir`) and `output_dir`
  reachable at the **same absolute path** on every machine (e.g. NFS/SMB). With
  `transport = "copy"` + `tunnel = TRUE`, **SSH is all you need** -- no shared
  mount and no routable controller.

## Try it

```r
source(system.file("examples", "dist_stan_demo.R", package = "diststan"))
```

Stage A of the demo runs entirely on one machine (two local mirai profiles, no
SSH) so you can validate the whole pipeline before configuring the cluster.

## Status

Local (single-machine, multi-profile) path is validated. The cross-machine SSH
path is implemented and ready to test on a real cluster. Not yet on CRAN; install
locally with `devtools::install("/path/to/diststan")`.

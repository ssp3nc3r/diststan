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

## Prerequisites

On **every** machine (the controller and each worker):

- **R**, with **`cmdstanr`** and **`mirai` (>= 2.6)** installed.
- A **working CmdStan toolchain** that cmdstanr can compile with — i.e.
  `cmdstanr::check_cmdstan_toolchain()` passes and `cmdstan_model()` builds a
  model locally. Each host uses *its own* CmdStan (auto-detected from the
  `CMDSTAN` env var or `~/.cmdstan`, exactly as cmdstanr does), so the install
  path does **not** need to match across machines. Pass `cmdstan_path=` only if
  you deliberately want one shared path.
- Your **model + any custom C++ header** must compile on each host. diststan
  ships the `.stan`/`.hpp` to every machine but does not make your C++ portable
  (see [Platforms](#platforms)).

On the **controller** (the machine you launch from):

- **Passwordless SSH** to each worker (key-based — `ssh me@worker` connects with
  no prompt). Each worker therefore needs an **SSH server** running and reachable.

Depending on transport:

- **`transport = "mount"`** — the project (`work_dir`) and `output_dir` must be
  reachable at the **same absolute path** on every machine (NFS/SMB/etc.).
  Nothing is copied.
- **`transport = "copy"`** — **`rsync`** must be on the controller *and* each
  worker (inputs are pushed and draws pulled back over SSH). With
  `transport = "copy"` + `tunnel = TRUE`, **SSH is all you need** — no shared
  mount, no VPN, no open ports.

## Platforms

In principle diststan runs across a **mixed cluster of macOS, Linux, and
Windows**: each host compiles its *own* native binary and auto-detects its *own*
CmdStan, and the defaults are portable (`cpp_options = list(stan_threads =
TRUE)`, nothing platform-specific linked). Two caveats:

- **Compiler flags and custom C++ are yours to keep portable.** If your model
  needs, say, Apple's Accelerate, add it on the relevant hosts yourself —
  `cpp_options = list(stan_threads = TRUE, LDFLAGS_OS = "-framework Accelerate")`
  — and a `user_header` that calls OS-specific intrinsics will only build where
  they exist.
- **`transport = "copy"` needs `rsync`** (and SSH) on every host; on Windows that
  means Git Bash / WSL / cwRsync, or simply use `transport = "mount"`.

The author's day-to-day cluster is all Apple Silicon, so the cross-OS paths are
designed-in but not yet battle-tested — reports welcome.

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

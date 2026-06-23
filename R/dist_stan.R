# Distributed Stan fitting across a small heterogeneous cluster, via {mirai}.
#
# Interface goal: a drop-in for cmdstanr's `$sample()`. You add a `hosts` vector
# naming the machines (in order); any cmdstanr argument that can sensibly differ
# per machine -- `chains`, `threads_per_chain`, `parallel_chains` -- may be a
# vector aligned to `hosts` (a scalar is recycled to all). Every other
# `$sample()` argument passes straight through with cmdstanr's own name/default.
#
# Each machine runs ONE ordinary cmdstanr call (so `chains = c(2,1,1)` => machine
# 1 runs `sample(chains=2)`, the others `sample(chains=1)`). Chain ids are handed
# out as GLOBAL contiguous blocks (machine 1 -> 1:2, machine 2 -> 3, ...) so the
# pooled draws have distinct ids and a shared `seed` reproduces exactly what a
# single `sample(chains=4, seed=S)` run would. Every chain writes its CSV to one
# common directory, already gathered for post-processing. Fitting only.
#
# Two transports (see dist_sample):
#   "mount" (default): source + data read from a shared dir at the SAME path on
#       every host; each host compiles to its own LOCAL `exe_dir` (so M2/M3/M5
#       each build a native binary; nothing collides).
#   "push": rsync source + data to a per-host local dir first.
#
# Public: dist_sample() (one call), and the pieces dist_push() / dist_fit()
# (non-blocking) / dist_progress() (live board + teardown).
#
# Requires: mirai (>= 2.6), cmdstanr, cmdstan 2.39, passwordless SSH to each
# remote host, and `output_dir` (plus, for "mount", `work_dir`) reachable at the
# SAME path on every machine.

# ---- internal helpers ---------------------------------------------------------

# Which hosts are this controller (driven without SSH)? Accepts "user@host.dom".
.dist_is_local <- function(hosts) {
  norm <- function(x) tolower(sub("\\..*$", "", sub("^[^@]*@", "", x)))
  hosts %in% c("localhost", "127.0.0.1") | norm(hosts) == norm(Sys.info()[["nodename"]])
}

# Recycle a per-machine arg to length n (scalar -> all; length n -> as is).
.dist_recycle <- function(x, n, nm) {
  if (length(x) == 1L) return(rep(x, n))
  if (length(x) == n) return(x)
  stop(sprintf("`%s` must be length 1 or %d (number of hosts)", nm, n))
}

# For a pass-through `...` arg: a length-n vector is split per machine, anything
# else (scalar, or a within-machine vector like a per-chain seed) goes to all.
.dist_pick <- function(x, i, n) if (length(x) == n && n > 1L) x[[i]] else x

# The per-machine task that runs on a daemon. Top-level but shipped with its
# environment reset to baseenv(), so it serializes without dragging globals; uses
# only its args and fully-qualified (pkg::) calls.
.dist_machine_task <- function(machine_id, host, chains, chain_ids,
                               parallel_chains, threads_per_chain,
                               work_dir, exe_dir, stan_path, data_path,
                               header_path, cpp_options, stanc_options,
                               cmdstan_path, output_dir, run_id, init, prep_data,
                               sample_args) {
  if (!is.null(cmdstan_path)) cmdstanr::set_cmdstan_path(cmdstan_path)
  setwd(path.expand(work_dir))
  if (is.null(parallel_chains)) parallel_chains <- chains
  if (is.na(threads_per_chain))
    threads_per_chain <- max(1L, parallel::detectCores() %/% parallel_chains)

  # Tiny per-machine log on the shared dir. sink() captures cmdstan's native
  # progress stream LIVE (verified), so it holds only the "Chain k Iteration..."
  # lines -- no draws, no bloat.
  output_dir <- path.expand(output_dir)   # may be a per-host "~/..." dir in copy mode
  prog_dir <- file.path(output_dir, ".progress")
  dir.create(prog_dir, recursive = TRUE, showWarnings = FALSE)
  log_file <- file.path(prog_dir, sprintf("%s-machine%d.log", run_id, machine_id))
  con <- file(log_file, open = "wt")
  sink(con); sink(con, type = "message")
  on.exit({ sink(type = "message"); sink(); close(con) }, add = TRUE)
  # structured marker -> the controller renders the aligned per-machine banner
  # line (it already knows this machine's host + chains); only threads is new.
  cat(sprintf("##DIST## threads=%d\n", threads_per_chain))

  if (is.null(exe_dir))   # per-machine subdir so co-located profiles never share/race
    exe_dir <- file.path(dirname(tempdir()), "dist_stan_exe", run_id,
                         sprintf("m%d", machine_id))
  exe_dir <- path.expand(exe_dir)
  dir.create(exe_dir, recursive = TRUE, showWarnings = FALSE)
  mod <- cmdstanr::cmdstan_model(
    stan_path,
    dir             = exe_dir,  # native binary stays local to THIS host (temp by default)
    cpp_options     = cpp_options,
    stanc_options   = stanc_options,
    user_header     = if (is.null(header_path)) NULL else normalizePath(header_path),
    force_recompile = FALSE
  )

  data <- if (grepl("\\.json$", data_path)) data_path else readRDS(data_path)
  if (!is.null(prep_data) && !is.character(data))
    data <- prep_data(data, threads_per_chain)

  # Evaluate a function init with the GLOBAL chain ids, so inits stay distinct.
  if (is.function(init)) init <- lapply(chain_ids, init)

  args <- c(
    # Args this orchestrator owns; everything else is the user's `...`, verbatim.
    list(data = data, chains = chains, chain_ids = chain_ids,
         parallel_chains = parallel_chains, threads_per_chain = threads_per_chain,
         output_dir = output_dir, output_basename = run_id),
    sample_args
  )
  if (!is.null(init)) args$init <- init

  fit <- do.call(mod$sample, args)
  list(machine = machine_id, host = host, chain_ids = chain_ids,
       threads_per_chain = threads_per_chain, csv = fit$output_files(),
       log = log_file)
}

# ---- dist_push ----------------------------------------------------------------

#' Copy code + data to each machine's local working directory (transport="push")
#'
#' @param hosts Character vector of SSH targets (optionally `user@host`).
#' @param files Local file paths (e.g. the `.stan`, `.hpp`, and data file).
#' @param dest Destination directory, interpreted on each host (`~` expands).
#' @return `hosts`, invisibly.
#' @export
dist_push <- function(hosts, files, dest) {
  files <- normalizePath(files, mustWork = TRUE)
  local <- .dist_is_local(hosts)
  for (i in seq_along(hosts)) {
    if (local[i]) {
      d <- path.expand(dest)
      dir.create(d, recursive = TRUE, showWarnings = FALSE)
      file.copy(files, d, overwrite = TRUE)
    } else {
      system2("ssh", c(hosts[i], shQuote(sprintf("mkdir -p %s", dest))))
      st <- system2("rsync", c("-az", shQuote(files),
                               sprintf("%s:%s/", hosts[i], dest)))
      if (st != 0L) stop(sprintf("rsync to %s failed (status %d)", hosts[i], st))
    }
  }
  invisible(hosts)
}

# ---- dist_fit (non-blocking) --------------------------------------------------

#' Launch a distributed fit (non-blocking)
#'
#' One `mirai` daemon per host (deterministic placement); each runs a single
#' cmdstanr `$sample()` with that host's `chains` / `threads_per_chain`, building
#' its own native binary in `exe_dir`. Returns immediately with a handle you
#' watch with [dist_progress()].
#'
#' @param stan_file,data,user_header Paths relative to `work_dir` (or absolute).
#'   `data` must be a path to an `.rds`/`.json` file (in-memory is handled by
#'   [dist_sample()]).
#' @param hosts Character vector of SSH targets (optionally `user@host`), in the
#'   order the per-machine vectors below follow.
#' @param chains,threads_per_chain,parallel_chains Per-machine cmdstanr settings:
#'   a scalar (applied to every host) or a vector aligned to `hosts`. `chains`
#'   default 1. `threads_per_chain` `NA` => that host's cores / `parallel_chains`.
#'   `parallel_chains` `NULL` => that host's `chains` (run them all at once).
#' @param tunnel Per-machine logical: route that host's daemon over an SSH tunnel.
#' @param output_dir Common directory (same path on every host) for CSVs + logs.
#' @param work_dir Directory holding source + data, at this path on every host.
#' @param exe_dir Where each host writes its binary. `NULL` (default) => per-host
#'   temp dir erased after the draws are written; a path => persistent cache.
#' @param init,prep_data Optional. `init` as in cmdstanr (a function is evaluated
#'   with the GLOBAL chain id). `prep_data(data, threads)` returns the data list
#'   for a host. Both must be self-contained (mirai does not export globals).
#' @param output_basename `NULL` (default) => cmdstanr's `<model>-<timestamp>`,
#'   giving `<model>-<stamp>-<chain>.csv`. A string names the run.
#' @param cpp_options,stanc_options,cmdstan_path Compile settings passed to
#'   [cmdstanr::cmdstan_model()] on each host. `cpp_options` defaults to
#'   `stan_threads = TRUE` (required) plus `-framework Accelerate` (macOS);
#'   `stanc_options` defaults to `allow-undefined` iff a `user_header` is given;
#'   `cmdstan_path` defaults to this machine's, assumed identical on every host.
#' @param url Override the controller URL daemons dial back to (e.g. a
#'   10GbE/Thunderbolt address). Default `mirai::host_url()`, or a loopback URL
#'   when a host uses `tunnel = TRUE`.
#' @param transport,gather_dir,hostdir Normally set by [dist_sample()] (they
#'   describe the "copy" transport: where draws are gathered on the controller
#'   and the per-host temp dir). Leave at defaults when calling `dist_fit()`
#'   directly against a shared filesystem.
#' @param ... Any other cmdstanr `$sample()` arg (`iter_warmup`, `iter_sampling`,
#'   `seed`, `refresh`, `adapt_delta`, ...), forwarded verbatim; a value of
#'   length == `length(hosts)` is split per machine, otherwise applied to all.
#'   `chains`/`chain_ids`/`parallel_chains`/`threads_per_chain`/`data`/
#'   `output_dir`/`output_basename` are managed and cannot be passed here.
#' @return A handle of class "dist_fit" for [dist_progress()].
#' @export
dist_fit <- function(stan_file, data, hosts, chains = 1,
                     threads_per_chain = NA, parallel_chains = NULL,
                     tunnel = FALSE, output_dir,
                     work_dir = getwd(), exe_dir = NULL,
                     user_header = NULL, init = NULL, prep_data = NULL,
                     cpp_options = list(stan_threads = TRUE,
                                        LDFLAGS_OS = "-framework Accelerate"),
                     stanc_options = NULL,
                     cmdstan_path = cmdstanr::cmdstan_path(),
                     output_basename = NULL, url = NULL,
                     transport = "mount", gather_dir = NULL, hostdir = NULL, ...) {
  stopifnot(is.character(hosts), length(hosts) >= 1L, is.character(data))
  n <- length(hosts)
  if (is.null(output_basename))
    output_basename <- paste0(tools::file_path_sans_ext(basename(stan_file)),
                              "-", format(Sys.time(), "%Y%m%d%H%M"))
  run_id <- output_basename
  if (is.null(stanc_options))
    stanc_options <- if (is.null(user_header)) list() else list("allow-undefined" = TRUE)

  # Resolve per-machine vectors and global chain-id blocks.
  local   <- .dist_is_local(hosts)
  chains  <- as.integer(.dist_recycle(chains, n, "chains"))
  tpc     <- .dist_recycle(threads_per_chain, n, "threads_per_chain")
  pc      <- if (is.null(parallel_chains)) as.list(chains)
             else as.list(.dist_recycle(parallel_chains, n, "parallel_chains"))
  tunnel  <- .dist_recycle(tunnel, n, "tunnel")
  starts  <- cumsum(c(0L, chains))[seq_len(n)]
  blocks  <- lapply(seq_len(n), function(i) (starts[i] + 1L):(starts[i] + chains[i]))

  # Pass-through sampler args; drop any we manage.
  shared <- list(...)
  owned  <- c("data", "chains", "chain_ids", "parallel_chains",
              "threads_per_chain", "output_dir", "output_basename")
  clash  <- intersect(names(shared), owned)
  if (length(clash)) {
    warning("these args are managed by dist_fit and will be ignored: ",
            paste(clash, collapse = ", "))
    shared[clash] <- NULL
  }

  task <- .dist_machine_task
  environment(task) <- baseenv()

  m <- vector("list", n)
  for (i in seq_len(n)) {
    # tunnel => bind a loopback url; the daemon reaches it via the SSH reverse
    # tunnel, so no routable controller / Tailscale is needed.
    url_i <- if (isTRUE(tunnel[i])) local_url(tcp = TRUE)
             else if (is.null(url)) host_url() else url
    daemons(url = url_i, dispatcher = TRUE, .compute = hosts[i])
    if (local[i]) {
      launch_local(1L, .compute = hosts[i])
    } else {
      launch_remote(1L, remote = ssh_config(paste0("ssh://", hosts[i]),
                                            tunnel = isTRUE(tunnel[i])),
                    .compute = hosts[i])
    }
    sample_args_i <- lapply(shared, .dist_pick, i = i, n = n)
    m[[i]] <- mirai(
      .task(machine_id = machine_id, host = host, chains = chains,
            chain_ids = chain_ids, parallel_chains = parallel_chains,
            threads_per_chain = threads_per_chain, work_dir = work_dir,
            exe_dir = exe_dir, stan_path = stan_path, data_path = data_path,
            header_path = header_path, cpp_options = cpp_options,
            stanc_options = stanc_options, cmdstan_path = cmdstan_path,
            output_dir = output_dir, run_id = run_id, init = init,
            prep_data = prep_data, sample_args = sample_args),
      .args = list(
        .task = task, machine_id = i, host = hosts[i], chains = chains[i],
        chain_ids = blocks[[i]], parallel_chains = pc[[i]],
        threads_per_chain = tpc[i], work_dir = work_dir, exe_dir = exe_dir,
        stan_path = stan_file, data_path = data, header_path = user_header,
        cpp_options = cpp_options, stanc_options = stanc_options,
        cmdstan_path = cmdstan_path, output_dir = output_dir, run_id = run_id,
        init = init, prep_data = prep_data, sample_args = sample_args_i),
      .compute = hosts[i]
    )
  }

  machines <- data.frame(
    machine = seq_len(n), host = hosts, chains = chains,
    chain_ids = vapply(blocks, paste, "", collapse = ","),
    local = local,
    log = file.path(output_dir, ".progress",
                    sprintf("%s-machine%d.log", run_id, seq_len(n))),
    stringsAsFactors = FALSE)

  structure(
    list(mirai = m, machines = machines, blocks = blocks, hosts = hosts,
         model = tools::file_path_sans_ext(basename(stan_file)),
         output_dir = output_dir, run_id = run_id, ephemeral = is.null(exe_dir),
         total_chains = sum(chains), transport = transport, hostdir = hostdir,
         gather_dir = if (is.null(gather_dir)) output_dir else gather_dir),
    class = "dist_fit"
  )
}

# ---- dist_progress (stream native output) ------------------------------------

#' Watch a distributed fit: stream each machine's native cmdstan output
#'
#' Tails every machine's `.progress` log and prints new lines as they arrive --
#' once each, like a local fit (no screen redraw) -- rewriting cmdstan's
#' per-run "Chain k" label to the GLOBAL chain id and prefixing the host. Blocks
#' until all machines finish, then tears the daemons down and erases temp
#' binaries on exit.
#'
#' @param handle Returned by [dist_fit()].
#' @param interval Seconds between log polls (default 0.5).
#' @param teardown Stop daemons + clean temp binaries when done (default TRUE).
#' @return A data.frame with one row per chain (`chain`, `host`, `csv`), ready
#'   for `summarize_gc_draws*` / `as_cmdstan_fit`.
#' @export
dist_progress <- function(handle, interval = 0.5, teardown = TRUE) {
  stopifnot(inherits(handle, "dist_fit"))
  mc     <- handle$machines
  blocks <- handle$blocks
  hlab   <- vapply(mc$host, function(h) sub("^[^@]*@", "", sub("\\..*$", "", h)), "")
  seen   <- integer(nrow(mc))   # complete log lines already streamed, per machine
  hw     <- max(nchar(hlab))                 # pad hostnames so "chain" aligns inside [ ]
  cw     <- max(nchar(mc$chain_ids))         # pad the chain-id list in the ready line
  pwidth <- max(vapply(seq_len(nrow(mc)),    # then pad whole prefix so content aligns
                       function(k) max(nchar(sprintf("[%-*s chain %d]",
                                                     hw, hlab[k], blocks[[k]]))), 0L))

  # Read a machine's progress log: a local file (mount, or local host) or over
  # SSH (copy transport on a remote host -- the log lives only on that host).
  read_log <- function(k) {
    if (handle$transport == "copy" && !isTRUE(mc$local[k])) {
      suppressWarnings(system2("ssh", c("-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
        mc$host[k], shQuote(sprintf("cat %s 2>/dev/null", mc$log[k]))),
        stdout = TRUE, stderr = FALSE))
    } else {
      f <- path.expand(mc$log[k])
      if (!file.exists(f)) character()
      else tryCatch(readLines(f, warn = FALSE), error = function(e) character())
    }
  }

  emit_new <- function() {
    for (k in seq_len(nrow(mc))) {
      ln <- read_log(k)
      if (length(ln) <= seen[k]) next
      for (line in ln[(seen[k] + 1L):length(ln)]) {
        if (!nzchar(trimws(line))) next
        dm <- regmatches(line, regexec("^##DIST## threads=([0-9]+)", line))[[1]]
        if (length(dm) == 2L) {                  # per-machine "ready" banner line
          cat(sprintf("  %-*s   chains %-*s   %s threads/chain\n",
                      hw, hlab[k], cw, mc$chain_ids[k], dm[2]))
          next
        }
        # cmdstan prints "Chain k ..." with k = within-run index; map k -> global id
        mm <- regmatches(line, regexec("^Chain ([0-9]+) ?(.*)$", line))[[1]]
        if (length(mm) == 3L) {
          pre <- sprintf("[%-*s chain %d]", hw, hlab[k], blocks[[k]][as.integer(mm[2])])
          cat(sprintf("%-*s %s\n", pwidth, pre, mm[3]))
        } else {
          cat(sprintf("%-*s %s\n", pwidth, sprintf("[%-*s]", hw, hlab[k]), trimws(line)))
        }
      }
      seen[k] <<- length(ln)
    }
  }

  on.exit(if (teardown) for (h in unique(handle$hosts))
            try(daemons(0L, .compute = h), silent = TRUE), add = TRUE)

  cat(sprintf("\n== distributed fit: %s  (%d chains, %d machines) ==\n",
              handle$model, handle$total_chains, nrow(mc)))
  cat(sprintf("   run: %s\n", handle$run_id))
  cat("   compiling per host; each reports below as it becomes ready...\n\n")

  poll <- if (handle$transport == "copy") max(interval, 2) else interval  # ssh polls
  repeat {
    done <- all(vapply(handle$mirai, function(x) !unresolved(x), logical(1)))
    emit_new()
    if (done) { emit_new(); break }   # flush any final lines
    Sys.sleep(poll)
  }

  # Each task has resolved -- to its result, OR to a captured error (compile/
  # runtime exception, or a daemon that died: mirai resolves those to errors too,
  # so we never hang). A machine is OK iff it returned its CSVs.
  res <- lapply(handle$mirai, collect_mirai)
  ok  <- vapply(res, function(r)
    is.list(r) && !is.null(r$csv) && length(r$csv) == length(r$chain_ids), logical(1))

  # The actual cmdstan/compile error went to that host's progress log (we sink
  # it), so report the R error plus the log tail -- the useful part.
  fail_message <- function(k, r) {
    if (inherits(r, "miraiError")) {            # an R / compile error inside the task
      msg <- trimws(paste(as.character(r), collapse = " "))
      ln <- read_log(k); ln <- ln[nzchar(trimws(ln))]
      if (length(ln)) msg <- paste0(msg, "  |  log: ",
                                    paste(utils::tail(ln, 3), collapse = " / "))
      msg
    } else if (inherits(r, "errorValue")) {     # the daemon died / host unreachable
      paste0("worker disconnected -- daemon died or host unreachable (nng code ",
             trimws(as.character(r)), ")")
    } else {
      "no draws returned"
    }
  }

  if (teardown && isTRUE(handle$ephemeral)) {  # erase per-host temp binaries
    for (h in unique(handle$hosts)) {          # skip hosts whose daemon is gone (no hang)
      if (!isTRUE(tryCatch(status(.compute = h)$connections > 0L,
                           error = function(e) FALSE))) next
      cu <- mirai(unlink(file.path(dirname(tempdir()), "dist_stan_exe", run_id),
                         recursive = TRUE, force = TRUE),
                  .args = list(run_id = handle$run_id), .compute = h)
      try(collect_mirai(cu), silent = TRUE)
    }
  }

  # copy transport: pull each OK host's draws into the controller's gather dir
  # (compressed in transit) and rewrite the CSV paths to their local location.
  if (handle$transport == "copy") {
    for (i in which(ok)) {
      r <- res[[i]]
      if (isTRUE(mc$local[i])) {
        file.copy(r$csv, handle$gather_dir, overwrite = TRUE)
      } else {
        for (f in r$csv)
          system2("rsync", c("-az", sprintf("%s:%s", mc$host[i], f),
                             paste0(handle$gather_dir, "/")))
      }
      res[[i]]$csv <- file.path(handle$gather_dir, basename(r$csv))
    }
    if (teardown) for (i in seq_len(nrow(mc))) {   # remove the per-host run dir
      if (isTRUE(mc$local[i])) unlink(path.expand(handle$hostdir), recursive = TRUE)
      else system2("ssh", c("-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                            mc$host[i], shQuote(sprintf("rm -rf %s", handle$hostdir))))
    }
  }

  # One row per chain, with a status/error so survivors come back even if a host
  # failed. OK hosts zip chain_ids<->CSVs; failed hosts get status="failed".
  rows <- list()
  for (i in seq_along(res)) {
    if (ok[i]) {
      rows[[i]] <- data.frame(chain = res[[i]]$chain_ids, host = mc$host[i],
                              status = "ok", csv = res[[i]]$csv,
                              error = NA_character_, stringsAsFactors = FALSE)
    } else {
      rows[[i]] <- data.frame(chain = handle$blocks[[i]], host = mc$host[i],
                              status = "failed", csv = NA_character_,
                              error = fail_message(i, res[[i]]), stringsAsFactors = FALSE)
    }
  }
  out <- do.call(rbind, rows)
  out <- out[order(out$chain), ]

  nok <- sum(out$status == "ok")
  cat(sprintf("\n== %d/%d chains succeeded ==\n", nok, nrow(out)))
  if (nok < nrow(out)) {
    fl <- out[out$status == "failed", ]
    for (i in which(!ok)) cat(sprintf("   FAILED  %s  (chains %s)\n           %s\n",
      sub("^[^@]*@", "", mc$host[i]), paste(handle$blocks[[i]], collapse = ","),
      fl$error[match(handle$blocks[[i]][1], fl$chain)]))
  }
  if (nok > 0L) cat("   CSVs", if (handle$transport == "copy") "gathered in:" else
                    "written under:", handle$gather_dir, "\n")
  out
}

# ---- dist_cluster (reusable config; an R6 object with a $sample() method) -----

# Internal R6 generator. Users never touch it directly -- they build one with
# dist_cluster() and either pass it as dist_sample(cluster=) or call cl$sample().
# Public fields hold the validated, recycled settings; treat them as read-only.
DistCluster <- R6Class(
  "DistCluster",
  cloneable = FALSE,
  public = list(
    hosts = NULL, chains = NULL, threads_per_chain = NULL,
    parallel_chains = NULL, tunnel = NULL, transport = NULL,
    url = NULL, work_dir = NULL, exe_dir = NULL,

    initialize = function(hosts, chains = NA, threads_per_chain = NA,
                          parallel_chains = NULL, tunnel = FALSE,
                          transport = c("mount", "copy"),
                          url = NULL, work_dir = NULL, exe_dir = NULL) {
      stopifnot(is.character(hosts), length(hosts) >= 1L)
      transport <- match.arg(transport)
      n <- length(hosts)
      rec <- function(x, nm) {
        if (length(x) == 1L) return(rep(x, n))
        if (length(x) == n)  return(x)
        stop(sprintf("`%s` must be length 1 or %d (one per host)", nm, n), call. = FALSE)
      }
      if (length(chains) == 1L && is.na(chains)) chains <- 1L   # default: one chain per host
      chains <- as.integer(rec(chains, "chains"))
      if (any(is.na(chains) | chains < 1L))
        stop("`chains` must be >= 1 for every host", call. = FALSE)
      self$hosts             <- hosts
      self$chains            <- chains
      self$threads_per_chain <- rec(threads_per_chain, "threads_per_chain")
      self$parallel_chains   <- if (is.null(parallel_chains)) NULL
                                else rec(parallel_chains, "parallel_chains")
      self$tunnel            <- rec(as.logical(tunnel), "tunnel")
      self$transport         <- transport
      self$url               <- url
      self$work_dir          <- work_dir
      self$exe_dir           <- exe_dir
      invisible(self)
    },

    # Fit a model on this cluster -- dist_sample() with cluster = self. Every
    # argument (stan_file, data, output_dir, user_header, sampler args, ...)
    # passes straight through; mirrors cmdstanr's mod$sample().
    sample = function(stan_file, data, output_dir, ...) {
      dist_sample(stan_file = stan_file, data = data, cluster = self,
                  output_dir = output_dir, ...)
    },

    print = function(...) {
      cat(sprintf("<DistCluster> %d host%s, %d chain%s, transport=%s\n",
                  length(self$hosts), if (length(self$hosts) == 1L) "" else "s",
                  sum(self$chains), if (sum(self$chains) == 1L) "" else "s",
                  self$transport))
      thr <- ifelse(is.na(self$threads_per_chain), "auto",
                    as.character(self$threads_per_chain))
      blk <- cumsum(self$chains); lo <- c(1L, blk[-length(blk)] + 1L)
      ids <- ifelse(self$chains == 1L, as.character(lo), paste0(lo, "-", blk))
      for (i in seq_along(self$hosts))
        cat(sprintf("  %-28s chains %-7s threads/chain %-4s%s\n",
                    self$hosts[i], ids[i], thr[i],
                    if (isTRUE(self$tunnel[i])) "  tunnel" else ""))
      if (!is.null(self$url)) cat(sprintf("  dial-back url: %s\n", self$url))
      invisible(self)
    }
  )
)

#' Describe a cluster once, reuse it across fits
#'
#' Builds a `DistCluster` (an R6 object) bundling the *where* and *how* of a run
#' -- the hosts, how many chains each runs, the threads per chain, the transport,
#' and the dial-back. Everything is validated and recycled against `hosts` at
#' construction, so a bad shape fails now rather than mid-fit. Use it two ways:
#' functionally, `dist_sample(cluster = cl, ...)`, or as a method,
#' `cl$sample(stan_file, data, output_dir, ...)`, mirroring cmdstanr's
#' `mod$sample()`. The validated settings are read-only public fields
#' (`cl$hosts`, `cl$chains`, ...).
#'
#' @param hosts Character vector of `user@host` (or bare hostnames); the local
#'   controller is auto-detected and run without SSH.
#' @param chains Chains per host: a scalar (recycled to every host) or a vector
#'   aligned to `hosts`. `NA` (the default) means one chain per host.
#' @param threads_per_chain Threads per chain per host: scalar or aligned
#'   vector. `NA` (default) => that host's cores / `parallel_chains`, detected on
#'   the host.
#' @param parallel_chains Chains run at once per host: scalar or aligned vector.
#'   `NULL` (default) => that host's `chains`.
#' @param tunnel Route each host's dial-back through its SSH connection: scalar
#'   or aligned logical. Default FALSE (direct, or via `url`).
#' @param transport `"mount"` (shared filesystem, the default) or `"copy"` (push
#'   inputs out, pull draws back). See [dist_sample()].
#' @param url Address the workers dial back to (e.g. a Tailscale `tcp://IP:0`).
#'   `NULL` => mirai's default. Ignored on hosts where `tunnel` is TRUE.
#' @param work_dir Shared project root for `"mount"`; `NULL` => the working
#'   directory at fit time. Unused for `"copy"`.
#' @param exe_dir Where each host compiles its binary; `NULL` => an ephemeral
#'   per-host temp dir, erased when the run ends.
#' @return A validated `DistCluster` R6 object with a `$sample()` method.
#' @export
dist_cluster <- function(hosts, chains = NA, threads_per_chain = NA,
                         parallel_chains = NULL, tunnel = FALSE,
                         transport = c("mount", "copy"),
                         url = NULL, work_dir = NULL, exe_dir = NULL) {
  DistCluster$new(hosts = hosts, chains = chains,
                  threads_per_chain = threads_per_chain,
                  parallel_chains = parallel_chains, tunnel = tunnel,
                  transport = transport, url = url,
                  work_dir = work_dir, exe_dir = exe_dir)
}

# ---- dist_sample (the single-machine-like entry point) ------------------------

#' Fit a Stan model across several machines, as easily as on one
#'
#' Composes (optionally [dist_push()]) -> [dist_fit()] -> [dist_progress()].
#' A drop-in for `mod$sample()`: add a `cluster` (built once with
#' [dist_cluster()]) -- or, equivalently, the loose `hosts`/`chains`/... args --
#' and every other `$sample()` argument passes straight through. Per-machine
#' settings (`chains`, `threads_per_chain`, `parallel_chains`) may be scalars
#' (recycled) or vectors aligned to `hosts`.
#'
#' @inheritParams dist_fit
#' @param cluster An optional [dist_cluster()] object supplying `hosts`,
#'   `chains`, `threads_per_chain`, `parallel_chains`, `tunnel`, `transport`,
#'   `url`, `work_dir`, and `exe_dir` in one validated bundle. When given it
#'   takes precedence over those loose arguments -- build it once, reuse it
#'   across fits.
#' @param transport How files reach the hosts and draws come back.
#'   `"mount"` (default): `stan_file`/`data`/`output_dir` are paths on a shared
#'   filesystem visible at the same location on every host -- nothing is copied.
#'   `"copy"`: `stan_file`/`data` are paths on the CONTROLLER; they are pushed to
#'   a per-host temp dir, and each host's draws are pulled back into `output_dir`
#'   on the controller. Use `"copy"` when there is no shared mount.
#' @param progress Show the live progress stream and block until done; tear down
#'   on finish (default TRUE).
#' @return If `progress`, a per-chain data.frame (`chain`, `host`, `csv`) -- with
#'   `csv` pointing at the gathered local files under `output_dir` in `"copy"`
#'   mode; otherwise the non-blocking [dist_fit()] handle.
#' @export
dist_sample <- function(stan_file, data, cluster = NULL, output_dir,
                        hosts = NULL, chains = NA,
                        threads_per_chain = NA, parallel_chains = NULL,
                        tunnel = FALSE, transport = c("mount", "copy"),
                        url = NULL, work_dir = NULL, exe_dir = NULL,
                        user_header = NULL, progress = TRUE,
                        output_basename = NULL, ...) {
  transport <- match.arg(transport)
  if (!is.null(cluster)) {                 # cluster supplies the where/how-many/how
    stopifnot(inherits(cluster, "DistCluster"))
    hosts <- cluster$hosts; chains <- cluster$chains
    threads_per_chain <- cluster$threads_per_chain
    parallel_chains <- cluster$parallel_chains
    tunnel <- cluster$tunnel; transport <- cluster$transport
    url <- cluster$url; work_dir <- cluster$work_dir; exe_dir <- cluster$exe_dir
  }
  stopifnot(is.character(hosts), length(hosts) >= 1L)
  if (length(chains) == 1L && is.na(chains)) chains <- 1L   # default: one chain per host
  if (is.null(output_basename))
    output_basename <- paste0(tools::file_path_sans_ext(basename(stan_file)),
                              "-", format(Sys.time(), "%Y%m%d%H%M"))

  cleanup <- NULL   # local staged-data file to remove afterwards (mount, in-memory)
  if (transport == "mount") {
    wd <- if (is.null(work_dir)) getwd() else work_dir
    stan_path <- stan_file; header_path <- user_header
    if (is.character(data)) {
      data_path <- data
    } else {                              # stage in-memory data onto the shared FS
      dir.create(file.path(wd, ".dist_data"), recursive = TRUE, showWarnings = FALSE)
      data_path <- file.path(".dist_data", paste0(output_basename, ".rds"))
      saveRDS(data, file.path(wd, data_path)); cleanup <- file.path(wd, data_path)
    }
    handle <- dist_fit(stan_file = stan_path, data = data_path, hosts = hosts,
                       chains = chains, threads_per_chain = threads_per_chain,
                       parallel_chains = parallel_chains, tunnel = tunnel,
                       output_dir = output_dir, work_dir = wd, exe_dir = exe_dir,
                       user_header = header_path, transport = "mount", url = url,
                       gather_dir = output_dir, output_basename = output_basename, ...)
  } else {                                # copy: no shared FS -- push in, pull back
    hostdir   <- file.path("~/.diststan", output_basename)   # per-host temp (~ per host)
    data_file <- if (is.character(data)) data else {
      f <- file.path(tempdir(), paste0(output_basename, ".rds")); saveRDS(data, f); f
    }
    dist_push(hosts, c(stan_file, data_file,
                       if (!is.null(user_header)) user_header), hostdir)
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    handle <- dist_fit(
      stan_file = basename(stan_file), data = basename(data_file), hosts = hosts,
      chains = chains, threads_per_chain = threads_per_chain,
      parallel_chains = parallel_chains, tunnel = tunnel,
      output_dir = hostdir, work_dir = hostdir, exe_dir = exe_dir,
      user_header = if (is.null(user_header)) NULL else basename(user_header),
      transport = "copy", url = url, gather_dir = output_dir, hostdir = hostdir,
      output_basename = output_basename, ...)
  }

  if (!progress) return(handle)
  out <- dist_progress(handle)
  if (!is.null(cleanup)) {
    unlink(cleanup)
    d <- dirname(cleanup)
    if (dir.exists(d) && length(list.files(d, all.files = TRUE, no.. = TRUE)) == 0L)
      unlink(d, recursive = TRUE)
  }
  out
}

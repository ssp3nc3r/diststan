# End-to-end local fit. Slow (compiles + samples), needs cmdstan, and starts
# mirai daemons -- so it is opt-in: set DISTSTAN_INTEGRATION=true to run.

test_that("two local machines fit and gather distinct chain ids", {
  skip_on_cran()
  skip_if_not(identical(Sys.getenv("DISTSTAN_INTEGRATION"), "true"),
              "set DISTSTAN_INTEGRATION=true to run the live fit test")
  skip_if_not_installed("cmdstanr")
  skip_if(inherits(try(cmdstanr::cmdstan_version(), silent = TRUE), "try-error"),
          "cmdstan not available")

  work <- file.path(tempdir(), "diststan-itest")
  dir.create(work, showWarnings = FALSE)
  file.copy(list.files(system.file("stan", package = "diststan"), full.names = TRUE),
            work, overwrite = TRUE)

  set.seed(1)
  dat <- list(N = 50000L, y = rnorm(50000, 10, 3))

  res <- dist_sample(
    stan_file         = "demo_reduce_sum.stan",
    data              = dat,
    hosts             = c("localhost", "127.0.0.1"),
    chains            = c(2, 1),               # ids 1:2 and 3
    threads_per_chain = 2,
    work_dir          = work,
    output_dir        = file.path(work, "out"),
    user_header       = "demo_funcs.hpp",
    prep_data         = function(d, t) { d$grainsize <- max(1L, d$N %/% (t * 2L)); d },
    iter_warmup = 300, iter_sampling = 300, seed = 1, refresh = 0
  )

  expect_equal(sort(res$chain), 1:3)            # distinct, contiguous ids
  expect_true(all(file.exists(res$csv)))
  fit <- cmdstanr::as_cmdstan_fit(res$csv)
  s <- fit$summary("mu")
  expect_equal(s$mean, 10, tolerance = 0.1)     # recovered truth
})

# Fast, dependency-free unit tests of the internal helpers (no cmdstan needed).

test_that(".dist_recycle recycles scalars and accepts length-n vectors", {
  expect_equal(diststan:::.dist_recycle(2, 3, "x"), c(2, 2, 2))
  expect_equal(diststan:::.dist_recycle(c(2, 1, 1), 3, "x"), c(2, 1, 1))
  expect_error(diststan:::.dist_recycle(c(1, 2), 3, "chains"), "chains")
})

test_that(".dist_pick splits length-n vectors per machine but keeps others whole", {
  # length == n  -> element i
  expect_equal(diststan:::.dist_pick(c(10, 20, 30), 2, 3), 20)
  # scalar       -> same to all
  expect_equal(diststan:::.dist_pick(5, 2, 3), 5)
  # other length -> whole value to all (e.g. a per-chain seed vector)
  expect_equal(diststan:::.dist_pick(c(1, 2), 2, 3), c(1, 2))
  # n == 1 never splits
  expect_equal(diststan:::.dist_pick(c(7), 1, 1), 7)
})

test_that(".dist_is_local detects the controller (incl. user@host and domains)", {
  me <- tolower(sub("\\..*$", "", Sys.info()[["nodename"]]))
  expect_true(diststan:::.dist_is_local("localhost"))
  expect_true(diststan:::.dist_is_local("127.0.0.1"))
  expect_true(diststan:::.dist_is_local(paste0("scottspencer@", me)))
  expect_true(diststan:::.dist_is_local(paste0(me, ".local")))
  expect_false(diststan:::.dist_is_local("user@some-other-host"))
  # vectorized
  expect_equal(diststan:::.dist_is_local(c("localhost", "user@some-other-host")),
               c(TRUE, FALSE))
})

test_that("dist_cluster validates, recycles, and defaults chains to one per host", {
  h <- c("me@a", "me@b", "me@c")

  # chains = NA (default) -> one chain per host
  cl <- dist_cluster(hosts = h)
  expect_s3_class(cl, "DistCluster")            # R6 object
  expect_true(is.function(cl$sample))           # OO interface: cl$sample(...)
  expect_equal(cl$chains, c(1L, 1L, 1L))
  expect_equal(sum(cl$chains), 3L)

  # scalars recycle to every host
  cl2 <- dist_cluster(hosts = h, chains = 2, tunnel = TRUE)
  expect_equal(cl2$chains, c(2L, 2L, 2L))
  expect_equal(cl2$tunnel, c(TRUE, TRUE, TRUE))

  # aligned vectors pass through; transport/url carried
  cl3 <- dist_cluster(hosts = h, chains = c(2, 1, 1),
                      threads_per_chain = c(12, NA, 16),
                      transport = "copy", url = "tcp://1.2.3.4:0")
  expect_equal(cl3$chains, c(2L, 1L, 1L))
  expect_equal(cl3$transport, "copy")
  expect_equal(cl3$url, "tcp://1.2.3.4:0")

  # misaligned length and bad chain counts error at construction
  expect_error(dist_cluster(hosts = h, chains = c(2, 1)), "length 1 or 3")
  expect_error(dist_cluster(hosts = h, chains = c(2, 1, 0)), ">= 1")
  expect_error(dist_cluster(hosts = h, transport = "nope"))
})

test_that("global chain-id blocks are contiguous and distinct", {
  chains <- c(2L, 1L, 1L)
  n <- length(chains)
  starts <- cumsum(c(0L, chains))[seq_len(n)]
  blocks <- lapply(seq_len(n), function(i) (starts[i] + 1L):(starts[i] + chains[i]))
  expect_equal(blocks, list(1:2, 3L, 4L))
  expect_equal(sort(unlist(blocks)), 1:sum(chains))
})

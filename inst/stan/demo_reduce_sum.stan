// Toy model for the distributed-fitting demo. Deliberately exercises the same
// compile path as the real models:
//   * a custom C++ function (`scale_shift`) DECLARED here, DEFINED in
//     demo_funcs.hpp -> needs stanc `allow-undefined` + a user_header
//   * reduce_sum(...) with a data-supplied `grainsize` -> needs stan_threads
//   * -framework Accelerate is linked via cpp_options (not used directly here)
//
// It just estimates the mean/sd of N normals; the point is the machinery.
functions {
  // Declared only -- defined in demo_funcs.hpp (custom C++ via user_header).
  real scale_shift(real x, real a, real b);

  // reduce_sum partial sum: log-likelihood over a slice of y.
  real partial_normal(array[] real y_slice, int start, int end,
                      real mu, real sigma) {
    return normal_lpdf(y_slice | mu, sigma);
  }
}
data {
  int<lower=0> N;
  array[N] real y;
  int<lower=1> grainsize;
}
parameters {
  real mu_raw;
  real<lower=0> sigma;
}
transformed parameters {
  // route a parameter through the custom C++ function (so autodiff must work):
  // mu = 2 * mu_raw + 10
  real mu = scale_shift(mu_raw, 2.0, 10.0);
}
model {
  mu_raw ~ std_normal();
  sigma ~ exponential(1);
  target += reduce_sum(partial_normal, y, grainsize, mu, sigma);
}

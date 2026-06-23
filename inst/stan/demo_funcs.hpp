// Custom C++ definition for the function DECLARED in demo_reduce_sum.stan:
//
//     real scale_shift(real x, real a, real b);
//
// Supplied to cmdstanr via `user_header = "models/demo_funcs.hpp"` together with
// `stanc_options = list("allow-undefined" = TRUE)`. Templated on the scalar
// types so Stan can autodiff through it (T may be double or stan::math::var).
#include <ostream>

template <typename T0__, typename T1__, typename T2__,
          stan::require_all_t<stan::is_stan_scalar<T0__>,
                              stan::is_stan_scalar<T1__>,
                              stan::is_stan_scalar<T2__>>* = nullptr>
stan::promote_args_t<T0__, T1__, T2__>
scale_shift(const T0__& x, const T1__& a, const T2__& b, std::ostream* pstream__) {
  return a * x + b;
}

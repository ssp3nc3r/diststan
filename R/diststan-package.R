#' @keywords internal
"_PACKAGE"

#' @importFrom mirai daemons host_url local_url ssh_config launch_local launch_remote
#' @importFrom mirai mirai collect_mirai unresolved status
#' @importFrom R6 R6Class
#' @importFrom tools file_path_sans_ext
#' @importFrom parallel detectCores
#' @importFrom utils tail
NULL

# These names appear only inside unevaluated `mirai({...})` expressions, bound on
# the daemon via `.args`; declare them so R CMD check's static analysis is quiet.
utils::globalVariables(c(
  ".task", "machine_id", "host", "chains", "chain_ids", "parallel_chains",
  "threads_per_chain", "work_dir", "exe_dir", "stan_path", "data_path",
  "header_path", "cpp_options", "stanc_options", "cmdstan_path", "output_dir",
  "run_id", "init", "prep_data", "sample_args"
))

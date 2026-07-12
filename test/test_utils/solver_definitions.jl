# Solvers
using Ipopt
using SCS
using HiGHS

ipopt_optimizer =
    JuMP.optimizer_with_attributes(Ipopt.Optimizer, "tol" => 1e-6, "print_level" => 0)
fast_ipopt_optimizer = JuMP.optimizer_with_attributes(
    Ipopt.Optimizer,
    "print_level" => 0,
    "max_cpu_time" => 5.0,
)
# use default print_level = 5 # set to 0 to disable
scs_solver = JuMP.optimizer_with_attributes(
    SCS.Optimizer,
    "max_iters" => 100000,
    "eps_infeas" => 1e-4,
    "verbose" => 0,
)

HiGHS_optimizer = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer,
    "time_limit" => 100.0,
    "random_seed" => 12345,
    "log_to_console" => false,
)

HiGHS_optimizer_small_gap = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer,
    "time_limit" => 100.0,
    "random_seed" => 12345,
    "mip_rel_gap" => 0.001,
    "log_to_console" => false,
)

# Pinned to a single thread so branch-and-bound search order (and therefore how much
# of the 100s wall-clock budget is actually available before the time limit hits) is
# reproducible under CI's parallel-worker contention, rather than varying with however
# many cores HiGHS's auto thread-detection happens to grab.
HiGHS_optimizer_single_threaded = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer,
    "time_limit" => 100.0,
    "random_seed" => 12345,
    "threads" => 1,
    "log_to_console" => false,
)

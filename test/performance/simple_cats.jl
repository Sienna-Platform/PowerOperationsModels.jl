using Revise
import Dates
import Gurobi
import MathOptLazy
import PowerNetworkMatrices as PNM
import PowerOperationsModels as POM
import PowerSystems as PSY
import HiGHS
using JuMP
using PowerSystems

function run_problem(optimizer)
    sys = PSY.System(joinpath(@__DIR__, "CATS_Sienna.json"))
    PSY.transform_single_time_series!(sys, Dates.Hour(24), Dates.Hour(24))
    ptdf = POM.VirtualPTDF(
        sys;
        tol = 0.01,
        network_reductions = [PNM.RadialReduction(), PNM.DegreeTwoReduction()],
    )
    network_model = POM.NetworkModel(
        POM.PTDFPowerModel;
        PTDF_matrix = ptdf,
        reduce_radial_branches = true,
        reduce_degree_two_branches = true,
    )
    template = POM.OperationsProblemTemplate(network_model);
    POM.set_device_model!(template, PSY.ThermalStandard, POM.ThermalBasicUnitCommitment)
    POM.set_device_model!(template, PSY.RenewableDispatch, POM.RenewableFullDispatch)
    POM.set_device_model!(template, PSY.HydroDispatch, POM.HydroDispatchRunOfRiver)
    POM.set_device_model!(template, PSY.PowerLoad, POM.StaticPowerLoad)
    POM.set_device_model!(
        template,
        POM.DeviceModel(PSY.Line, POM.StaticBranch; use_slacks = true)
    )
    POM.set_device_model!(template, PSY.Transformer2W, POM.StaticBranch)
    model = POM.DecisionModel(
        template,
        sys;
        name = "CATS_UC2",
        optimizer,
        direct_mode_optimizer = true,
        optimizer_solve_log_print = true,
    );
    POM.build!(model; output_dir = mktempdir(; cleanup = true))
    @time POM.solve!(model)
    return
end

# | Solver | Lazy? | tol=1e-2 | tol=1e-3 |
# | :----- | :---- | -------: | -------: |
# | Gurobi | false |       55 |       57 |
# | Gurobi | true  |       12 |       17 |
# | HiGHS  | false |      175 |      201 |
# | HiGHS  | true  |      173 |      670 |
# | HiGHS  | true* |       94 |      589 182, 201, 650 |

# run_problem(
#     optimizer_with_attributes(
#         Gurobi.Optimizer,
#         MOI.RelativeGapTolerance() => 1e-3,
#     ),
# )
run_problem(
    optimizer_with_attributes(
        () -> MathOptLazy.Optimizer(Gurobi.Optimizer),
        MOI.RelativeGapTolerance() => 1e-2,
    ),
)
# run_problem(
#     optimizer_with_attributes(
#         HiGHS.Optimizer,
#         MOI.RelativeGapTolerance() => 1e-3,
#     ),
# )
# run_problem(
#     optimizer_with_attributes(
#         () -> MathOptLazy.Optimizer(HiGHS.Optimizer),
#         MOI.RelativeGapTolerance() => 1e-3,
#         "random_seed" => 123,
#     ),
# )


# for (k, v) in model.internal.container.constraints
#     if k isa POM.ConstraintKey{POM.FlowRateConstraint,PSY.Line}
#         JuMP.set_attribute.(v, Gurobi.ConstraintAttribute("Lazy"), 1)
#     end
# end
# @time solve = POM.solve!(model)

# function solve_with_loop(model)
#     jmp = POM.IOM.get_optimization_container(model).JuMPmodel
#     constraints_lb, constraints_ub = Dict{Any,Any}(), Dict{Any,Any}()
#     for (k, v) in model.internal.container.constraints
#         if k == POM.ConstraintKey{POM.FlowRateConstraint,PSY.Line}("lb")
#             for vi in v
#                 constraints_lb[vi] = JuMP.constraint_object(vi)
#             end
#         elseif k == POM.ConstraintKey{POM.FlowRateConstraint,PSY.Line}("ub")
#             for vi in v
#                 constraints_ub[vi] = JuMP.constraint_object(vi)
#             end
#         end
#     end
#     JuMP.delete(jmp, [k for k in keys(constraints_lb)])
#     JuMP.delete(jmp, [k for k in keys(constraints_ub)])
#     JuMP.set_silent(jmp)
#     total_solve_time = 0.0
#     while true
#         start_time = time()
#         JuMP.optimize!(jmp)
#         total_solve_time += time() - start_time
#         n_constraints_added = 0
#         for (k, c) in constraints_lb
#             if JuMP.value(c.func) < c.set.lower
#                 JuMP.@constraint(jmp, c.func in c.set)
#                 n_constraints_added += 1
#                 delete!(constraints_lb, k)
#             end
#         end
#         for (k, c) in constraints_ub
#             if JuMP.value(c.func) > c.set.upper
#                 JuMP.@constraint(jmp, c.func in c.set)
#                 n_constraints_added += 1
#                 delete!(constraints_ub, k)
#             end
#         end
#         if n_constraints_added == 0
#             break
#         else
#             @show n_constraints_added
#         end
#     end
#     @show total_solve_time
#     return jmp
# end

# import PProf
# POM.build!(model; output_dir = mktempdir(; cleanup = true))
# PProf.@pprof POM.build!(model; output_dir = mktempdir(; cleanup = true))


# using SnoopCompileCore
# invs = @snoop_invalidations using PowerSystems, PowerOperationsModels
# using SnoopCompile, AbstractTrees
# trees = invalidation_trees(invs)

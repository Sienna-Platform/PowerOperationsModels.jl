using Revise
import Dates
import Gurobi
import MathOptLazy
import PowerNetworkMatrices as PNM
import PowerOperationsModels as POM
import PowerSystems as PSY
using PowerSystems

sys = PSY.System(joinpath(@__DIR__, "CATS_Sienna.json"))
PSY.transform_single_time_series!(sys, Dates.Hour(24), Dates.Hour(24))
ptdf = POM.VirtualPTDF(
    sys;
    tol = 0.01,
    network_reductions = [PNM.RadialReduction(), PNM.DegreeTwoReduction()],
)
network_model = POM.NetworkModel(
    POM.PTDFPowerModel;
    # use_slacks = true,
    # duals = [POM.CopperPlateBalanceConstraint],
    PTDF_matrix = ptdf,
    reduce_radial_branches = true,
    reduce_degree_two_branches = true,
    # power_flow_evaluation = POM.DCPPowerModel(), # ???
)
template = POM.OperationsProblemTemplate(network_model);
POM.set_device_model!(template, PSY.ThermalStandard, POM.ThermalBasicUnitCommitment)
POM.set_device_model!(template, PSY.RenewableDispatch, POM.RenewableFullDispatch)
POM.set_device_model!(template, PSY.HydroDispatch, POM.HydroDispatchRunOfRiver)
POM.set_device_model!(template, PSY.PowerLoad, POM.StaticPowerLoad)
# POM.set_device_model!(template, PSY.Line, POM.StaticBranch)
POM.set_device_model!(
    template,
    POM.DeviceModel(
        PSY.Line,
        POM.StaticBranch;
        use_slacks = true,
    )
)
POM.set_device_model!(template, PSY.Transformer2W, POM.StaticBranch)
import JuMP
import HiGHS
model = POM.DecisionModel(
    template,
    sys;
    name = "CATS_UC2",
    # optimizer = Gurobi.MOI.OptimizerWithAttributes(() -> MathOptLazy.Optimizer(Gurobi.Optimizer)),
    # optimizer = Gurobi.Optimizer,
    optimizer = JuMP.MOI.OptimizerWithAttributes(
        # () -> MathOptLazy.Optimizer(HiGHS.Optimizer),
        HiGHS.Optimizer,
        # "mip_rel_gap" => 1e-3,
    ),
    direct_mode_optimizer = true,
    optimizer_solve_log_print = true,
);
@time POM.build!(model; output_dir = mktempdir(; cleanup = true))

jmp = POM.IOM.get_optimization_container(model).JuMPmodel
@time JuMP.optimize!(jmp)

# Gurobi
#   Default: 540 seconds
#   Gurobi.ConstraintAttribute("Lazy")=1: 80 seconds
#   MathOptLazy: 120 seconds
# HiGHS
#   mip_rel_gap = 1e-3
#     Default: 192 seconds
#     MathOptLazy: 160 seconds

# With: 330 seconds.
# Without: 776.688322 seconds
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

using Revise
import Dates
import Gurobi
import PowerNetworkMatrices as PNM
import PowerOperationsModels as POM
import PowerSystems as PSY
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
        # Options are:  66, 115, 230
        attributes = Dict(
            "filter_function" =>
                x -> (x |> PSY.get_arc |> PSY.get_from |> PSY.get_base_voltage) >= 115.0,
        )
    )
)
POM.set_device_model!(template, PSY.Transformer2W, POM.StaticBranch)
model = POM.DecisionModel(
    template,
    sys;
    name = "CATS_UC2",
    optimizer = Gurobi.Optimizer,
    direct_mode_optimizer = true,
    optimizer_solve_log_print = true,
);
@time POM.build!(model; output_dir = mktempdir(; cleanup = true))
import JuMP
# With: 330 seconds.
# Without: 776.688322 seconds
# for (k, v) in model.internal.container.constraints
#     if k isa POM.ConstraintKey{POM.FlowRateConstraint,PSY.Line}
#         JuMP.set_attribute.(v, Gurobi.ConstraintAttribute("Lazy"), 1)
#     end
# end
@time solve = POM.solve!(model)

# import PProf
# POM.build!(model; output_dir = mktempdir(; cleanup = true))
# PProf.@pprof POM.build!(model; output_dir = mktempdir(; cleanup = true))


# using SnoopCompileCore
# invs = @snoop_invalidations using PowerSystems, PowerOperationsModels
# using SnoopCompile, AbstractTrees
# trees = invalidation_trees(invs)

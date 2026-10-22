# A series capacitor inserted into line "1" of the 5-bus case: line `from -> mid`, then the
# compensator `mid -> to`. Dispatch must match the line with the capacitor folded into it.

const DC_NETWORK_MODELS_FOR_TESTING = [PTDFNetworkModel, DCPNetworkModel]
const STATIC_BRANCH_FORMULATIONS = [StaticBranch, StaticBranchBounds, StaticBranchUnbounded]
const COMPENSATION = -0.2  # capacitor reactance as a fraction of line "1"'s

"""c_sys5 with line "1" split by a `SeriesCompensator` in `mode`, and the compensator."""
function compensated_c_sys5(mode = PSY.SeriesCompensatorControlMode.FIXED; kwargs...)
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(Line, sys, "1")
    from, to = PSY.get_from(PSY.get_arc(line)), PSY.get_to(PSY.get_arc(line))
    mid = PSY.ACBus(;
        number = 100, name = "mid", available = true, bustype = PSY.ACBusTypes.PQ,
        angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(from), input_basis = u"CU",
    )
    PSY.add_component!(sys, mid)
    line_arc, compensator_arc =
        PSY.Arc(; from = from, to = mid), PSY.Arc(; from = mid, to = to)
    PSY.add_component!(sys, line_arc)
    PSY.add_component!(sys, compensator_arc)
    PSY.set_arc!(line, line_arc)
    compensator = PSY.SeriesCompensator(;
        name = "compensator", available = true, active_power_flow = 0.0,
        reactive_power_flow = 0.0, arc = compensator_arc, r = 0.0,
        x = COMPENSATION * PSY.get_x(line, u"SU"), rating = PSY.get_rating(line, u"SU"),
        control_mode = mode, input_basis = u"CU", kwargs...,
    )
    PSY.add_component!(sys, compensator)
    return sys, compensator
end

"""c_sys5 with the capacitor folded into line "1"."""
function folded_c_sys5()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(Line, sys, "1")
    PSY.set_x!(line, (1 + COMPENSATION) * PSY.get_x(line, u"SU") * u"SU")
    return sys
end

function solved_model(sys, network, formulation; compensator_model = nothing)
    template = get_thermal_dispatch_template_network(NetworkModel(network))
    set_device_model!(template, DeviceModel(Line, formulation))
    isnothing(compensator_model) ||
        set_device_model!(template, compensator_model)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

objective(model) = IOM.get_objective_value(IOM.OptimizationProblemOutputs(model))

# StaticBranchBounds holds the flow in a variable; StaticBranch under PTDF in an expression.
compensator_flows(model) = IOM.jump_value.(
    IOM.get_variable(
        IOM.get_optimization_container(model), FlowActivePowerVariable,
        PSY.SeriesCompensator)[
        "compensator",
        :,
    ],
)
compensator_ptdf_flows(model) = IOM.jump_value.(
    IOM.get_expression(
        IOM.get_optimization_container(model), PTDFBranchFlow,
        PSY.SeriesCompensator)[
        "compensator",
        :,
    ],
)

"""The compensator's largest flow magnitude (pu) when only its rating limits it."""
function peak_compensator_flow()
    sys, _ = compensated_c_sys5()
    model = solved_model(sys, PTDFNetworkModel, StaticBranchBounds;
        compensator_model = DeviceModel(PSY.SeriesCompensator, StaticBranchBounds))
    return maximum(abs, compensator_flows(model))
end

@testset "A FIXED SeriesCompensator dispatches as the line with its reactance folded in" begin
    for network in DC_NETWORK_MODELS_FOR_TESTING, formulation in STATIC_BRANCH_FORMULATIONS
        # Under DCP, StaticBranchUnbounded builds no branch flows, so c_sys5 is infeasible
        # with or without the compensator.
        (network, formulation) == (DCPNetworkModel, StaticBranchUnbounded) && continue
        sys, _ = compensated_c_sys5()
        compensated = solved_model(sys, network, formulation;
            compensator_model = DeviceModel(PSY.SeriesCompensator, formulation))
        folded = solved_model(folded_c_sys5(), network, formulation)
        @test objective(compensated) ≈ objective(folded) rtol = 1e-6
    end
end

@testset "A FIXED SeriesCompensator takes flow slacks" begin
    sys, _ = compensated_c_sys5()
    model = solved_model(sys, PTDFNetworkModel, StaticBranchBounds;
        compensator_model = DeviceModel(
            PSY.SeriesCompensator, StaticBranchBounds; use_slacks = true))
    @test !check_variable_bounded(
        model,
        FlowActivePowerSlackUpperBound,
        PSY.SeriesCompensator,
    )
end

@testset "A SeriesCompensator's operational flow limit binds" begin
    limit = 0.9 * peak_compensator_flow()
    sys, _ = compensated_c_sys5(;
        operational_flow_limit = (
            from_to = (min = 0.0, max = limit), to_from = (min = 0.0, max = limit)),
    )
    model = solved_model(sys, PTDFNetworkModel, StaticBranchBounds;
        compensator_model = DeviceModel(PSY.SeriesCompensator, StaticBranchBounds))
    flows = compensator_flows(model)
    @test all(abs.(flows) .<= limit + 1e-6)
    @test maximum(abs, flows) ≈ limit rtol = 1e-6
end

@testset "A SeriesCompensator's rating time series binds" begin
    rating = peak_compensator_flow()
    sys, compensator = compensated_c_sys5()
    PSY.set_rating!(compensator, rating * u"SU")
    factors = vcat([fill(x, 6) for x in [0.99, 0.98, 1.0, 0.95]]...)
    add_branch_rating_time_series_to_system!(
        sys, ["compensator"], 2, factors; initial_date = "2024-01-01")
    model = solved_model(sys, PTDFNetworkModel, StaticBranch;
        compensator_model = DeviceModel(PSY.SeriesCompensator, StaticBranch;
            time_series_names = Dict(BranchRatingTimeSeriesParameter => "branch_rating")))
    flows = compensator_ptdf_flows(model)
    @test all(abs.(flows) .<= rating .* factors[1:length(flows)] .+ 1e-6)
    @test any(isapprox.(abs.(flows), rating .* factors[1:length(flows)]; rtol = 1e-6))
end

@testset "A BYPASSED SeriesCompensator ties its buses" begin
    sys, _ = compensated_c_sys5(PSY.SeriesCompensatorControlMode.BYPASSED)
    bypassed = solved_model(sys, PTDFNetworkModel, StaticBranch;
        compensator_model = DeviceModel(PSY.SeriesCompensator, StaticBranch))
    reference = solved_model(PSB.build_system(PSITestSystems, "c_sys5"),
        PTDFNetworkModel, StaticBranch)
    @test objective(bypassed) ≈ objective(reference) rtol = 1e-6
end

@testset "A controlled SeriesCompensator fails the build" begin
    for mode in (
        PSY.SeriesCompensatorControlMode.DISPATCHABLE,
        PSY.SeriesCompensatorControlMode.ACTIVE_POWER_FLOW,
    )
        sys, _ = compensated_c_sys5(mode;
            reactance_limits = (min = -0.02, max = 0.0),
            active_power_flow_setpoint = 0.5)
        template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
        set_device_model!(template, DeviceModel(PSY.SeriesCompensator, StaticBranch))
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        error = try
            POM.validate_template(model)
            nothing
        catch e
            e
        end
        @test error isa IS.ConflictingInputsError
        @test occursin("compensator ($mode)", sprint(showerror, error))
        @test occursin(
            "Set their control_mode to FIXED or BYPASSED",
            sprint(showerror, error),
        )
    end
end

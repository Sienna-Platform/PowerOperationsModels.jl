@testset "Precompile workload functions run" begin
    sys = POM._build_precompile_system()
    @test !isempty(PSY.get_components(PSY.ThermalMultiStart, sys))
    @test !isempty(PSY.get_components(PSY.ThermalStandard, sys))
    # AreaPTDFNetworkModel template requires every bus assigned to an Area.
    @test length(PSY.get_components(PSY.Area, sys)) == 2
    for bus in PSY.get_components(PSY.ACBus, sys)
        @test !isnothing(PSY.get_area(bus))
    end
    out = mktempdir(; cleanup = true)
    @test POM._run_precompile_workload(sys, out) === nothing
end

# Ramp and duration constraints are silently dropped for non-binding device
# data (IOM _get_ramp_constraint_devices, POM _get_data_for_tdc). If a future
# edit to the micro system un-binds them, the workload would silently stop
# compiling those paths — this testset makes that a loud failure.
@testset "Precompile workload UC model constructs ramp and duration constraints" begin
    sys = POM._build_precompile_system()
    model = POM._build_precompile_model(
        sys,
        POM._precompile_uc_template(),
        mktempdir(; cleanup = true),
    )
    constraints = IOM.get_constraints(model)
    for key in (
        IOM.ConstraintKey(RampConstraint, PSY.ThermalMultiStart, "up"),
        IOM.ConstraintKey(RampConstraint, PSY.ThermalMultiStart, "dn"),
        IOM.ConstraintKey(DurationConstraint, PSY.ThermalMultiStart, "up"),
        IOM.ConstraintKey(DurationConstraint, PSY.ThermalMultiStart, "dn"),
        IOM.ConstraintKey(RampConstraint, PSY.ThermalStandard, "up"),
        IOM.ConstraintKey(RampConstraint, PSY.ThermalStandard, "dn"),
        IOM.ConstraintKey(DurationConstraint, PSY.ThermalStandard, "up"),
        IOM.ConstraintKey(DurationConstraint, PSY.ThermalStandard, "dn"),
        IOM.ConstraintKey(StartTypeConstraint, PSY.ThermalMultiStart),
        IOM.ConstraintKey(
            StartupTimeLimitTemperatureConstraint,
            PSY.ThermalMultiStart,
            "hot",
        ),
        IOM.ConstraintKey(
            StartupTimeLimitTemperatureConstraint,
            PSY.ThermalMultiStart,
            "warm",
        ),
    )
        @test haskey(constraints, key)
    end
end

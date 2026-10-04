# Computing duals for a MILP fixes the discrete variables, re-solves the LP, and restores
# the model, after which JuMP no longer reports primal values. Aux variables are computed
# after the duals, so these tests solve the same MILP with and without duals and require
# the post-solve values to agree.

const _BALANCE_DUALS = [CopperPlateBalanceConstraint]

function _solve_with_and_without_duals(make_template, make_system)
    return map((DataType[], _BALANCE_DUALS)) do duals
        model = DecisionModel(
            make_template(duals),
            make_system();
            optimizer = HiGHS_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              ModelBuildStatus.BUILT
        @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
        return IOM.get_optimization_container(model)
    end
end

function _test_aux_variables_match(expected_keys, make_template, make_system)
    without_duals, with_duals = _solve_with_and_without_duals(make_template, make_system)
    @test IOM.is_milp(with_duals)
    @test !isempty(IOM.get_duals(with_duals))
    aux_with_duals = IOM.get_aux_variables(with_duals)
    aux_without_duals = IOM.get_aux_variables(without_duals)
    for key in expected_keys
        @test haskey(aux_with_duals, key)
    end
    @test keys(aux_with_duals) == keys(aux_without_duals)
    for (key, values) in aux_with_duals
        @test all(isfinite, values.data)
        @test isapprox(values.data, aux_without_duals[key].data; atol = 1e-6)
    end
    return
end

@testset "Thermal aux variables with MILP duals" begin
    make_template =
        duals -> begin
            template = PowerOperationsProblemTemplate(
                NetworkModel(CopperPlateNetworkModel; duals = duals),
            )
            set_device_model!(template, ThermalMultiStart, ThermalMultiStartUnitCommitment)
            set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
            set_device_model!(template, PowerLoad, StaticPowerLoad)
            template
        end
    _test_aux_variables_match(
        [
            AuxVarKey(POM.TimeDurationOn, ThermalMultiStart),
            AuxVarKey(POM.TimeDurationOff, ThermalMultiStart),
            AuxVarKey(POM.PowerOutput, ThermalMultiStart),
            AuxVarKey(POM.TimeDurationOn, ThermalStandard),
            AuxVarKey(POM.TimeDurationOff, ThermalStandard),
        ],
        make_template,
        () -> PSB.build_system(PSITestSystems, "c_sys5_pglib"),
    )
end

@testset "Storage aux variables with MILP duals" begin
    make_template =
        duals -> begin
            template = PowerOperationsProblemTemplate(
                NetworkModel(CopperPlateNetworkModel; duals = duals),
            )
            set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
            set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
            set_device_model!(template, PowerLoad, StaticPowerLoad)
            set_device_model!(template, EnergyReservoirStorage, StorageDispatchWithReserves)
            template
        end
    _test_aux_variables_match(
        [AuxVarKey(POM.StorageEnergyOutput, EnergyReservoirStorage)],
        make_template,
        () -> PSB.build_system(PSITestSystems, "c_sys5_bat"),
    )
end

@testset "Hydro aux variables with MILP duals" begin
    make_system =
        () -> begin
            sys = PSB.build_system(
                PSITestSystems,
                "c_sys5_hy";
                add_single_time_series = true,
                add_reserves = true,
            )
            reserve_up = only(get_components(OnlineReserve{ReserveUp}, sys))
            reserve_down = only(get_components(OnlineReserve{ReserveDown}, sys))
            set_deployed_fraction!(reserve_up, 0.0)
            set_deployed_fraction!(reserve_down, 0.5)
            set_requirement!(reserve_up, 0.01 * PSY.SU)
            set_requirement!(reserve_down, 0.01 * PSY.SU)
            transform_single_time_series!(sys, Hour(4), Hour(4))
            sys
        end
    make_template =
        duals -> begin
            template = PowerOperationsProblemTemplate(
                NetworkModel(CopperPlateNetworkModel; duals = duals),
            )
            set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
            set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
            set_device_model!(template, PowerLoad, StaticPowerLoad)
            set_device_model!(template, RenewableNonDispatch, FixedOutput)
            set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
            set_service_model!(template, OnlineReserve{ReserveUp}, RangeReserve)
            set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)
            template
        end
    _test_aux_variables_match(
        [AuxVarKey(POM.HydroEnergyOutput, HydroDispatch)],
        make_template,
        make_system,
    )
end

@testset "Power flow in the loop with MILP duals" begin
    make_template =
        duals -> begin
            template = PowerOperationsProblemTemplate(
                NetworkModel(
                    PTDFNetworkModel;
                    duals = duals,
                    evaluations = power_flow_evaluations(
                        ACPowerFlow(;
                            distribute_slack_proportional_to_headroom = true,
                            correct_bustypes = true,
                        ),
                    ),
                ),
            )
            set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
            set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
            set_device_model!(template, PowerLoad, StaticPowerLoad)
            set_device_model!(template, Line, StaticBranch)
            set_device_model!(template, TwoWindingTransformer, StaticBranch)
            template
        end
    _test_aux_variables_match(
        [
            AuxVarKey(POM.PowerFlowVoltageAngle, ACBus),
            AuxVarKey(POM.PowerFlowVoltageMagnitude, ACBus),
            AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line),
        ],
        make_template,
        () -> PSB.build_system(PSITestSystems, "c_sys5_uc"),
    )
end

struct CountingEvaluator <: IOM.AbstractEvaluator end

mutable struct CountingEvaluationData <: IOM.AbstractEvaluationData
    n_init::Int
    n_eval::Int
    solved::Bool
end

function IOM.initialize_evaluation_data(::CountingEvaluator, container, sys)
    return CountingEvaluationData(1, 0, false)
end

function IOM.evaluate!(d::CountingEvaluationData, container, sys)
    d.n_eval += 1
    d.solved = true
    return
end

function IOM.reset!(d::CountingEvaluationData)
    d.solved = false
    return
end

# IOM calls every evaluator aux key with every evaluation data.
IOM.calculate_aux_variable_value!(
    ::IOM.OptimizationContainer,
    ::IOM.AuxVarKey{<:POM.PowerFlowAuxVariableType},
    ::PSY.System,
    ::CountingEvaluationData,
) = nothing

function _build_and_solve_external(evaluations)
    system = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel; evaluations = evaluations),
    )
    model = DecisionModel(template, system; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    @test solve!(model) == RunStatus.SUCCESSFULLY_FINALIZED
    return get_optimization_container(model)
end

@testset "Evaluator that is not a power flow" begin
    ec = IOM.EvaluationContainer()
    IOM.add_evaluator!(ec, CountingEvaluator, CountingEvaluator())
    container = _build_and_solve_external(ec)
    data = only(values(get_evaluation_data(get_evaluations(container))))
    @test typeof(data) === CountingEvaluationData
    @test data.n_init == 1
    @test data.n_eval == 1
    @test data.solved
end

@testset "Evaluator that is not a power flow, next to a power flow" begin
    ec = power_flow_evaluations(ACPowerFlow())
    IOM.add_evaluator!(ec, CountingEvaluator, CountingEvaluator())
    container = _build_and_solve_external(ec)
    evaluation_data = get_evaluation_data(get_evaluations(container))
    @test length(evaluation_data) == 2
    @test evaluation_data[CountingEvaluator].n_eval == 1

    reference = _build_and_solve_external(power_flow_evaluations(ACPowerFlow()))
    key = AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, Line)
    @test lookup_value(container, key) == lookup_value(reference, key)
end

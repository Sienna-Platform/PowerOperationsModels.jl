@testset "show(SimulationModels) decision-only does not throw" begin
    sim_models = IOM.SimulationModels(;
        decision_models = [
            DecisionModel(MockOperationProblem; horizon = Hour(24), name = "UC"),
            DecisionModel(
                MockOperationProblem;
                horizon = Hour(12),
                resolution = Minute(5),
                name = "ED",
            ),
        ],
    )
    out = sprint(show, MIME"text/plain"(), sim_models)
    @test occursin("UC", out)
    @test occursin("ED", out)
    @test occursin("Decision Models", out)
end

@testset "show(SimulationModels) with emulator row does not throw" begin
    sim_models = IOM.SimulationModels(;
        decision_models = [
            DecisionModel(MockOperationProblem; horizon = Hour(24), name = "UC"),
        ],
        emulation_model = EmulationModel(MockEmulationProblem; name = "AGC"),
    )
    out = sprint(show, MIME"text/plain"(), sim_models)
    @test occursin("UC", out)
    @test occursin("AGC", out)
end

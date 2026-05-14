@testset "DecisionModel{GenericOpProblem}(sys) throws ArgumentError" begin
    sys = System(100.0)
    @test_throws IS.ArgumentError DecisionModel{POM.GenericOpProblem}(sys)
end

@testset "EmulationModel{GenericEmulationProblem}(sys) throws ArgumentError" begin
    sys = System(100.0)
    @test_throws IS.ArgumentError EmulationModel{POM.GenericEmulationProblem}(sys)
end

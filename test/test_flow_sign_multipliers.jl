@testset "Power-balance multiplier contract" begin
    # `get_variable_multiplier(V, D, F)` returns the coefficient with which a
    # decision variable enters a power-balance expression. The contract below
    # is the *meaning* of that coefficient--add tests based on the intended behavior,
    # not the implementation.

    combos = POM.generate_device_formulation_combinations()

    @testset "All defined multipliers are exactly ±1.0 (no NaN, no fractions)" begin
        # Triples with no defined power-balance throw; defined ones are exactly ±1.0.
        for V in (
            IOM.ActivePowerVariable,
            IOM.ActivePowerInVariable,
            IOM.ActivePowerOutVariable,
        )
            for c in combos
                D, F = c["device_type"], c["formulation"]
                m = try
                    get_variable_multiplier(V, D, F)
                catch
                    continue
                end
                @test m == 1.0 || m == -1.0
                @test !isnan(m)
            end
        end
    end

    @testset "Generators inject: ActivePowerVariable contributes +1 on generator devices" begin
        # Anything in PSY's StaticInjection-generator subtree should produce
        # power, not consume it.
        for c in combos
            D, F = c["device_type"], c["formulation"]
            D <: PSY.Generator || continue
            @test get_variable_multiplier(IOM.ActivePowerVariable, D, F) == +1.0
        end
    end

    @testset "Loads withdraw: ActivePowerVariable contributes -1 on load devices" begin
        # restrict to sensible formulations for loads.
        for c in combos
            D, F = c["device_type"], c["formulation"]
            D <: PSY.ElectricLoad && F <: POM.AbstractLoadFormulation || continue
            @test get_variable_multiplier(IOM.ActivePowerVariable, D, F) == -1.0
        end
    end

    @testset "Bidirectional: In = grid withdrawal, Out = grid injection" begin
        bidirectional = Union{PSY.Storage, PSY.HybridSystem, PSY.Source}
        for c in combos
            D, F = c["device_type"], c["formulation"]
            D <: bidirectional || continue
            @test get_variable_multiplier(IOM.ActivePowerInVariable, D, F) == -1.0
            @test get_variable_multiplier(IOM.ActivePowerOutVariable, D, F) == +1.0
        end
    end

    @testset "Balance slacks: Up closes a shortage (+), Down closes a surplus (-)" begin
        # A slack on a power balance is a synthetic injection/withdrawal that
        # closes an infeasibility. "Up" means "we need more power here" →
        # it must enter the balance with the same sign as a generator.
        @test get_variable_multiplier(
            SystemBalanceSlackUp, PSY.System, CopperPlatePowerModel,
        ) == +1.0
        @test get_variable_multiplier(
            SystemBalanceSlackDown, PSY.System, CopperPlatePowerModel,
        ) == -1.0
        @test get_variable_multiplier(
            InterfaceFlowSlackUp, PSY.TransmissionInterface, CopperPlatePowerModel,
        ) == +1.0
        @test get_variable_multiplier(
            InterfaceFlowSlackDown, PSY.TransmissionInterface, CopperPlatePowerModel,
        ) == -1.0
    end

    # TODO: check that purposefully unsupported combinations error.
    # Certain ones used to return NaN, which seems hazardous. Changed to error, but not
    # sure exactly which should error long-term versus just "unimplemented for now"
end

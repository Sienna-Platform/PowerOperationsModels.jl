@testset "Power-balance multiplier contract" begin
    # `get_variable_multiplier(V, D, F)` returns the coefficient with which a
    # decision variable enters a power-balance expression. The contract below
    # is the *meaning* of that coefficient — independent of which dispatches
    # currently exist. If a test fails, the question to ask is "is the test
    # wrong, or has someone added a dispatch that violates the convention?"
    #
    # Conventions (all from physics, not from the existing implementation):
    #   * Injection into the bus contributes +1.0
    #   * Withdrawal from the bus contributes -1.0
    #   * The "In/Out" naming on a port refers to the *device's* port:
    #       ActivePowerInVariable  = power into device  = grid withdrawal (-1)
    #       ActivePowerOutVariable = power out of device = grid injection (+1)
    #   * A device's nature can override the variable's default sign:
    #       ActivePowerVariable on a generator → +1 (the device injects)
    #       ActivePowerVariable on a load      → -1 (the device withdraws)
    #   * Multipliers are exactly ±1.0 — no fractions, no NaN, no zero.

    combos = POM.generate_device_formulation_combinations()

    @testset "All defined multipliers are exactly ±1.0 (no NaN, no fractions)" begin
        # The contract is: *if* `get_variable_multiplier` returns a number, that
        # number must be exactly ±1.0. Triples with no defined power-balance
        # role are expected to throw (via `_unsupported_multiplier`) — that's
        # the desired behavior vs. silently returning NaN, so we treat throwing
        # as a valid outcome here.
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
        # Restrict to pairs whose formulation actually belongs to the load
        # family. `generate_device_formulation_combinations` enumerates via
        # `methodswith(...; supertypes=true)`, which also matches abstract
        # supertype methods, so it emits pairings like
        # `(PowerLoad, PhaseAngleControl)` that the codebase never instantiates.
        for c in combos
            D, F = c["device_type"], c["formulation"]
            D <: PSY.ElectricLoad && F <: POM.AbstractLoadFormulation || continue
            @test get_variable_multiplier(IOM.ActivePowerVariable, D, F) == -1.0
        end
    end

    @testset "Port semantics: In = grid withdrawal, Out = grid injection" begin
        # Only devices with two grid-side ports actually use In/Out variables.
        # For everything else the call returns the trait default and the test
        # would be vacuous (or worse, exercise nonsense pairings emitted by
        # `generate_device_formulation_combinations`).
        port_having = Union{PSY.Storage, PSY.HybridSystem, PSY.TwoTerminalHVDC}
        for c in combos
            D, F = c["device_type"], c["formulation"]
            D <: port_having || continue
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

    # TODO: purposefully unsupported combinations. Certain ones used to return NaN,
    # which seems hazardous. Changed to error, but 
    # The new implementation hard-errors (via `_unsupported_multiplier`) on
    # combinations that have no defined power-balance role, instead of silently
    # returning NaN. We want a test that pins this contract — "no multiplier
    # defined → throw, never NaN" — but choosing *which* triples count as
    # semantically meaningless is itself a design decision that needs review
    # before being codified. Defer until that conversation happens.
end

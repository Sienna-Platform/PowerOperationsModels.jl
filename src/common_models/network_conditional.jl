"""
Run `f` only when the network models reactive power (`AbstractPowerModel`); on
active-power-only networks (`AbstractActivePowerModel`) it is a no-op. One
compile-time switch for reactive variables/expressions/constraints regardless
of their individual `add_*!` signatures.
"""
on_reactive_power(f::F, ::NetworkModel{<:AbstractPowerModel}) where {F} = f()
on_reactive_power(::F, ::NetworkModel{<:AbstractActivePowerModel}) where {F} = nothing

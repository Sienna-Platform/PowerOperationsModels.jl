"""
Market model formulation that clears market components against a single system-wide
settlement balance: one `PSY.System`-keyed [`SettlementBalanceConstraint`](@ref) row per
timestep, separate from the network's physical [`CopperPlateBalanceConstraint`](@ref)/nodal
balance. The physical balance keeps its `StaticPowerLoad` parameters and gains zero-cost
`SystemBalanceSlackUp`/`SystemBalanceSlackDown` while a market model is present, since the
settlement equality — not the physical slack — is the binding accounting identity.
"""
struct SettlementMarket <: IOM.AbstractMarketModel end

"""
Offer direction for a willingness-to-pay instrument whose curve is authored on the
incremental side. It reads the incremental parameters, variables and constraints exactly as
`IOM.IncrementalOffer` does, but enters the minimized objective with a **negative** sign:
the curve is a benefit, not a cost, so the instrument clears up to the quantity where its
marginal bid price meets the cleared price rather than only when it relieves congestion.

A spread bid is the motivating case. PSY stores `spread_bid` on the incremental side only,
so the side is fixed by the data contract while the sign is fixed by the economics, and the
two differ. Because the sign is negative, the delta PWL relaxation is exact only for a
non-increasing bid curve, so the expected curvity is concave (a single-segment curve, the
usual shape for a point-to-point bid, satisfies both).
"""
struct IncrementalBidOffer <: IOM.OfferDirection end

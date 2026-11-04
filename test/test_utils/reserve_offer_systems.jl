# Reserve-offer fixtures shared by the reserve-offer and logical-unit tests.

# Awards are stored per (device type, service type): join every device type's WIDE frame for
# `service_type` (the encoded service type, e.g. "OnlineReserve__ReserveUp").
function _read_awards(res, service_type::String)
    frames = [
        read_variable(res, key; table_format = TableFormat.WIDE) for
        key in list_variable_names(res) if
        startswith(key, "ActivePowerReserveVariable__") &&
        endswith(key, "__" * service_type)
    ]
    return reduce((a, b) -> innerjoin(a, b; on = :DateTime), frames)
end

# Give every contributing thermal device of `reserve` a MarketBidCost with an energy offer and a
# per-device reserve OFFER curve (PiecewiseStepData, NaturalUnit) named after the service.
function add_device_reserve_offers!(
    sys,
    reserve;
    init_times = [DateTime("2024-01-01T00:00:00"), DateTime("2024-01-02T00:00:00")],
    horizon = 24,
    resolution = Hour(1),
)
    contributors =
        [d for d in get_components(ThermalStandard, sys) if reserve in PSY.get_services(d)]
    @assert !isempty(contributors) "reserve has no thermal contributors"
    offer_curve(price) = IS.PiecewiseStepData([0.0, 50.0, 100.0], [price, price * 1.5])
    # device name -> first-segment offer slope ($/MWh, natural units); segment 2 is 1.5x it.
    base_slope = Dict{String, Float64}()
    for (i, g) in enumerate(contributors)
        pmax = PSY.get_max_active_power(g, u"NU")
        # Keep the unit's own marginal energy cost: read the proportional (linear) term of its
        # existing variable cost before overwriting, and use it as the single-block energy offer.
        energy_slope = PSY.get_proportional_term(
            PSY.get_value_curve(PSY.get_variable_operation_cost(get_operation_cost(g))),
        )
        set_operation_cost!(
            g,
            MarketBidCost(;
                minimum_energy_offer = LinearCurve(0.0),
                start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
                shut_down = LinearCurve(0.0),
                incremental_offer_curves = make_market_bid_curve(
                    [0.0, pmax], [energy_slope], 0.0; power_units = IS.NaturalUnit(),
                ),
            ),
        )
        price = 8.0 + 2.0 * i
        base_slope[PSY.get_name(g)] = price
        data = Dict(it => [offer_curve(price) for _ in 1:horizon] for it in init_times)
        ts = Deterministic(PSY.get_name(reserve), data, resolution)
        PSY.set_service_bid!(sys, g, reserve, ts, IS.NaturalUnit())
    end
    return contributors, base_slope
end

const _MKT_INIT_TIMES =
    [DateTime("2024-01-01T00:00:00"), DateTime("2024-01-02T00:00:00")]

_mkt_offer_ts(svc, mw, price) = Deterministic(
    PSY.get_name(svc),
    Dict(
        it => [IS.PiecewiseStepData([0.0, mw], [price]) for _ in 1:24] for
        it in _MKT_INIT_TIMES
    ),
    Hour(1),
)

_mkt_curve(x, y) = make_market_bid_curve(x, y, 0.0; power_units = IS.NaturalUnit())

# `c_sys5_uc` promoted to MarketBidCost with an OfflineReserve ORDC ("NSPIN") and an
# OnlineReserve ("SPIN"). The returned `offunit` is priced out of the energy stack -
# prohibitive slope and startup - so the UC leaves it OFF while its cheap offline offer
# still clears. Shared by the standard-UC and compact-UC offline-capability testsets.
function _offline_ordc_uc_system()
    sys = deepcopy(PSB.build_system(PSITestSystems, "c_sys5_uc"))
    thermals = collect(get_components(ThermalStandard, sys))
    # Make one unit uneconomical for energy so the UC leaves it OFF; its cheap offline
    # offer must clear regardless.
    offunit = first(sort(thermals; by = PSY.get_name))
    # Service bids require an OfferCurveCost: convert every thermal to a MarketBidCost that
    # keeps its energy slope; the off-unit gets a prohibitive slope + startup so the UC
    # never commits it for energy.
    for g in thermals
        pmax_g = PSY.get_max_active_power(g, u"NU")
        slope = if g === offunit
            1.0e4
        else
            PSY.get_proportional_term(
                PSY.get_value_curve(PSY.get_variable_operation_cost(get_operation_cost(g))),
            )
        end
        PSY.set_operation_cost!(
            g,
            MarketBidCost(;
                minimum_energy_offer = LinearCurve(0.0),
                start_up = (
                    hot = g === offunit ? 1.0e5 : 0.0,
                    warm = g === offunit ? 1.0e5 : 0.0,
                    cold = g === offunit ? 1.0e5 : 0.0,
                ),
                shut_down = LinearCurve(0.0),
                incremental_offer_curves = make_market_bid_curve(
                    [0.0, pmax_g], [slope], 0.0; power_units = IS.NaturalUnit(),
                ),
            ),
        )
    end
    nspin = OfflineReserve(;
        name = "NSPIN",
        available = true,
        time_frame = 30.0,
        variable = _mkt_curve([0.0, 100.0, 200.0], [65.0, 11.0]),
    )
    spin = OnlineReserve{ReserveUp}(;
        name = "SPIN", available = true, time_frame = 10.0, requirement = 0.0,
        variable = _mkt_curve([0.0, 50.0], [40.0]),
    )
    add_service!(sys, nspin, PSY.Device[thermals...])
    add_service!(sys, spin, PSY.Device[thermals...])
    for (i, g) in enumerate(thermals)
        price = g === offunit ? 0.01 : 6.0 + i
        PSY.set_service_bid!(
            sys,
            g,
            nspin,
            _mkt_offer_ts(nspin, 80.0, price),
            IS.NaturalUnit(),
        )
        PSY.set_service_bid!(
            sys,
            g,
            spin,
            _mkt_offer_ts(spin, 30.0, price),
            IS.NaturalUnit(),
        )
    end
    return sys, offunit
end

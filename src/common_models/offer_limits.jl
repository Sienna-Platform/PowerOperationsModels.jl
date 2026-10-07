# Opt-in device-model rows over offer data that spans services: linked reserve offer blocks
# are sold once, and energy plus upward reserve awards stay within the energy offer curve's
# top. Built in a final pass after every service model, when every block variable exists.

"""
Device model attribute. When `true`, a device's reserve offer blocks that its
`reserve_offer_links` series links across services are sold once
(`LinkedReserveOfferConstraint`). Off when absent.
"""
const LINKED_RESERVE_OFFERS_KEY = "linked_reserve_offers"

"""
Device model attribute for thermal formulations. When `true`, energy plus upward reserve
awards stay within the top of the device's energy offer curve (`EnergyOfferCapConstraint`).
Off when absent.
"""
const ENERGY_OFFER_CAP_KEY = "energy_offer_cap"

"""
Name of the device series that links reserve offer blocks across services. Int64 values
`[time step, block, service]`: the block's step in that service's offer curve, `0` when it is
not in it; `value_axes = [IS.TimeSeriesAxis("block", 1:n), IS.TimeSeriesAxis("product",
service names)]`. A row with fewer than two nonzero entries adds nothing, so padding is free.
"""
const RESERVE_OFFER_LINKS_TS_NAME = "reserve_offer_links"

_attribute_on(model::DeviceModel, key::String) = get_attribute(model, key) === true

# The rows read offer data once, at build.
function _require_rebuild_model(container::OptimizationContainer, key::String)
    if IOM.get_param_eltype(container) !== Float64
        error(
            "The \"$(key)\" device model attribute reads offer data at build; recurrent " *
            "solves need rebuild_model = true.",
        )
    end
    return
end

"""
Register the empty containers of the opt-in rows before the device model stage: IOM's device
dual hook throws for a listed constraint type that has no container yet.
"""
function add_offer_limit_containers!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    for model in values(get_device_models(template))
        validate_available_devices(model, sys) || continue
        _add_offer_limit_containers!(container, model)
    end
    return
end

function _add_offer_limit_containers!(
    container::OptimizationContainer,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    if _attribute_on(model, LINKED_RESERVE_OFFERS_KEY)
        add_constraints_container!(
            container, LinkedReserveOfferConstraint, D, String[], Int[], Int[];
            sparse = true,
        )
    end
    if _attribute_on(model, ENERGY_OFFER_CAP_KEY)
        add_constraints_container!(
            container, EnergyOfferCapConstraint, D, String[], Int[]; sparse = true,
        )
    end
    return
end

"""
Build the opt-in offer-limit rows of every device model and assign the duals it lists. Runs
after the services model stage, where the per-step reserve offer variables are created.
"""
function add_offer_limit_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    template::PowerOperationsProblemTemplate,
)
    for model in values(get_device_models(template))
        validate_available_devices(model, sys) || continue
        _add_offer_limit_constraints!(container, sys, model)
    end
    return
end

function _add_offer_limit_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D, F},
) where {D <: PSY.Component, F <: AbstractDeviceFormulation}
    if _attribute_on(model, LINKED_RESERVE_OFFERS_KEY)
        _require_rebuild_model(container, LINKED_RESERVE_OFFERS_KEY)
        add_linked_reserve_offer_constraints!(container, sys, model)
        _reassign_dual!(container, sys, LinkedReserveOfferConstraint, model)
    else
        _warn_ignored_offer_links(container, sys, model)
    end
    if _attribute_on(model, ENERGY_OFFER_CAP_KEY)
        _require_rebuild_model(container, ENERGY_OFFER_CAP_KEY)
        add_energy_offer_cap_constraints!(container, sys, model)
        _reassign_dual!(container, sys, EnergyOfferCapConstraint, model)
    end
    return
end

# The device stage built this dual over the empty registered container; rebuild it over
# the rows the pass added.
function _reassign_dual!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::Type{T},
    model::DeviceModel{D, F},
) where {T <: ConstraintType, D <: PSY.Component, F <: AbstractDeviceFormulation}
    T in IOM.get_duals(model) || return
    delete!(IOM.get_duals(container), IOM.ConstraintKey(T, D))
    IOM.assign_dual_variable!(container, T, get_available_components(model, sys), F)
    return
end

# Links on a device whose model leaves the attribute off are ignored: say so once per type.
function _warn_ignored_offer_links(
    container::OptimizationContainer,
    sys::PSY.System,
    model::DeviceModel{D},
) where {D <: PSY.Component}
    has_container_key(container, PiecewiseLinearBlockReserveOffer, D) || return
    for d in get_available_components(model, sys)
        IS.has_time_series(d, IS.Deterministic, RESERVE_OFFER_LINKS_TS_NAME) || continue
        @warn "$(D) devices carry $(RESERVE_OFFER_LINKS_TS_NAME) series (first: " *
              "$(PSY.get_name(d))), ignored without the \"$(LINKED_RESERVE_OFFERS_KEY)\" " *
              "device model attribute."
        return
    end
    return
end

add_linked_reserve_offer_constraints!(
    ::OptimizationContainer, ::PSY.System, ::DeviceModel,
) = nothing

add_energy_offer_cap_constraints!(::OptimizationContainer, ::PSY.System, ::DeviceModel) =
    nothing

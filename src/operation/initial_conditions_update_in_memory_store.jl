
################## ic updates from store for emulation problems simulation #################

"""
    update_initial_conditions!(model, key, source)

Update initial conditions for a specific key from the model store.
Dispatches to the per-IC-type `update_initial_conditions!(ics, store, resolution)` method.
"""
function update_initial_conditions!(
    model::OperationModel,
    key::InitialConditionKey{T, U},
    source,
) where {T <: InitialConditionType, U <: IS.InfrastructureSystemsComponent}
    if get_execution_count(model) < 1
        return
    end
    container = get_optimization_container(model)
    model_resolution = get_resolution(get_store_params(model))
    ini_conditions_vector = get_initial_condition(container, key)
    update_initial_conditions!(ini_conditions_vector, source, model_resolution)
    return
end

# NOTE: The 3-arg method (Vector{<:InitialCondition{T}}, ::EmulationModelStore,
# ::Dates.Millisecond) lives in src/initial_conditions/update_initial_conditions.jl.
# It used to be a stub here when this file lived in IOM; POM provides the
# concrete implementation now.

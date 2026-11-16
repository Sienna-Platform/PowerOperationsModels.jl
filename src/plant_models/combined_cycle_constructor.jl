# One `PlantModel` per `PSY.PowerPlant` attribute type. `construct_plant!` runs once per plant
# model after the services of the same stage, so every device variable it couples exists.

"""
    construct_plant!(container, sys, stage, model::PlantModel, devices_template, network_model)

Build one plant model. Each plant formulation implements it for `ArgumentConstructStage`
(variables) and `ModelConstructStage` (constraints and duals).
"""
function construct_plant! end

function construct_plants!(
    container::OptimizationContainer,
    sys::PSY.System,
    stage::Union{ArgumentConstructStage, ModelConstructStage},
    plants_template::PlantsModelContainer,
    devices_template::DevicesModelContainer,
    network_model::NetworkModel{<:AbstractNetworkModel},
)
    for plant_model in values(plants_template)
        construct_plant!(
            container,
            sys,
            stage,
            plant_model,
            devices_template,
            network_model,
        )
    end
    return
end

function construct_plant!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance},
    devices_template::DevicesModelContainer,
    ::NetworkModel{<:AbstractNetworkModel},
)
    hrsgs = resolve_hrsgs(container, sys, model, devices_template)
    add_heat_allocation_variables!(container, hrsgs)
    return
end

function construct_plant!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance},
    devices_template::DevicesModelContainer,
    ::NetworkModel{<:AbstractNetworkModel},
)
    hrsgs = resolve_hrsgs(container, sys, model, devices_template)
    check_steam_has_ct(container, devices_template, hrsgs)
    add_constraints!(container, HRSGHeatAllocationConstraint, hrsgs, devices_template)
    add_constraints!(container, HRSGHeatDrawConstraint, hrsgs, devices_template)
    add_constraints!(container, CombinedCycleCommitmentConstraint, hrsgs, devices_template)
    add_constraint_dual!(container, sys, model)
    return
end

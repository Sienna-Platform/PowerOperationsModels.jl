"""
    PlantModel(::Type{P}, ::Type{F}; duals, attributes)

Establishes the model for a `PSY.PowerPlant` supplemental attribute type `P` under the plant
formulation `F`. One `PlantModel` covers every attribute of its type in the system. A plant
model couples the devices the attribute groups, so those devices must also carry a
`DeviceModel` in the template.

# Arguments

  - `::Type{P} where P <: PSY.PowerPlant`: the plant attribute type.
  - `::Type{F} where F <: AbstractPlantFormulation`: the formulation.
  - `duals::Vector{DataType}`: constraint types whose duals are written to the outputs.
  - `attributes::Dict{String, Any}`: formulation attributes, merged over the pair's
    `get_default_attributes`.

# Example

```julia
set_plant_model!(template, PlantModel(CombinedCycleBlock, SharedHRSGHeatBalance))
```
"""
mutable struct PlantModel{P <: PSY.PowerPlant, F <: AbstractPlantFormulation}
    duals::Vector{DataType}
    attributes::Dict{String, Any}
    function PlantModel(
        ::Type{P},
        ::Type{F};
        duals = Vector{DataType}(),
        attributes = Dict{String, Any}(),
    ) where {P <: PSY.PowerPlant, F <: AbstractPlantFormulation}
        if isabstracttype(P) || isabstracttype(F)
            throw(
                ArgumentError(
                    "The plant model must contain only concrete types: got $P and $F",
                ),
            )
        end
        attributes_for_model = get_default_attributes(P, F)
        for (k, v) in attributes
            attributes_for_model[k] = v
        end
        return new{P, F}(duals, attributes_for_model)
    end
end

get_component_type(::PlantModel{P, F}) where {P <: PSY.PowerPlant, F} = P
IOM.get_formulation(::PlantModel{P, F}) where {P <: PSY.PowerPlant, F} = F
IOM.get_duals(m::PlantModel) = m.duals
IOM.get_attributes(m::PlantModel) = m.attributes
IOM.get_attribute(m::PlantModel, key::String) = get(m.attributes, key, nothing)

get_default_attributes(
    ::Type{<:PSY.PowerPlant},
    ::Type{<:AbstractPlantFormulation},
) = Dict{String, Any}()

const PlantsModelContainer = Dict{Symbol, PlantModel}

function set_model!(dict::Dict, model::PlantModel{P}) where {P <: PSY.PowerPlant}
    key = nameof(P)
    if haskey(dict, key)
        @warn "Overwriting $(key) existing plant model"
    end
    dict[key] = model
    return
end

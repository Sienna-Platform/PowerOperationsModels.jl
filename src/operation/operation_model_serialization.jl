const _SERIALIZED_MODEL_FILENAME = "model.bin"

struct OptimizerAttributes
    name::String
    version::String
    attributes::Any
end

function OptimizerAttributes(
    model::IOM.OperationModel,
    optimizer::IOM.MOI.OptimizerWithAttributes,
)
    jump_model = IOM.get_jump_model(model)
    name = JuMP.solver_name(jump_model)
    # Note that this uses private field access to MOI.OptimizerWithAttributes because there
    # is no public method available.
    # This could break if MOI changes their implementation.
    try
        version = IOM.MOI.get(JuMP.backend(jump_model), IOM.MOI.SolverVersion())
        return OptimizerAttributes(name, version, optimizer.params)
    catch
        @debug "Solver Version not supported by the solver"
        version = "MOI.SolverVersion not supported"
        return OptimizerAttributes(name, version, optimizer.params)
    end
end

function _get_optimizer_attributes(model::IOM.OperationModel)
    return IOM.get_optimizer(IOM.get_settings(model)).params
end

struct ProblemSerializationWrapper
    template::IOM.AbstractProblemTemplate
    sys::Union{Nothing, String}
    settings::IOM.Settings
    model_type::DataType
    name::String
    optimizer::OptimizerAttributes
end

function serialize_problem(model::IOM.OperationModel; optimizer = nothing)
    # A PowerSystem cannot be serialized in this format because of how it stores
    # time series data. Use its specialized serialization method instead.
    sys = IOM.get_system(model)
    sys_filename =
        joinpath(IOM.get_output_dir(model), IOM.make_system_filename(sys))
    # Skip serialization if the system is already in the folder
    !ispath(sys_filename) && PSY.to_json(sys, sys_filename)

    if optimizer === nothing
        optimizer = IOM.get_optimizer(IOM.get_settings(model))
        @assert optimizer !== nothing "optimizer must be passed if it wasn't saved in Settings"
    end

    obj = ProblemSerializationWrapper(
        model.template,
        sys_filename,
        deepcopy(IOM.get_settings(model)),
        typeof(model),
        string(IOM.get_name(model)),
        OptimizerAttributes(model, optimizer),
    )
    bin_file_name = joinpath(IOM.get_output_dir(model), _SERIALIZED_MODEL_FILENAME)
    Serialization.serialize(bin_file_name, obj)
    @info "Serialized OperationModel to" bin_file_name
end

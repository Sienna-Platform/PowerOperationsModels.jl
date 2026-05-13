function get_deterministic_time_series_type(sys::IS.InfrastructureSystemsContainer)
    time_series_types = get_time_series_counts_by_type(sys)
    existing_types = Set(d["type"] for d in time_series_types)
    if ("Deterministic" in existing_types) &&
       ("DeterministicSingleTimeSeries" in existing_types)
        error(
            "The System contains a combination of forecast data and transformed time series data. Currently this is not supported.",
        )
    end
    if "Deterministic" ∈ existing_types
        return IS.Deterministic
    elseif "DeterministicSingleTimeSeries" ∈ existing_types
        return IS.DeterministicSingleTimeSeries
    else
        error(
            "The System does not contain any forecast data or transformed time series data.",
        )
    end
end

"""
Abstract type for models that use default InfrastructureOptimizationModels formulations. For custom decision problems
    use DecisionProblem as the super type.
"""
abstract type DefaultDecisionProblem <: DecisionProblem end

"""
Generic InfrastructureOptimizationModels Operation Problem Type for unspecified models
"""
struct GenericOpProblem <: DefaultDecisionProblem end

mutable struct DecisionModel{M <: DecisionProblem} <: OperationModel{M}
    name::Symbol
    template::AbstractProblemTemplate
    sys::IS.InfrastructureSystemsContainer
    internal::Union{Nothing, ModelInternal}
    simulation_info::Union{Nothing, SimulationInfo}
    store::DecisionModelStore
    ext::Dict{String, Any}
end

"""
    DecisionModel{M}(
        template::AbstractProblemTemplate,
        sys::IS.InfrastructureSystemsContainer,
        jump_model::Union{Nothing, JuMP.Model}=nothing;
        kwargs...) where {M<:DecisionProblem}

Build the optimization problem of type M with the specific system and template.

# Arguments

  - `::Type{M} where M<:DecisionProblem`: The abstract operation model type
  - `template::AbstractProblemTemplate`: The model reference made up of transmission, devices, branches, and services.
  - `sys::IS.InfrastructureSystemsContainer`: the system created using Power Systems
  - `jump_model::Union{Nothing, JuMP.Model}`: Enables passing a custom JuMP model. Use with care
  - `name = nothing`: name of model, string or symbol; defaults to the type of template converted to a symbol.
  - `optimizer::Union{Nothing,MOI.OptimizerWithAttributes} = nothing` : The optimizer does
    not get serialized. Callers should pass whatever they passed to the original problem.
  - `horizon::Dates.Period = UNSET_HORIZON`: Manually specify the length of the forecast Horizon
  - `resolution::Dates.Period = UNSET_RESOLUTION`: Manually specify the model's resolution
  - `warm_start::Bool = true`: True will use the current operation point in the system to initialize variable values. False initializes all variables to zero. Default is true
  - `check_components::Bool = true`: True to check the components valid fields when building
  - `initialize_model::Bool = true`: Option to decide to initialize the model or not.
  - `initialization_file::String = ""`: This allows to pass pre-existing initialization values to avoid the solution of an optimization problem to find feasible initial conditions.
  - `deserialize_initial_conditions::Bool = false`: Option to deserialize conditions
  - `export_pwl_vars::Bool = false`: True to export all the pwl intermediate variables. It can slow down significantly the build and solve time.
  - `allow_fails::Bool = false`: True to allow the simulation to continue even if the optimization step fails. Use with care.
  - `optimizer_solve_log_print::Bool = false`: Uses JuMP.unset_silent() to print the optimizer's log. By default all solvers are set to MOI.Silent()
  - `detailed_optimizer_stats::Bool = false`: True to save detailed optimizer stats log.
  - `calculate_conflict::Bool = false`: True to use solver to calculate conflicts for infeasible problems. Only specific solvers are able to calculate conflicts.
  - `direct_mode_optimizer::Bool = false`: True to use the solver in direct mode. Creates a [JuMP.direct_model](https://jump.dev/JuMP.jl/dev/reference/models/#JuMP.direct_model).
  - `store_variable_names::Bool = false`: to store variable names in optimization model. Decreases the build times.
  - `rebuild_model::Bool = false`: It will force the rebuild of the underlying JuMP model with each call to update the model. It increases solution times, use only if the model can't be updated in memory.
  - `initial_time::Dates.DateTime = UNSET_INI_TIME`: Initial Time for the model solve.
  - `time_series_cache_size::Int = IS.TIME_SERIES_CACHE_SIZE_BYTES`: Size in bytes to cache for each time array. Default is 1 MiB. Set to 0 to disable.

# Example

```julia
template = ProblemTemplate(CopperPlatePowerModel, devices, branches, services)
OpModel = DecisionModel(MockOperationProblem, template, system)
```
"""
function DecisionModel{M}(
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    settings::Settings,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    name = nothing,
) where {M <: DecisionProblem}
    if name === nothing
        name = nameof(M)
    elseif name isa String
        name = Symbol(name)
    end
    auto_transform_time_series!(sys, settings)
    ts_type = get_deterministic_time_series_type(sys)
    internal = ModelInternal(
        OptimizationContainer(sys, settings, jump_model, ts_type),
    )

    template_ = deepcopy(template)
    finalize_template!(template_, sys)
    model = DecisionModel{M}(
        name,
        template_,
        sys,
        internal,
        SimulationInfo(),
        DecisionModelStore(),
        Dict{String, Any}(),
    )
    validate_time_series!(model)
    return model
end

function DecisionModel{M}(
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    name = nothing,
    optimizer = nothing,
    horizon = UNSET_HORIZON,
    resolution = UNSET_RESOLUTION,
    interval = UNSET_INTERVAL,
    warm_start = true,
    check_components = true,
    initialize_model = true,
    initialization_file = "",
    deserialize_initial_conditions = false,
    export_pwl_vars = false,
    allow_fails = false,
    optimizer_solve_log_print = false,
    detailed_optimizer_stats = false,
    calculate_conflict = false,
    direct_mode_optimizer = false,
    store_variable_names = false,
    rebuild_model = false,
    export_optimization_model = false,
    check_numerical_bounds = true,
    initial_time = UNSET_INI_TIME,
    time_series_cache_size::Int = IS.TIME_SERIES_CACHE_SIZE_BYTES,
) where {M <: DecisionProblem}
    settings = Settings(
        sys;
        horizon = horizon,
        resolution = resolution,
        interval = interval,
        initial_time = initial_time,
        optimizer = optimizer,
        time_series_cache_size = time_series_cache_size,
        warm_start = warm_start,
        check_components = check_components,
        initialize_model = initialize_model,
        initialization_file = initialization_file,
        deserialize_initial_conditions = deserialize_initial_conditions,
        export_pwl_vars = export_pwl_vars,
        allow_fails = allow_fails,
        calculate_conflict = calculate_conflict,
        optimizer_solve_log_print = optimizer_solve_log_print,
        detailed_optimizer_stats = detailed_optimizer_stats,
        direct_mode_optimizer = direct_mode_optimizer,
        check_numerical_bounds = check_numerical_bounds,
        store_variable_names = store_variable_names,
        rebuild_model = rebuild_model,
        export_optimization_model = export_optimization_model,
    )
    return DecisionModel{M}(template, sys, settings, jump_model; name = name)
end

"""
Build the optimization problem of type M with the specific system and template

# Arguments

  - `::Type{M} where M<:DecisionProblem`: The abstract operation model type
  - `template::AbstractProblemTemplate`: The model reference made up of transmission, devices, branches, and services.
  - `sys::IS.InfrastructureSystemsContainer`: the system created using Power Systems
  - `jump_model::Union{Nothing, JuMP.Model}` = nothing: Enables passing a custom JuMP model. Use with care.

# Example

```julia
template = ProblemTemplate(CopperPlatePowerModel, devices, branches, services)
problem = DecisionModel(MyOpProblemType, template, system, optimizer)
```
"""
function DecisionModel(
    ::Type{M},
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
) where {M <: DecisionProblem}
    return DecisionModel{M}(template, sys, jump_model; kwargs...)
end

function DecisionModel(
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
)
    return DecisionModel{GenericOpProblem}(template, sys, jump_model; kwargs...)
end

function DecisionModel{M}(
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
) where {M <: DefaultDecisionProblem}
    IS.ArgumentError(
        "DefaultDecisionProblem subtypes require a template. Use DecisionModel subtyping instead.",
    )
end

# get_problem_type lifted to OperationModel{T} in IOM/operation_model_abstract_types.jl

# Probably could be more efficient by storing the info in the internal
function get_current_time(model::DecisionModel)
    execution_count = get_execution_count(model)
    initial_time = get_initial_time(model)
    interval = get_interval(model)
    return initial_time + interval * execution_count
end

function init_model_store_params!(model::DecisionModel)
    num_executions = get_executions(model)
    horizon = get_horizon(model)
    system = get_system(model)
    settings = get_settings(model)
    model_interval = get_interval(settings)
    if model_interval != UNSET_INTERVAL
        interval = model_interval
    else
        interval = get_forecast_interval(system)
    end
    resolution = get_resolution(model)
    base_power = get_base_power(system)
    sys_uuid = get_system_uuid(system)
    store_params = ModelStoreParams(
        num_executions,
        horizon,
        iszero(interval) ? resolution : interval,
        resolution,
        base_power,
        sys_uuid,
        get_metadata(get_optimization_container(model)),
    )
    set_store_params!(get_internal(model), store_params)
    return
end

function validate_time_series!(model::DecisionModel{<:DefaultDecisionProblem})
    sys = get_system(model)
    settings = get_settings(model)
    available_resolutions = get_time_series_resolutions(sys)

    if get_resolution(settings) == UNSET_RESOLUTION && length(available_resolutions) != 1
        throw(
            IS.ConflictingInputsError(
                "Data contains multiple resolutions, the resolution keyword argument must be added to the Model. Time Series Resolutions: $(available_resolutions)",
            ),
        )
    elseif get_resolution(settings) != UNSET_RESOLUTION && length(available_resolutions) > 1
        if get_resolution(settings) ∉ available_resolutions
            throw(
                IS.ConflictingInputsError(
                    "Resolution $(get_resolution(settings)) is not available in the system data. Time Series Resolutions: $(available_resolutions)",
                ),
            )
        end
    else
        set_resolution!(settings, first(available_resolutions))
    end

    model_interval = get_interval(settings)
    available_intervals = get_forecast_intervals(sys)
    if model_interval == UNSET_INTERVAL && length(available_intervals) > 1
        throw(
            IS.ConflictingInputsError(
                "The system contains multiple forecast intervals $(available_intervals). " *
                "The `interval` keyword argument must be provided to the DecisionModel constructor " *
                "to select which interval to use.",
            ),
        )
    elseif model_interval != UNSET_INTERVAL && !isempty(available_intervals)
        if model_interval ∉ available_intervals
            throw(
                IS.ConflictingInputsError(
                    "Interval $(Dates.canonicalize(model_interval)) is not available in the system data. " *
                    "Available forecast intervals: $(available_intervals)",
                ),
            )
        end
    end
    if get_horizon(settings) == UNSET_HORIZON
        set_horizon!(
            settings,
            get_forecast_horizon(sys; interval = _to_is_interval(model_interval)),
        )
    end

    counts = get_time_series_counts(sys)
    if counts.forecast_count < 1
        error(
            "The system does not contain forecast data. A DecisionModel can't be built.",
        )
    end
    return
end

get_horizon(model::DecisionModel) = get_horizon(get_settings(model))
function build_pre_step!(model::DecisionModel{<:DecisionProblem})
    TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Build pre-step" begin
        validate_template(model)
        if !isempty(model)
            @info "OptimizationProblem status not ModelBuildStatus.EMPTY. Resetting"
            reset!(model)
        end
        @info "Initializing Optimization Container For a DecisionModel"
        init_optimization_container!(
            get_optimization_container(model),
            get_network_model(get_template(model)),
            get_system(model),
        )
        @info "Initializing ModelStoreParams"
        init_model_store_params!(model)
        set_status!(model, ModelBuildStatus.IN_PROGRESS)
    end
    return
end

# Called `build_impl!(model)` in PSI (lived in decision_model.jl).
function build_model!(model::DecisionModel{<:DecisionProblem})
    build_pre_step!(model)
    @info "Instantiating Network Model"
    IOM.instantiate_network_model!(model)
    handle_initial_conditions!(model)
    build_problem!(
        get_optimization_container(model),
        get_template(model),
        get_system(model),
    )
    IOM.serialize_metadata!(get_optimization_container(model), IOM.get_output_dir(model))
    log_values(get_settings(model))
    return
end

"""
Build the Decision Model based on the specified DecisionProblem.

# Arguments

  - `model::DecisionModel{<:DecisionProblem}`: DecisionModel object
  - `output_dir::String`: Output directory for outputs
  - `recorders::Vector{Symbol} = []`: recorder names to register
  - `console_level = Logging.Error`:
  - `file_level = Logging.Info`:
  - `disable_timer_outputs = false` : Enable/Disable timing outputs
  - `store_system_in_results::Bool = true`: If true, stores the system as JSON in the results HDF5 file.
"""
function build!(
    model::DecisionModel{<:DecisionProblem};
    output_dir::String,
    recorders = [],
    console_level = Logging.Error,
    file_level = Logging.Info,
    disable_timer_outputs = false,
    store_system_in_results = true,
)
    mkpath(output_dir)
    IOM.set_output_dir!(model, output_dir)
    IOM.set_console_level!(model, console_level)
    IOM.set_file_level!(model, file_level)
    TimerOutputs.reset_timer!(BUILD_PROBLEMS_TIMER)
    disable_timer_outputs && TimerOutputs.disable_timer!(BUILD_PROBLEMS_TIMER)
    file_mode = "w"
    IOM.add_recorders!(model, recorders)
    IOM.register_recorders!(model, file_mode)
    logger = IS.configure_logging(get_internal(model), IOM.PROBLEM_LOG_FILENAME, file_mode)
    if store_system_in_results
        @warn "store_system_in_results for $(model) is set to true. This will do nothing unless a Simulation is being built."
    end
    try
        Logging.with_logger(logger) do
            try
                TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Problem $(get_name(model))" begin
                    build_model!(model)
                end
                set_status!(model, ModelBuildStatus.BUILT)
                @info "\n$(BUILD_PROBLEMS_TIMER)\n"
            catch e
                set_status!(model, ModelBuildStatus.FAILED)
                bt = catch_backtrace()
                @error "DecisionModel Build Failed" exception = e, bt
            end
        end
    finally
        IOM.unregister_recorders!(model)
        close(logger)
    end
    return IOM.get_status(model)
end

function reset!(model::DecisionModel{<:DefaultDecisionProblem})
    was_built_for_recurrent_solves = built_for_recurrent_solves(model)
    if was_built_for_recurrent_solves
        IOM.set_execution_count!(model, 0)
    end
    sys = get_system(model)
    ts_type = get_deterministic_time_series_type(sys)
    IOM.set_container!(
        get_internal(model),
        OptimizationContainer(
            get_system(model),
            get_settings(model),
            nothing,
            ts_type,
        ),
    )
    get_optimization_container(model).built_for_recurrent_solves =
        was_built_for_recurrent_solves
    internal = get_internal(model)
    IOM.set_initial_conditions_model_container!(internal, nothing)
    IOM.empty_time_series_cache!(model)
    empty!(get_store(model))
    set_status!(model, ModelBuildStatus.EMPTY)
    return
end

"""
Default solve method for models that conform to the requirements of
DecisionModel{<: DecisionProblem}.

This will call `build!` on the model if it is not already built. It will forward all
keyword arguments to that function.

# Arguments

  - `model::OperationModel = model`: operation model
  - `export_problem_outputs::Bool = false`: If true, export OptimizationProblemOutputs DataFrames to CSV files.
  - `console_level = Logging.Error`:
  - `file_level = Logging.Info`:
  - `disable_timer_outputs = false` : Enable/Disable timing outputs
  - `export_optimization_problem::Bool = true`: If true, serialize the model to a file to allow re-execution later.
  - `store_system_in_results::Bool = true`: If true, stores the system as JSON in the results HDF5 file.

# Examples

```julia
outputs = solve!(OpModel)
outputs = solve!(OpModel, export_problem_outputs = true)
```
"""
function solve!(
    model::DecisionModel{<:DecisionProblem};
    export_problem_outputs = false,
    console_level = Logging.Error,
    file_level = Logging.Info,
    disable_timer_outputs = false,
    export_optimization_problem = true,
    store_system_in_results = true,
    kwargs...,
)
    if store_system_in_results
        @warn "store_system_in_results for $(model) is set to true. This will do nothing unless a Simulation is being built."
    end
    build_if_not_already_built!(
        model;
        console_level = console_level,
        file_level = file_level,
        disable_timer_outputs = disable_timer_outputs,
        kwargs...,
    )
    IOM.set_console_level!(model, console_level)
    IOM.set_file_level!(model, file_level)
    TimerOutputs.reset_timer!(RUN_OPERATION_MODEL_TIMER)
    disable_timer_outputs && TimerOutputs.disable_timer!(RUN_OPERATION_MODEL_TIMER)
    file_mode = "a"
    IOM.register_recorders!(model, file_mode)
    logger = IS.configure_logging(
        get_internal(model),
        IOM.PROBLEM_LOG_FILENAME,
        file_mode,
    )
    optimizer = get(kwargs, :optimizer, nothing)
    try
        Logging.with_logger(logger) do
            try
                initialize_storage!(
                    get_store(model),
                    get_optimization_container(model),
                    IOM.get_store_params(model),
                )
                TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Solve" begin
                    _pre_solve_model_checks(model, optimizer)
                    IOM.solve_model!(model)
                    current_time = get_initial_time(model)
                    write_outputs!(get_store(model), model, current_time, current_time)
                    write_optimizer_stats!(
                        get_store(model),
                        get_optimizer_stats(model),
                        current_time,
                    )
                end
                if export_optimization_problem
                    TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Serialize" begin
                        serialize_optimization_model(model)
                    end
                end
                TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Outputs processing" begin
                    outputs = OptimizationProblemOutputs(model)
                    serialize_outputs(outputs, IOM.get_output_dir(model))
                    export_problem_outputs && export_outputs(outputs)
                end
                @info "\n$(RUN_OPERATION_MODEL_TIMER)\n"
            catch e
                @error "Decision Problem solve failed" exception = (e, catch_backtrace())
                set_run_status!(model, RunStatus.FAILED)
            end
        end
    finally
        IOM.unregister_recorders!(model)
        close(logger)
    end

    return get_run_status(model)
end

function handle_initial_conditions!(model::OperationModel)
    TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Model Initialization" begin
        if isempty(get_template(model))
            return
        end
        settings = get_settings(model)
        initialize_model = get_initialize_model(settings)
        deserialize_initial_conditions = get_deserialize_initial_conditions(settings)
        serialized_initial_conditions_file = IOM.get_initial_conditions_file(model)
        custom_init_file = get_initialization_file(settings)

        if !initialize_model && deserialize_initial_conditions
            throw(
                IS.ConflictingInputsError(
                    "!initialize_model && deserialize_initial_conditions",
                ),
            )
        elseif !initialize_model && !isempty(custom_init_file)
            throw(IS.ConflictingInputsError("!initialize_model && initialization_file"))
        end

        if !initialize_model
            @info "Skip build of initial conditions"
            return
        end

        if !isempty(custom_init_file)
            if !isfile(custom_init_file)
                error("initialization_file = $custom_init_file does not exist")
            end
            if abspath(custom_init_file) != abspath(serialized_initial_conditions_file)
                cp(custom_init_file, serialized_initial_conditions_file; force = true)
            end
        end

        if deserialize_initial_conditions && isfile(serialized_initial_conditions_file)
            IOM.set_initial_conditions_data!(
                get_optimization_container(model),
                Serialization.deserialize(serialized_initial_conditions_file),
            )
            @info "Deserialized initial_conditions_data"
        else
            @info "Make Initial Conditions Model"
            build_initial_conditions!(model)
            solve_and_write_initial_conditions!(model)
        end
        IOM.set_initial_conditions_model_container!(
            get_internal(model),
            nothing,
        )
    end
    return
end

function build_if_not_already_built!(model::OperationModel; kwargs...)
    status = IOM.get_status(model)
    if status == ModelBuildStatus.EMPTY
        if !haskey(kwargs, :output_dir)
            error(
                "'output_dir' must be provided as a kwarg if the model build status is $status",
            )
        else
            new_kwargs = Dict(k => v for (k, v) in kwargs if k != :optimizer)
            status = build!(model; new_kwargs...)
        end
    end
    if status != ModelBuildStatus.BUILT
        error("build! of the $(typeof(model)) $(get_name(model)) failed: $status")
    end
    return
end

# Default + custom-problem validate_template dispatches are defined once on
# OperationModel{T} in operation/template_validation.jl.

function _make_device_cache(
    filter_function::Function,
    devices::IS.FlattenIteratorWrapper{T},
    check_components::Bool,
    sys::PSY.System,
) where {T <: PSY.Device}
    device_cache = sizehint!(Vector{T}(), length(devices))
    for device in devices
        if PSY.get_available(device) && filter_function(device)
            check_components && PSY.check_component(sys, device)
            push!(device_cache, device)
        end
    end
    return device_cache
end

function _make_device_cache(
    ::Nothing,
    devices::IS.FlattenIteratorWrapper{T},
    check_components::Bool,
    sys::PSY.System,
) where {T <: PSY.Device}
    device_cache = sizehint!(Vector{T}(), length(devices))
    for device in devices
        if PSY.get_available(device)
            check_components && PSY.check_component(sys, device)
            push!(device_cache, device)
        end
    end
    return device_cache
end

function make_device_cache!(
    model::DeviceModel{T, <:AbstractDeviceFormulation},
    system::PSY.System,
    check_components::Bool,
) where {T <: PSY.Device}
    subsystem = get_subsystem(model)
    !PSY.has_components(system, T) && return false
    devices = PSY.get_components(T, system; subsystem_name = subsystem)
    filt_func = get_attribute(model, "filter_function")
    model.device_cache =
        _make_device_cache(filt_func, devices, check_components, system)
    return
end

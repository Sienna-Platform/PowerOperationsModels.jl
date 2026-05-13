"""
Abstract type for models that use default InfrastructureOptimizationModels formulations. For custom emulation problems
    use EmulationProblem as the super type.
"""
abstract type DefaultEmulationProblem <: EmulationProblem end

"""
Default InfrastructureOptimizationModels Emulation Problem Type for unspecified problems
"""
struct GenericEmulationProblem <: DefaultEmulationProblem end

"""
    EmulationModel{M}(
        template::AbstractProblemTemplate,
        sys::IS.InfrastructureSystemsContainer,
        jump_model::Union{Nothing, JuMP.Model}=nothing;
        kwargs...) where {M<:EmulationProblem}

Build the optimization problem of type M with the specific system and template.

# Arguments

  - `::Type{M} where M<:EmulationProblem`: The abstract Emulation model type
  - `template::AbstractProblemTemplate`: The model reference made up of transmission, devices, branches, and services.
  - `sys::IS.InfrastructureSystemsContainer`: the system created using Power Systems
  - `jump_model::Union{Nothing, JuMP.Model}`: Enables passing a custom JuMP model. Use with care
  - `name = nothing`: name of model, string or symbol; defaults to the type of template converted to a symbol.
  - `optimizer::Union{Nothing,MOI.OptimizerWithAttributes} = nothing` : The optimizer does
    not get serialized. Callers should pass whatever they passed to the original problem.
  - `warm_start::Bool = true`: True will use the current operation point in the system to initialize variable values. False initializes all variables to zero. Default is true
  - `initialize_model::Bool = true`: Option to decide to initialize the model or not.
  - `initialization_file::String = ""`: This allows to pass pre-existing initialization values to avoid the solution of an optimization problem to find feasible initial conditions.
  - `deserialize_initial_conditions::Bool = false`: Option to deserialize conditions
  - `export_pwl_vars::Bool = false`: True to export all the pwl intermediate variables. It can slow down significantly the build and solve time.
  - `allow_fails::Bool = false`: True to allow the simulation to continue even if the optimization step fails. Use with care.
  - `calculate_conflict::Bool = false`: True to use solver to calculate conflicts for infeasible problems. Only specific solvers are able to calculate conflicts.
  - `optimizer_solve_log_print::Bool = false`: Uses JuMP.unset_silent() to print the optimizer's log. By default all solvers are set to MOI.Silent()
  - `detailed_optimizer_stats::Bool = false`: True to save detailed optimizer stats log.
  - `direct_mode_optimizer::Bool = false`: True to use the solver in direct mode. Creates a [JuMP.direct_model](https://jump.dev/JuMP.jl/dev/reference/models/#JuMP.direct_model).
  - `store_variable_names::Bool = false`: True to store variable names in optimization model.
  - `rebuild_model::Bool = false`: It will force the rebuild of the underlying JuMP model with each call to update the model. It increases solution times, use only if the model can't be updated in memory.
  - `initial_time::Dates.DateTime = UNSET_INI_TIME`: Initial Time for the model solve.
  - `time_series_cache_size::Int = IS.TIME_SERIES_CACHE_SIZE_BYTES`: Size in bytes to cache for each time array. Default is 1 MiB. Set to 0 to disable.

# Example

```julia
template = ProblemTemplate(CopperPlatePowerModel, devices, branches, services)
OpModel = EmulationModel(MockEmulationProblem, template, system)
```
"""
mutable struct EmulationModel{M <: EmulationProblem} <: OperationModel{M}
    name::Symbol
    template::AbstractProblemTemplate
    sys::IS.InfrastructureSystemsContainer
    internal::ModelInternal
    simulation_info::SimulationInfo
    store::EmulationModelStore # might be extended to other stores for simulation
    ext::Dict{String, Any}

    function EmulationModel{M}(
        template::AbstractProblemTemplate,
        sys::IS.InfrastructureSystemsContainer,
        settings::Settings,
        jump_model::Union{Nothing, JuMP.Model} = nothing;
        name = nothing,
    ) where {M <: EmulationProblem}
        if name === nothing
            name = nameof(M)
        elseif name isa String
            name = Symbol(name)
        end
        finalize_template!(template, sys)
        internal = ModelInternal(
            OptimizationContainer(sys, settings, jump_model, IS.SingleTimeSeries),
        )
        new{M}(
            name,
            template,
            sys,
            internal,
            SimulationInfo(),
            EmulationModelStore(),
            Dict{String, Any}(),
        )
    end
end

function EmulationModel{M}(
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    resolution = UNSET_RESOLUTION,
    name = nothing,
    optimizer = nothing,
    warm_start = true,
    initialize_model = true,
    initialization_file = "",
    deserialize_initial_conditions = false,
    export_pwl_vars = false,
    allow_fails = false,
    calculate_conflict = false,
    optimizer_solve_log_print = false,
    detailed_optimizer_stats = false,
    direct_mode_optimizer = false,
    check_numerical_bounds = true,
    store_variable_names = false,
    rebuild_model = false,
    initial_time = UNSET_INI_TIME,
    time_series_cache_size::Int = IS.TIME_SERIES_CACHE_SIZE_BYTES,
) where {M <: EmulationProblem}
    settings = Settings(
        sys;
        initial_time = initial_time,
        optimizer = optimizer,
        time_series_cache_size = time_series_cache_size,
        warm_start = warm_start,
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
        horizon = resolution,
        resolution = resolution,
    )
    model = EmulationModel{M}(template, sys, settings, jump_model; name = name)
    validate_time_series!(model)
    return model
end

"""
Build the optimization problem of type M with the specific system and template

# Arguments

  - `::Type{M} where M<:EmulationProblem`: The abstract Emulation model type
  - `template::AbstractProblemTemplate`: The model reference made up of transmission, devices,
    branches, and services.
  - `sys::IS.InfrastructureSystemsContainer`: the system created using Power Systems
  - `jump_model::Union{Nothing, JuMP.Model}`: Enables passing a custom JuMP model. Use with care

# Example

```julia
template = ProblemTemplate(CopperPlatePowerModel, devices, branches, services)
problem = EmulationModel(MyEmProblemType, template, system, optimizer)
```
"""
function EmulationModel(
    ::Type{M},
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
) where {M <: EmulationProblem}
    return EmulationModel{M}(template, sys, jump_model; kwargs...)
end

function EmulationModel(
    template::AbstractProblemTemplate,
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
)
    return EmulationModel{GenericEmulationProblem}(template, sys, jump_model; kwargs...)
end

"""
Builds an empty emulation model. This constructor is used for the implementation of custom
emulation models that do not require a template.

# Arguments

  - `::Type{M} where M<:EmulationProblem`: The abstract operation model type
  - `sys::IS.InfrastructureSystemsContainer`: the system created using Power Systems
  - `jump_model::Union{Nothing, JuMP.Model}` = nothing: Enables passing a custom JuMP model. Use with care.

# Example

```julia
problem = EmulationModel(system, optimizer)
```
"""
function EmulationModel{M}(
    sys::IS.InfrastructureSystemsContainer,
    jump_model::Union{Nothing, JuMP.Model} = nothing;
    kwargs...,
) where {M <: DefaultEmulationProblem}
    throw(
        IS.ArgumentError(
            "DefaultEmulationProblem subtypes require a template. Use EmulationModel subtyping instead.",
        ),
    )
end

# get_problem_type lifted to OperationModel{T} in IOM/operation_model_abstract_types.jl

function validate_time_series!(model::EmulationModel{<:DefaultEmulationProblem})
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

    if get_horizon(settings) == UNSET_HORIZON
        # Emulation Models Only solve one "step" so Horizon and Resolution must match
        set_horizon!(settings, get_resolution(settings))
    end

    counts = get_time_series_counts(sys)
    if counts.static_time_series_count < 1
        error(
            "The system does not contain Static Time Series data. A EmulationModel can't be built.",
        )
    end
    return
end

function get_current_time(model::EmulationModel)
    execution_count = get_execution_count(model)
    initial_time = get_initial_time(model)
    resolution = get_resolution(model)
    return initial_time + resolution * execution_count
end

function init_model_store_params!(model::EmulationModel)
    num_executions = get_executions(model)
    system = get_system(model)
    settings = get_settings(model)
    horizon = interval = resolution = get_resolution(settings)
    base_power = get_base_power(system)
    sys_uuid = get_system_uuid(system)
    set_store_params!(
        get_internal(model),
        ModelStoreParams(
            num_executions,
            horizon,
            interval,
            resolution,
            base_power,
            sys_uuid,
            get_metadata(get_optimization_container(model)),
        ),
    )
    return
end

function update_parameters!(
    model::EmulationModel,
    store::EmulationModelStore{InMemoryDataset},
)
    update_parameters!(model, store.data_container)
    return
end

function update_parameters!(model::EmulationModel, data::DatasetContainer{InMemoryDataset})
    cost_function_unsynch(get_optimization_container(model))
    for key in keys(get_parameters(model))
        update_parameter_values!(model, key, data)
    end
    if !is_synchronized(model)
        update_objective_function!(get_optimization_container(model))
        obj_func = get_objective_expression(get_optimization_container(model))
        set_synchronized_status!(obj_func, true)
    end
    return
end

function update_model!(
    model::EmulationModel,
    source::EmulationModelStore{InMemoryDataset},
    ini_cond_chronology,
)
    TimerOutputs.@timeit RUN_SIMULATION_TIMER "Parameter Updates" begin
        update_parameters!(model, source)
    end
    TimerOutputs.@timeit RUN_SIMULATION_TIMER "Ini Cond Updates" begin
        update_initial_conditions!(model, source, ini_cond_chronology)
    end
    return
end

"""
Standalone update for EmulationModel (non-simulation context).
Updates parameters and initial conditions from the model's own store.
"""
function update_model!(model::EmulationModel)
    source = get_store(model)
    TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Parameter Updates" begin
        update_parameters!(model, source)
    end
    TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Ini Cond Updates" begin
        for key in keys(get_initial_conditions(model))
            update_initial_conditions!(model, key, source)
        end
    end
    return
end

"""
Update parameter function an OperationModel
"""
function update_parameter_values!(
    model::EmulationModel,
    key::ParameterKey{T, U},
    input::DatasetContainer{InMemoryDataset},
) where {T <: ParameterType, U <: IS.InfrastructureSystemsComponent}
    # Enable again for detailed debugging
    # TimerOutputs.@timeit RUN_SIMULATION_TIMER "$T $U Parameter Update" begin
    optimization_container = get_optimization_container(model)
    # FIXME: This parameter update logic belongs in POM or PSI, not IOM.
    # Move this function (and the surrounding update chain) once EmulationModel
    # lifecycle code is fully migrated.
    update_container_parameter_values!(optimization_container, model, key, input)
    parameter_attributes = get_parameter_attributes(optimization_container, key)
    IS.@record :execution ParameterUpdateEvent(
        T,
        U,
        "event", # parameter_attributes,
        get_current_timestamp(model),
        get_name(model),
    )
    #end
    return
end
# FIXME untested. Moved to accommodate a few methods dispatching on EmulationModelStore,
# but not run in the tests and not yet refactored for IOM-POM split.
function build_pre_step!(model::EmulationModel)
    TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Build pre-step" begin
        validate_template(model)
        if !isempty(model)
            @info "EmulationProblem status not ModelBuildStatus.EMPTY. Resetting"
            reset!(model)
        end
        container = get_optimization_container(model)
        container.built_for_recurrent_solves = true

        @info "Initializing Optimization Container For an EmulationModel"
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

# Called `build_impl!(model)` in PSI (lived in emulation_model.jl).
function build_model!(model::EmulationModel{<:EmulationProblem})
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
Implementation of build for any EmulationProblem
  - `store_system_in_results::Bool = true`: If true, stores the system as JSON in the results HDF5 file.
"""
function build!(
    model::EmulationModel{<:EmulationProblem};
    executions = 1,
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
    logger = IS.configure_logging(
        get_internal(model),
        IOM.PROBLEM_LOG_FILENAME,
        file_mode,
    )
    if store_system_in_results
        @warn "store_system_in_results for $(model) is set to true. This will do nothing unless a Simulation is being built."
    end
    try
        Logging.with_logger(logger) do
            try
                IOM.set_executions!(model, executions)
                TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Problem $(get_name(model))" begin
                    build_model!(model)
                end
                set_status!(model, ModelBuildStatus.BUILT)
                @info "\n$(BUILD_PROBLEMS_TIMER)\n"
            catch e
                set_status!(model, ModelBuildStatus.FAILED)
                bt = catch_backtrace()
                @error "EmulationModel Build Failed" exception = e, bt
            end
        end
    finally
        IOM.unregister_recorders!(model)
        close(logger)
    end
    return IOM.get_status(model)
end

function reset!(model::EmulationModel{<:EmulationProblem})
    if built_for_recurrent_solves(model)
        IOM.set_execution_count!(model, 0)
    end
    IOM.set_container!(
        get_internal(model),
        OptimizationContainer(
            get_system(model),
            get_settings(model),
            nothing,
            PSY.SingleTimeSeries,
        ),
    )
    IOM.set_initial_conditions_model_container!(get_internal(model), nothing)
    IOM.empty_time_series_cache!(model)
    empty!(get_store(model))
    set_status!(model, ModelBuildStatus.EMPTY)
    return
end

function _progress_meter_enabled()
    return isa(stderr, Base.TTY) &&
           (get(ENV, "CI", nothing) != "true") &&
           (get(ENV, "RUNNING_SIENNA_TESTS", nothing) != "true")
end

# Called `run_impl!` in PSI (lived in emulation_model.jl).
function execute_emulation!(
    model::EmulationModel;
    optimizer = nothing,
    enable_progress_bar = _progress_meter_enabled(),
    kwargs...,
)
    _pre_solve_model_checks(model, optimizer)
    internal = get_internal(model)
    executions = IOM.get_executions(internal)
    # Temporary check. Needs better way to manage re-runs of the same model
    if internal.execution_count > 0
        error("Call build! again")
    end
    prog_bar = ProgressMeter.Progress(executions; enabled = enable_progress_bar)
    initial_time = get_initial_time(model)
    for execution in 1:executions
        TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Run execution" begin
            # NOTE: PSI's run_impl! calls update_model!(model) here to update parameters
            # and initial conditions between executions. That logic lives in IOM's
            # emulation_model.jl and is invoked by PSI during simulation. Standalone
            # emulation in POM does not update between steps.
            IOM.solve_model!(model)
            current_time = initial_time + (execution - 1) * get_resolution(model)
            write_outputs!(get_store(model), model, execution, current_time)
            write_optimizer_stats!(
                get_store(model),
                get_optimizer_stats(model),
                execution,
            )
            IOM.advance_execution_count!(model)
            ProgressMeter.update!(
                prog_bar,
                IOM.get_execution_count(model);
                showvalues = [(:Execution, execution)],
            )
        end
    end
    return
end

"""
Default run method for problems that conform to the requirements of
EmulationModel{<: EmulationProblem}

This will call `build!` on the model if it is not already built. It will forward all
keyword arguments to that function.

# Arguments

  - `model::EmulationModel = model`: Emulation model
  - `optimizer::MOI.OptimizerWithAttributes`: The optimizer that is used to solve the model
  - `executions::Int`: Number of executions for the emulator run
  - `export_problem_outputs::Bool`: If true, export OptimizationProblemOutputs DataFrames to CSV files.
  - `output_dir::String`: Required if the model is not already built, otherwise ignored
  - `enable_progress_bar::Bool`: Enables/Disable progress bar printing
  - `export_optimization_model::Bool`: If true, serialize the model to a file to allow re-execution later.
  - `store_system_in_results::Bool = true`: If true, stores the system as JSON in the results HDF5 file.

# Examples

```julia
status = run!(model; optimizer = HiGHS.Optimizer, executions = 10)
status = run!(model; output_dir = ./model_output, optimizer = HiGHS.Optimizer, executions = 10)
```
"""
function run!(
    model::EmulationModel{<:EmulationProblem};
    export_problem_outputs = false,
    console_level = Logging.Error,
    file_level = Logging.Info,
    disable_timer_outputs = false,
    export_optimization_model = true,
    enable_progress_bar = _progress_meter_enabled(),
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
    try
        Logging.with_logger(logger) do
            try
                initialize_storage!(
                    get_store(model),
                    get_optimization_container(model),
                    IOM.get_store_params(model),
                )
                TimerOutputs.@timeit RUN_OPERATION_MODEL_TIMER "Run" begin
                    execute_emulation!(
                        model;
                        enable_progress_bar = enable_progress_bar,
                        kwargs...,
                    )
                    set_run_status!(model, RunStatus.SUCCESSFULLY_FINALIZED)
                end
                if export_optimization_model
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
                @error "Emulation Problem Run failed" exception = (e, catch_backtrace())
                set_run_status!(model, RunStatus.FAILED)
            end
        end
    finally
        IOM.unregister_recorders!(model)
        close(logger)
    end
    return get_run_status(model)
end

# handle_initial_conditions! lifted to OperationModel in decision_model.jl
# (identical body for both DecisionModel and EmulationModel).

# Default + custom-problem validate_template dispatches are defined once on
# OperationModel{T} in operation/template_validation.jl.

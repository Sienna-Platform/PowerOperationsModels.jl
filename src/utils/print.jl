function Base.show(io::IO, ::MIME"text/plain", input::OperationsProblemTemplate)
    _show_method(io, input, :auto)
end

function Base.show(io::IO, ::MIME"text/html", input::OperationsProblemTemplate)
    _show_method(io, input, :html; stand_alone = false, table_format = PSY.tf_html_simple)
end

function _show_method(
    io::IO,
    template::OperationsProblemTemplate,
    backend::Symbol;
    kwargs...,
)
    network_model = get_network_model(template)
    table = [
        "Network Model" string(get_network_formulation(network_model))
        "Slacks" get_use_slacks(network_model)
        "PTDF" !isnothing(get_PTDF_matrix(network_model))
        "Duals" isempty(get_duals(network_model)) ? "None" : string.(get_duals(network_model))
        "HVDC Network Model" isnothing(get_hvdc_network_model(network_model)) ? "None" : replace(string(get_hvdc_network_model(network_model)), r"[()]" => "")
    ]

    PrettyTables.pretty_table(
        io,
        table;
        backend = backend,
        show_column_labels = false,
        title = "Network Model",
        alignment = :l,
        kwargs...,
    )

    devices = get_device_models(template)
    println(io)
    header = ["Device Type", "Formulation", "Slacks"]

    table = Matrix{String}(undef, length(devices), length(header))
    for (ix, model) in enumerate(values(devices))
        table[ix, 1] = string(get_component_type(model))
        table[ix, 2] = string(get_formulation(model))
        table[ix, 3] = string(model.use_slacks)
    end

    PrettyTables.pretty_table(
        io,
        table;
        backend = backend,
        column_labels = header,
        title = "Device Models",
        alignment = :l,
    )

    branches = get_branch_models(template)
    if !isempty(branches)
        println(io)
        header = ["Branch Type", "Formulation", "Slacks"]

        table = Matrix{String}(undef, length(branches), length(header))
        for (ix, model) in enumerate(values(branches))
            table[ix, 1] = string(get_component_type(model))
            table[ix, 2] = string(get_formulation(model))
            table[ix, 3] = string(model.use_slacks)
        end

        PrettyTables.pretty_table(
            io,
            table;
            column_labels = header,
            backend = backend,
            title = "Branch Models",
            alignment = :l,
            kwargs...,
        )
    end

    services = get_service_models(template)
    if !isempty(services)
        println(io)
        if isempty(first(keys(services))[1])
            header = ["Service Type", "Formulation", "Slacks", "Aggregated Model"]
        else
            header = ["Name", "Service Type", "Formulation", "Slacks", "Aggregated Model"]
        end

        table = Matrix{String}(undef, length(services), length(header))
        for (ix, (key, model)) in enumerate(services)
            if isempty(key[1])
                table[ix, 1] = string(get_component_type(model))
                table[ix, 2] = string(get_formulation(model))
                table[ix, 3] = string(model.use_slacks)
                table[ix, 4] =
                    string(get(model.attributes, "aggregated_service_model", "false"))
            else
                table[ix, 1] = key[1]
                table[ix, 2] = string(get_component_type(model))
                table[ix, 3] = string(get_formulation(model))
                table[ix, 4] = string(model.use_slacks)
                table[ix, 5] =
                    string(get(model.attributes, "aggregated_service_model", "false"))
            end
        end

        PrettyTables.pretty_table(
            io,
            table;
            column_labels = header,
            backend = backend,
            title = "Service Models",
            alignment = :l,
            kwargs...,
        )
    end
    return
end
function Base.show(io::IO, ::MIME"text/plain", input::OptimizationProblemOutputs)
    _show_method(io, input, :auto)
end

function Base.show(io::IO, ::MIME"text/html", input::OptimizationProblemOutputs)
    # The tf_html_simple format was eliminated from PrettyTables and it was added to PowerSystems
    _show_method(io, input, :html; stand_alone = false, table_format = PSY.tf_html_simple)
end

function _show_method(
    io::IO,
    outputs::OptimizationProblemOutputs,
    backend::Symbol;
    kwargs...,
)
    timestamps = get_timestamps(outputs)

    if backend == :html
        println(io, "<p> Start: $(first(timestamps))</p>")
        println(io, "<p> End: $(last(timestamps))</p>")
        println(
            io,
            "<p> Resolution: $(Dates.Minute(get_resolution(outputs)))</p>",
        )
    else
        println(io, "Start: $(first(timestamps))")
        println(io, "End: $(last(timestamps))")
        println(io, "Resolution: $(Dates.Minute(get_resolution(outputs)))")
    end

    values = Dict{String, Vector{String}}(
        "Variables" => list_variable_names(outputs),
        "Auxiliary variables" => list_aux_variable_names(outputs),
        "Duals" => list_dual_names(outputs),
        "Expressions" => list_expression_names(outputs),
        "Parameters" => list_parameter_names(outputs),
    )

    name = outputs.model_type

    for (k, val) in values
        if !isempty(val)
            println(io)
            PrettyTables.pretty_table(
                io,
                val;
                show_column_labels = false,
                backend = backend,
                title = "$name Problem $k Outputs",
                alignment = :l,
                kwargs...,
            )
        end
    end
end

function Base.show(io::IO, ::MIME"text/plain", bounds::ConstraintBounds)
    println(io, "ConstraintBounds:")
    println(io, "Constraint Coefficient")
    show(io, MIME"text/plain"(), bounds.coefficient)
    println(io, "Constraint RHS")
    show(io, MIME"text/plain"(), bounds.rhs)
end

function Base.show(io::IO, ::MIME"text/plain", bounds::VariableBounds)
    println(io, "VariableBounds:")
    show(io, MIME"text/plain"(), bounds.bounds)
end

function Base.show(io::IO, ::MIME"text/plain", bounds::NumericalBounds)
    println(io, rpad("  Minimum", 20), "Maximum")
    println(io, rpad("  $(bounds.min)", 20), "$(bounds.max)")
end

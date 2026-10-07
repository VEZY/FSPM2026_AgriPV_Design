using Dates
using DataFrames
using PlantSimEngine
using MultiScaleTreeGraph

const AGRIPV_LIGHT_OUTPUT_COLUMNS = (
    Ri_PAR_f=(:archimed_light, :Ri_PAR_f),
    Ri_NIR_f=(:archimed_light, :Ri_NIR_f),
    Ra_PAR_f=(:archimed_light, :Ra_PAR_f),
    Ra_NIR_f=(:archimed_light, :Ra_NIR_f),
    Ra_SW_f=(:archimed_light, :Ra_SW_f),
    aPPFD=(:archimed_light, :aPPFD),
    area=(:archimed_light, :area),
    sky_fraction=(:archimed_light, :sky_fraction),
)

# Monteith publishes the accepted A and Gₛ after its iterative hard calls.
const AGRIPV_LEAF_OUTPUT_COLUMNS = merge((
    A=(:energy_balance, :A),
    Tₗ=(:energy_balance, :Tₗ),
    Gₛ=(:energy_balance, :Gₛ),
    λE=(:energy_balance, :λE),
), AGRIPV_LIGHT_OUTPUT_COLUMNS)

const AGRIPV_OUTPUT_METADATA = (:node_id, :plant_id, :timestep, :datetime, :object_id, :scale, :kind)

function _output_plant_node_id(node, cache)
    id = MultiScaleTreeGraph.node_id(node)
    haskey(cache, id) && return cache[id]
    parent_node = parent(node)
    plant_id = MultiScaleTreeGraph.symbol(node) == :Plant ? id :
        (isnothing(parent_node) ? missing : _output_plant_node_id(parent_node, cache))
    cache[id] = plant_id
    return plant_id
end

# Generic Object scenarios have no MTG correspondence. Never label their
# engine ID as a node ID; MTG-backed scenarios use the public source mapping.
function _output_node_ids(model, objects)
    node_ids = fill!(Vector{Union{Missing,Int}}(undef, length(objects)), missing)
    plant_ids = copy(node_ids)
    isempty(objects) && return node_ids, plant_ids
    first_node = try
        PlantSimEngine.source_node(model, first(objects).id)
    catch error
        error isa ArgumentError || rethrow()
        return node_ids, plant_ids
    end
    plant_cache = Dict{Int,Union{Missing,Int}}()
    for (i, object) in enumerate(objects)
        node = i == 1 ? first_node : PlantSimEngine.source_node(model, object.id)
        node_ids[i] = MultiScaleTreeGraph.node_id(node)
        plant_ids[i] = _output_plant_node_id(node, plant_cache)
    end
    return node_ids, plant_ids
end

function leaf_output_requests(; kind=:active_leaf)
    return [
        OutputRequest(
            Many(scale=:LeafSection, kind=kind), variable;
            application,
            name=Symbol("leaf_", column),
        )
        for (column, (application, variable)) in pairs(AGRIPV_LEAF_OUTPUT_COLUMNS)
    ]
end

function light_output_requests()
    # Distributed-output requests retain only destinations owned by this
    # publisher, even though SceneScope also contains non-geometric nodes.
    return [
        OutputRequest(
            Many(within=SceneScope()), variable;
            application,
            name=Symbol("light_", column),
        )
        for (column, (application, variable)) in pairs(AGRIPV_LIGHT_OUTPUT_COLUMNS)
    ]
end

_selected_output_date(value::DateTime) = value
_selected_output_date(value::Date) = DateTime(value)
_selected_output_date(value::Dates.AbstractDateTime) = DateTime(value)
_selected_output_date(value) = missing

function _selected_output_dates(dates)
    isnothing(dates) && return missing
    dates isa Union{Date,Dates.AbstractDateTime} && return _selected_output_date(dates)
    return Union{Missing,DateTime}[_selected_output_date(value) for value in dates]
end

_selected_output_datetime(date::Union{Missing,DateTime}, timestep) = date

function _selected_output_datetime(dates::AbstractVector, timestep)
    return checkbounds(Bool, dates, timestep) ? dates[timestep] : missing
end

function _selected_output_timestep(time)
    isfinite(time) && time >= 1 && isinteger(time) || throw(ArgumentError(
        "The AgriPV output tables require integer global publication steps; got $time.",
    ))
    return Int(time)
end

# Merge the already ordered publication streams. At most one publication of
# each column exists per object and step. Missing columns remain missing: this
# collector does not resample or silently hold a value across unpublished steps.
function _visit_selected_output_rows(streams, visit)
    positions = ones(Int, length(streams))
    rows = 0
    while true
        next_time = Inf
        for column in eachindex(streams)
            samples = streams[column]
            isnothing(samples) && continue
            position = positions[column]
            position <= length(samples) || continue
            next_time = min(next_time, first(samples[position]))
        end
        isinf(next_time) && break
        timestep = _selected_output_timestep(next_time)
        rows += 1
        isnothing(visit) || visit(rows, timestep, positions)
        for column in eachindex(streams)
            samples = streams[column]
            isnothing(samples) && continue
            position = positions[column]
            position <= length(samples) || continue
            first(samples[position]) == next_time || continue
            positions[column] += 1
        end
    end
    return rows
end

"""
    collect_selected_outputs(simulation, model; columns, scale=nothing,
                             kind=nothing, geometry_only=false, dates=nothing)

Build a wide DataFrame directly from the public `outputs(simulation)` streams.
`columns` is a named tuple mapping each table column to `(application, variable)`,
for example `(A=(:energy_balance, :A), area=(:archimed_light, :area))`. The explicit
publisher prevents ambiguous A/Gₛ values from iterative photosynthesis calls.

Rows include `node_id`, the actual source MTG node ID, and `plant_id`, the
nearest Plant ancestor's node ID (the plant itself for Plant rows). These are
missing for generic Object scenarios without an MTG. `object_id` retains the
engine identity, which need not equal `node_id`; the original OBJ `:Id`
attribute is not a unique scene identifier. Rows use global `timestep` values. Objects are
ordered by the public object query and their publication steps are chronological.
Only currently registered objects matching `scale`, `kind`, and `geometry_only`
are selected; this is intended for this project's static daily scenes.

`dates` must come from the forcing passed to the simulation, indexed by global
step. Dates become midnight DateTimes, and timestamp subtypes of
`Dates.AbstractDateTime` use their DateTime conversion. Absent dates produce `missing`, and a
scalar forcing date is repeated. A vector remains indexed by step, including
when it has only one entry. No held values or interpolation are introduced.

Columns are preallocated and preserve the retained numeric types. With a fixed
number of selected columns, counting and merging publications is linear in their
number, without constructing or sorting a long table of all retained variables.
"""
function collect_selected_outputs(
    simulation,
    model;
    columns::NamedTuple,
    scale=nothing,
    kind=nothing,
    geometry_only=false,
    dates=nothing,
)
    reserved = AGRIPV_OUTPUT_METADATA
    any(name -> name in reserved, keys(columns)) && throw(ArgumentError(
        "Selected output names must not overlap the metadata columns $reserved.",
    ))
    sources = Tuple(values(columns))
    all(source -> source isa Tuple && length(source) == 2 &&
        all(value -> value isa Symbol, source), sources) || throw(ArgumentError(
        "Each output column must identify a publisher as (application::Symbol, variable::Symbol).",
    ))
    isempty(sources) && throw(ArgumentError("Select at least one output column."))

    objects = PlantSimEngine.model_objects(model; scale, kind)
    geometry_only && filter!(object -> !isnothing(object.geometry), objects)
    source_node_ids, source_plant_ids = _output_node_ids(model, objects)
    object_positions = Dict(object.id => index for (index, object) in enumerate(objects))
    streams_by_object = [Any[nothing for _ in sources] for _ in objects]
    value_types = Type[Union{} for _ in sources]
    found_sources = falses(length(sources))

    for ((application, object_id, variable), samples) in PlantSimEngine.outputs(simulation)
        object_position = get(object_positions, object_id, 0)
        object_position == 0 && continue
        for column in eachindex(sources)
            sources[column] == (application, variable) || continue
            found_sources[column] = true
            streams_by_object[object_position][column] = samples
            value_type = fieldtype(eltype(samples), 2)
            value_types[column] = Base.promote_typejoin(value_types[column], value_type)
        end
    end
    if !isempty(objects)
        for column in eachindex(sources)
            found_sources[column] && continue
            throw(ArgumentError(
                "No retained stream for column `$(keys(columns)[column])` from " *
                "$(sources[column]) on the selected objects. Add its OutputRequest before run!.",
            ))
        end
    end

    row_counts = [_visit_selected_output_rows(streams, nothing) for streams in streams_by_object]
    nrows = sum(row_counts)
    object_id_type = foldl(
        Base.promote_typejoin,
        (typeof(object.id.value) for object in objects);
        init=Union{},
    )
    object_id_type === Union{} && (object_id_type = Any)
    object_ids_column = Vector{object_id_type}(undef, nrows)
    steps_column = Vector{Int}(undef, nrows)
    datetimes_column = Vector{Union{Missing,DateTime}}(undef, nrows)
    scales_column = Vector{Union{Missing,Symbol}}(undef, nrows)
    kinds_column = Vector{Union{Missing,Symbol}}(undef, nrows)
    node_ids_column = Vector{Union{Missing,Int}}(undef, nrows)
    plant_ids_column = Vector{Union{Missing,Int}}(undef, nrows)
    output_columns = [fill!(Vector{Union{Missing,T}}(undef, nrows), missing) for T in value_types]
    forcing_dates = _selected_output_dates(dates)

    offset = 0
    for (object, streams, row_count, node_id, plant_id) in
        zip(objects, streams_by_object, row_counts, source_node_ids, source_plant_ids)
        row_offset = offset
        _visit_selected_output_rows(streams, (local_row, timestep, positions) -> begin
            row = row_offset + local_row
            object_ids_column[row] = object.id.value
            node_ids_column[row] = node_id
            plant_ids_column[row] = plant_id
            steps_column[row] = timestep
            datetimes_column[row] = _selected_output_datetime(forcing_dates, timestep)
            scales_column[row] = isnothing(object.scale) ? missing : object.scale
            kinds_column[row] = isnothing(object.kind) ? missing : object.kind
            for column in eachindex(streams)
                samples = streams[column]
                isnothing(samples) && continue
                position = positions[column]
                position <= length(samples) || continue
                first(samples[position]) == timestep || continue
                output_columns[column][row] = last(samples[position])
            end
        end)
        offset += row_count
    end
    table = DataFrame(
        node_id=node_ids_column,
        plant_id=plant_ids_column,
        timestep=steps_column,
        datetime=datetimes_column,
        object_id=object_ids_column,
        scale=scales_column;
        copycols=false,
    )
    table[!, :kind] = kinds_column
    for (name, values) in zip(keys(columns), output_columns)
        table[!, name] = values
    end
    return table
end

"""
    collect_leaf_outputs(simulation, model; dates=nothing, meteo=nothing, kind=:active_leaf)

One row per active LeafSection and published timestep, with physiology and
light together. Pass the actual forcing as `meteo` to add section assimilation
and water exchange. `transpiration_flux` is kg m⁻² s⁻¹; `transpiration`,
`condensation` and `net_water_flux` are kg s⁻¹ per section; step transpiration
is kg. `A_section` is μmol CO₂ s⁻¹ and `assimilation_step` is μmol CO₂.
"""
function collect_leaf_outputs(simulation, model; dates=nothing, meteo=nothing, kind=:active_leaf)
    if isnothing(dates) && !isnothing(meteo)
        dates = [row.date for row in meteo]
    end
    table = collect_selected_outputs(
        simulation, model;
        columns=AGRIPV_LEAF_OUTPUT_COLUMNS,
        scale=:LeafSection,
        kind,
        dates,
    )
    isnothing(meteo) || _add_leaf_flux_outputs!(table, meteo)
    return table
end

function _add_leaf_flux_outputs!(table, meteo)
    steps = unique(table.timestep)
    all(step -> 1 <= step <= length(meteo), steps) ||
        throw(ArgumentError("Forcing must be indexed by the retained global timesteps."))
    latent_heat = [meteo[step].λ for step in steps]
    durations = [meteo[step].duration isa Real ? meteo[step].duration :
        Dates.toms(meteo[step].duration) / 1000 for step in steps]
    for (λ, seconds) in zip(latent_heat, durations)
        isfinite(λ) && λ > 0 || throw(DomainError(λ, "Latent heat must be positive and finite (J kg⁻¹)."))
        isfinite(seconds) && seconds > 0 || throw(DomainError(seconds, "Duration must be positive and finite (s)."))
    end
    step_positions = Dict(step => i for (i, step) in enumerate(steps))
    λ = [latent_heat[step_positions[step]] for step in table.timestep]
    seconds = [durations[step_positions[step]] for step in table.timestep]
    net_flux = table.λE ./ λ
    table[!, :A_section] = table.A .* table.area
    table[!, :assimilation_step] = table.A_section .* seconds
    table[!, :net_water_flux] = net_flux .* table.area
    table[!, :transpiration_flux] = max.(net_flux, 0)
    table[!, :transpiration] = max.(table.net_water_flux, 0)
    table[!, :condensation] = max.(-table.net_water_flux, 0)
    table[!, :transpiration_step] = table.transpiration .* seconds
    return table
end

collect_light_outputs(simulation, model; dates=nothing) =
    collect_selected_outputs(
        simulation, model;
        columns=AGRIPV_LIGHT_OUTPUT_COLUMNS,
        geometry_only=true,
        dates,
    )

"""
    attach_outputs!(mtg, table; timestep, variables=nothing, clear=true)

Attach scalar columns from one timestep to their exact `node_id` in the MTG.
Use the MTG returned by the simulation, or a copy preserving its node IDs.
The original crop template's OBJ `:Id` cannot be used to identify scene nodes.
By default, attach all non-metadata columns. Missing/nonfinite values become
`nothing`, which PlantViz renders with `color_missing`. `clear=true` clears
these variables on other nodes, avoiding stale values from a previous snapshot.
Unknown IDs, duplicate nodes and absent timesteps are rejected before mutation.
Plant columns are stored on Plant nodes; these have no geometry of their own.
Use `clear=false` when combining leaf and plant tables with shared column names
on the same snapshot, so the second table preserves the first scale's values.
"""
function attach_outputs!(mtg::MultiScaleTreeGraph.Node, table::AbstractDataFrame;
    timestep::Integer, variables=nothing, clear=true)
    :node_id in propertynames(table) && :timestep in propertynames(table) ||
        throw(ArgumentError("The output table must contain node_id and timestep."))
    columns = isnothing(variables) ?
        Tuple(name for name in propertynames(table) if name ∉ AGRIPV_OUTPUT_METADATA) :
        (variables isa Symbol ? (variables,) : Tuple(Symbol.(variables)))
    isempty(columns) && throw(ArgumentError("Select at least one output variable."))
    all(name -> name in propertynames(table) && name ∉ AGRIPV_OUTPUT_METADATA, columns) ||
        throw(ArgumentError("Select existing output columns, excluding identity and time metadata."))
    rows = findall(==(timestep), table.timestep)
    isempty(rows) && throw(ArgumentError("No outputs were published at timestep $timestep."))
    nodes = Dict{Int,typeof(mtg)}()
    MultiScaleTreeGraph.traverse!(mtg) do node
        nodes[MultiScaleTreeGraph.node_id(node)] = node
    end
    selected_ids = Set{Int}()
    for row in rows
        id = table.node_id[row]
        !ismissing(id) && haskey(nodes, id) ||
            throw(ArgumentError("Output node_id $id is absent from this MTG."))
        id ∉ selected_ids || throw(ArgumentError("Repeated node_id $id at timestep $timestep."))
        push!(selected_ids, id)
    end
    if clear
        for node in values(nodes), name in columns
            node[name] = nothing
        end
    end
    for row in rows
        node = nodes[table.node_id[row]]
        for name in columns
            value = table[row, name]
            node[name] = ismissing(value) || (value isa Real && !isfinite(value)) ? nothing : value
        end
    end
    return mtg
end

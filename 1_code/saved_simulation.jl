using CSV, DataFrames, Dates, SHA, TOML
using MultiScaleTreeGraph, PlantGeom, GeometryBasics
isdefined(@__MODULE__, :_agripv_write_parquet) || include("parquet_output_io.jl")

isdefined(@__MODULE__, :_agripv_compact_light) || include("light_output_io.jl")

_agripv_saved_file_sha256(path) = bytes2hex(open(SHA.sha256, path))

isdefined(@__MODULE__, :ConfigPV) || include("pvconfig.jl")
isdefined(@__MODULE__, :agripv_scene) || include("scene.jl")
isdefined(@__MODULE__, :attach_outputs!) || include("simulation_outputs.jl")

_agripv_project_root() = normpath(joinpath(@__DIR__, ".."))
_agripv_daily_output_dir() = joinpath(_agripv_project_root(), "2_outputs", "simulations", "daily")

"""SHA256 of node identities, topology and world-space meshes, excluding outputs."""
function agripv_scene_fingerprint(scene)
    io = IOBuffer()
    MultiScaleTreeGraph.traverse!(scene.mtg) do node
        ancestor = parent(node)
        print(io, node_id(node), '|', isnothing(ancestor) ? 0 : node_id(ancestor), '|',
            symbol(node), '|', MultiScaleTreeGraph.scale(node), '|',
            MultiScaleTreeGraph.index(node), '|', node[:state], '\n')
        mesh = PlantGeom.refmesh_to_mesh(node)
        if isnothing(mesh)
            write(io, Int64(0))
        else
            points, triangles = GeometryBasics.coordinates(mesh), GeometryBasics.faces(mesh)
            write(io, Int64(length(points)), Int64(length(triangles)))
            for point in points, value in point
                write(io, Float64(value))
            end
            for face in triangles, value in face
                write(io, Int64(value))
            end
        end
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

"""
    write_day_outputs(result; config_id, output_dir=...)

Write the leaf and plant CSVs and compact gzip light results and `scene_config_ID_DATE.toml` beside them.
The sidecar stores the resolved PV configuration, actual plant rotations,
scene settings and source-file hashes. Keep it with the CSVs to reconstruct
the original scene later with `load_day_outputs`, without rerunning physics.
`compact_light=false` preserves the legacy full, uncompressed light export.
The result must use this version of `agripv_scene`, which records its recipe.
"""
function _write_day_outputs_csv(result; config_id, output_dir=_agripv_daily_output_dir(), compact_light=true)
    recipe = result.scene.mtg[:agripv_scene_recipe]
    isnothing(recipe) && throw(ArgumentError(
        "This scene has no saved construction recipe. Generate it with the updated agripv_scene before exporting.",
    ))
    recipe = deepcopy(recipe)
    for source in ("obj", "mtg")
        path = recipe[source * "_path"]
        _agripv_saved_file_sha256(path) == recipe[source * "_sha256"] || throw(ArgumentError(
            "The plant $source source changed since scene construction: $path",
        ))
        recipe[source * "_path"] = relpath(path, _agripv_project_root())
    end
    day = recipe["day"]
    output_dir = abspath(output_dir)
    paths = (
        leaves=joinpath(output_dir, "out_config_$(config_id)_$(day).csv"),
        plants=joinpath(output_dir, "plants_config_$(config_id)_$(day).csv"),
        light=joinpath(output_dir, "light_config_$(config_id)_$(day).csv$(compact_light ? ".gz" : "")"),
        metadata=joinpath(output_dir, "scene_config_$(config_id)_$(day).toml"),
    )
    fingerprint = agripv_scene_fingerprint(result.scene)
    mkpath(output_dir)
    tables = Dict{String,Any}()
    for name in (:leaves, :plants, :light)
        table = getproperty(result, name)
        ncol(table) == 0 && continue
        path = getproperty(paths, name)
        if name == :light && compact_light
            CSV.write(path, _agripv_compact_light(table); compress=true)
        else
            CSV.write(path, table)
        end
        tables[string(name)] = Dict("file" => basename(path), "sha256" => _agripv_saved_file_sha256(path))
    end
    metadata = Dict(
        "format_version" => 1, "config_id" => config_id,
        "scene" => recipe, "scene_sha256" => fingerprint, "tables" => tables,
    )
    open(paths.metadata, "w") do io
        TOML.print(io, metadata)
    end
    return paths
end

function _validate_saved_output_table!(table, scene)
    required = (:node_id, :plant_id, :timestep, :scale, :kind)
    all(name -> name in propertynames(table), required) || throw(ArgumentError(
        "Saved output tables must contain $required.",
    ))
    for name in (:scale, :kind)
        table[!, name] = Union{Missing,Symbol}[ismissing(value) ? missing : Symbol(value)
            for value in table[!, name]]
    end
    nodes = Dict{Int,typeof(scene.mtg)}()
    plant_ids = Dict{Int,Union{Missing,Int}}()
    has_plant_instances = :plant_instance_id in propertynames(table)
    plant_instance_ids = Dict{Int,Union{Missing,Int}}()
    MultiScaleTreeGraph.traverse!(scene.mtg) do node
        nodes[node_id(node)] = node
        _output_plant_node_id(node, plant_ids)
        has_plant_instances && _output_plant_instance_id(node, plant_instance_ids)
    end
    seen = Set{Tuple{Int,Int}}()
    for row in eachrow(table)
        id, step = row.node_id, row.timestep
        id isa Integer && haskey(nodes, id) || throw(ArgumentError("Unknown saved node_id $id."))
        step isa Integer && step > 0 || throw(ArgumentError("Invalid saved timestep $step."))
        (id, step) ∉ seen || throw(ArgumentError("Repeated node_id $id at timestep $step."))
        push!(seen, (id, step))
        node = nodes[id]
        kind = symbol(node) == :LeafSection ?
            (node[:state] == "senescent" ? :senescent_leaf : :active_leaf) : missing
        isequal(row.scale, symbol(node)) && isequal(row.plant_id, plant_ids[id]) &&
            (!has_plant_instances || isequal(row.plant_instance_id, plant_instance_ids[id])) &&
            isequal(row.kind, kind) || throw(ArgumentError("Saved identity metadata differs for node_id $id."))
    end
    return table
end

"""
    load_day_outputs(; config_id, day, output_dir=..., tables=(:leaves, :plants, :light))

Read saved Parquet/CSV tables and rebuild their original scene from its TOML recipe.
Replays plant rotations and the saved configuration values, independently of
the current DOE file and RNG. Checks source files, scene geometry, CSV hashes
and node metadata before returning. No meteorology or simulation is executed.
Return `scene`, `leaves`, `plants`, `light`, `config`, `day` and `metadata`.
Use `tables=(:leaves,)` to read just leaf outputs; other tables are empty.
Parquet readers also accept `timestep` and `variables` for selective snapshots.
Earlier format-version-1 tables without `plant_instance_id` remain readable.
When present, that column is also checked against each node's Plant ancestor.
"""
function load_day_outputs(; config_id, day, output_dir=_agripv_daily_output_dir(),
    tables=(:leaves, :plants, :light), timestep=nothing, variables=nothing, verify_hash=true)
    tables = tables isa Symbol ? (tables,) : Tuple(tables)
    all(name -> name in (:leaves, :plants, :light), tables) ||
        throw(ArgumentError("Select leaves, plants and/or light tables."))
    output_dir = abspath(output_dir)
    filename = joinpath(output_dir, "scene_config_$(config_id)_$(day).toml")
    if !isfile(filename)
        filename = joinpath(output_dir, "scene_config_$(config_id).toml")
    end
    isfile(filename) || throw(ArgumentError(
        "Scene recipe not found: $filename. CSVs alone cannot recover random plant rotations; export with write_day_outputs.",
    ))
    metadata = TOML.parsefile(filename)
    get(metadata, "format_version", nothing) in (1, 2) || throw(ArgumentError("Unsupported scene recipe format."))
    entry = haskey(metadata, "scene") ? metadata : only(filter(x -> x["scene"]["day"] == string(day), metadata["scenes"]))
    isequal(metadata["config_id"], config_id) && entry["scene"]["day"] == string(day) ||
        throw(ArgumentError("The saved recipe has a different configuration ID or date."))
    recipe = entry["scene"]
    source_paths = Dict{String,String}()
    for source in ("obj", "mtg")
        path = normpath(joinpath(_agripv_project_root(), recipe[source * "_path"]))
        isfile(path) && _agripv_saved_file_sha256(path) == recipe[source * "_sha256"] ||
            throw(ArgumentError("The saved plant $source source is missing or changed: $path"))
        source_paths[source] = path
    end
    config = ConfigPV(; (Symbol(name) => value for (name, value) in recipe["config"])...)
    scene = agripv_scene(; c=config, day=Date(recipe["day"]),
        plant_density=recipe["plant_density"], ground_res=recipe["ground_res"],
        ground_nx=get(recipe, "ground_nx", round(Int, recipe["ground_res"] * config.panel_x_distance)),
        ground_ny=get(recipe, "ground_ny", round(Int, recipe["ground_res"] * config.panel_y_distance)),
        obj_path=source_paths["obj"], mtg_path=source_paths["mtg"],
        plant_rotations=recipe["plant_rotations_rad"])
    agripv_scene_fingerprint(scene) == entry["scene_sha256"] || throw(ArgumentError(
        "Rebuilt scene geometry or node IDs differ from the saved simulation scene.",
    ))
    loaded = Dict(name => DataFrame() for name in (:leaves, :plants, :light))
    for name in tables
        info = get(metadata["tables"], string(name), nothing)
        isnothing(info) && continue # The run did not retain this table.
        get(info, "available", true) || throw(ArgumentError("Saved $name outputs are marked unavailable."))
        table = if haskey(info, "files")
            _agripv_read_parquet(output_dir, info; day, timestep, variables, verify_hash)
        else
            path = joinpath(output_dir, info["file"])
            isfile(path) && (!verify_hash || _agripv_saved_file_sha256(path) == info["sha256"]) ||
                throw(ArgumentError("The saved $name CSV is missing or changed: $path"))
            _agripv_open_light(path) do io
                CSV.read(io, DataFrame)
            end
        end
        name == :light && _agripv_restore_light_timestep!(table, recipe["day"])
        !isnothing(timestep) && (table = filter(:timestep => ==(timestep), table))
        loaded[name] = _validate_saved_output_table!(table, scene)
    end
    return (; scene, leaves=loaded[:leaves], plants=loaded[:plants], light=loaded[:light],
        config, day=Date(recipe["day"]), metadata)
end

_agripv_yearly_output_dir() = joinpath(_agripv_project_root(), "2_outputs", "simulations", "yearly")

"""
    load_yearly_scene(; config_id, day, output_dir=...)

Load and rebuild a specific day's scene from a yearly simulation TOML file.
The yearly configuration contains scene recipes for all simulated days, and this
function extracts and rebuilds the scene for the requested day. It validates
source files and scene geometry against the saved fingerprints to ensure
consistency. No meteorology or simulation is executed.

Return the rebuilt `scene` and its `config` for the specified day.
"""
function load_yearly_scene(; config_id, day, output_dir=_agripv_yearly_output_dir())
    output_dir = abspath(output_dir)
    filename = joinpath(output_dir, "scene_config_$(config_id).toml")
    isfile(filename) || throw(ArgumentError(
        "Yearly scene config not found: $filename. Use the daily loader for per-day TOML files.",
    ))
    metadata = TOML.parsefile(filename)
    get(metadata, "format_version", nothing) in (1, 2) || throw(ArgumentError("Unsupported scene recipe format."))
    isequal(metadata["config_id"], config_id) ||
        throw(ArgumentError("The saved recipe has a different configuration ID."))

    day_str = string(day)
    scenes_array = get(metadata, "scenes", nothing)
    isnothing(scenes_array) && throw(ArgumentError(
        "No scenes array found in yearly configuration file.",
    ))

    # Find the scene entry for the requested day
    scene_entry = nothing
    for entry in scenes_array
        scene_recipe = get(entry, "scene", nothing)
        isnothing(scene_recipe) && continue
        entry_day = get(scene_recipe, "day", nothing)
        isnothing(entry_day) && continue
        entry_day == day_str && (scene_entry = entry; break)
    end

    isnothing(scene_entry) && throw(ArgumentError(
        "No scene found for day $day in configuration $config_id."
    ))

    recipe = scene_entry["scene"]
    scene_sha256 = scene_entry["scene_sha256"]

    # Validate source files
    source_paths = Dict{String,String}()
    for source in ("obj", "mtg")
        path = normpath(joinpath(_agripv_project_root(), recipe[source * "_path"]))
        isfile(path) && _agripv_saved_file_sha256(path) == recipe[source * "_sha256"] ||
            throw(ArgumentError("The saved plant $source source is missing or changed: $path"))
        source_paths[source] = path
    end

    # Build the configuration
    config = ConfigPV(; (Symbol(name) => value for (name, value) in recipe["config"])...)

    # Rebuild the scene
    scene = agripv_scene(;
        c=config,
        day=Date(recipe["day"]),
        plant_density=recipe["plant_density"],
        ground_res=recipe["ground_res"],
        ground_nx=get(recipe, "ground_nx", round(Int, recipe["ground_res"] * config.panel_x_distance)),
        ground_ny=get(recipe, "ground_ny", round(Int, recipe["ground_res"] * config.panel_y_distance)),
        obj_path=source_paths["obj"],
        mtg_path=source_paths["mtg"],
        plant_rotations=recipe["plant_rotations_rad"]
    )

    # Verify fingerprint
    agripv_scene_fingerprint(scene) == scene_sha256 || throw(ArgumentError(
        "Rebuilt scene geometry or node IDs differ from the saved simulation scene."
    ))

    return (; scene, config, day=Date(recipe["day"]))
end


function _agripv_day_parquet_data!(result; config_id, root, dataset,
    tables=(:leaves, :plants, :light), compact_light=true, compression_level=19, batch_rows=122880)
    recipe = deepcopy(result.scene.mtg[:agripv_scene_recipe])
    isnothing(recipe) && throw(ArgumentError("Scene has no saved construction recipe."))
    for family in ("obj", "mtg")
        path = recipe[family * "_path"]
        _agripv_saved_file_sha256(path) == recipe[family * "_sha256"] || throw(ArgumentError("Geometry source changed: $path"))
        recipe[family * "_path"] = relpath(path, _agripv_project_root())
    end
    day = Date(recipe["day"])
    saved_tables = Dict{String,Any}()
    for role in tables
        role in (:leaves, :plants, :light) || throw(ArgumentError("Unknown output table $role."))
        source = getproperty(result, role)
        ncol(source) == 0 && continue
        table = DataFrame(role == :light && compact_light ? _agripv_compact_light(source) : source; copycols=false)
        # Keep date and configuration explicit in the new schema.
        table.day = fill(day, nrow(table))
        table.config_id = fill(config_id, nrow(table))
        directory = joinpath(root, dataset, string(role), "day=$day")
        entries = _agripv_write_parquet(table, directory; day, compression_level, batch_rows)
        for item in entries
            item["file"] = relpath(joinpath(directory, item["file"]), root)
        end
        saved_tables[string(role)] = _agripv_parquet_info(entries; compression_level)
    end
    metadata = Dict("format_version" => 2, "storage" => "parquet", "config_id" => config_id,
        "scene" => recipe, "scene_sha256" => agripv_scene_fingerprint(result.scene), "tables" => saved_tables)
    if hasproperty(result, :meteo)
        forcing = DataFrame(date=DateTime[row.date for row in result.meteo],
            duration=Float64[row.duration isa Real ? row.duration : Dates.toms(row.duration)/1000 for row in result.meteo],
            Ri_PAR_f=Float64[row.Ri_PAR_f for row in result.meteo])
        directory = joinpath(root, dataset, "forcing", "day=$day")
        entries = _agripv_write_parquet(forcing, directory; day, compression_level, batch_rows)
        for item in entries
            item["file"] = relpath(joinpath(directory, item["file"]), root)
        end
        metadata["forcing"] = _agripv_parquet_info(entries; compression_level)
        metadata["forcing_origin"] = "simulation"
        metadata["forcing_provenance"] = "actual prepared forcing; duration seconds; Ri_PAR_f W m^-2"
    end
    return metadata
end

"""Write lossless Parquet/Zstandard-19 by default; storage=:csv retains legacy exports."""
function write_day_outputs(result; config_id, output_dir=_agripv_daily_output_dir(),
    storage=:parquet, tables=(:leaves, :plants, :light), compact_light=true,
    compression_level=19, batch_rows=122880, provenance=Dict{String,Any}())
    storage in (:parquet, :csv) || throw(ArgumentError("storage must be :parquet or :csv."))
    storage == :csv && return _write_day_outputs_csv(result; config_id, output_dir, compact_light)
    output_dir = abspath(output_dir)
    mkpath(output_dir)
    day = result.scene.mtg[:agripv_scene_recipe]["day"]
    dataset = "config_$(config_id)_$day"
    metadata_file = "scene_config_$(config_id)_$day.toml"
    metadata = mktempdir(output_dir; prefix=".parquet_") do staging
        mkpath(joinpath(staging, dataset))
        data = _agripv_day_parquet_data!(result; config_id, root=staging, dataset,
            tables, compact_light, compression_level, batch_rows)
        isempty(provenance) || (data["reproducibility"] = provenance)
        open(joinpath(staging, metadata_file), "w") do io
            TOML.print(io, data)
        end
        _agripv_publish_dataset(staging, output_dir, dataset, metadata_file)
        data
    end
    paths = (; (role => (haskey(metadata["tables"], string(role)) ? joinpath(output_dir, dataset, string(role)) : nothing)
        for role in (:leaves, :plants, :light))...)
    return merge(paths, (; metadata=joinpath(output_dir, metadata_file)))
end

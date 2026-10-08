using CSV, DataFrames, Dates, SHA, TOML
using MultiScaleTreeGraph, PlantGeom, GeometryBasics

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
function write_day_outputs(result; config_id, output_dir=_agripv_daily_output_dir(), compact_light=true)
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
            CSV.write(path, _agripv_compact_light(table); compress=:gzip)
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

Read saved CSVs and rebuild their original scene from its TOML recipe.
Replays plant rotations and the saved configuration values, independently of
the current DOE file and RNG. Checks source files, scene geometry, CSV hashes
and node metadata before returning. No meteorology or simulation is executed.
Return `scene`, `leaves`, `plants`, `light`, `config`, `day` and `metadata`.
Use `tables=(:leaves,)` when only that CSV is needed; other tables are empty.
Earlier format-version-1 tables without `plant_instance_id` remain readable.
When present, that column is also checked against each node's Plant ancestor.
"""
function load_day_outputs(; config_id, day, output_dir=_agripv_daily_output_dir(),
    tables=(:leaves, :plants, :light))
    tables = tables isa Symbol ? (tables,) : Tuple(tables)
    all(name -> name in (:leaves, :plants, :light), tables) ||
        throw(ArgumentError("Select leaves, plants and/or light tables."))
    output_dir = abspath(output_dir)
    filename = joinpath(output_dir, "scene_config_$(config_id)_$(day).toml")
    isfile(filename) || throw(ArgumentError(
        "Scene recipe not found: $filename. CSVs alone cannot recover random plant rotations; export with write_day_outputs.",
    ))
    metadata = TOML.parsefile(filename)
    get(metadata, "format_version", nothing) == 1 || throw(ArgumentError("Unsupported scene recipe format."))
    isequal(metadata["config_id"], config_id) && metadata["scene"]["day"] == string(day) ||
        throw(ArgumentError("The saved recipe has a different configuration ID or date."))
    recipe = metadata["scene"]
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
    agripv_scene_fingerprint(scene) == metadata["scene_sha256"] || throw(ArgumentError(
        "Rebuilt scene geometry or node IDs differ from the saved simulation scene.",
    ))
    loaded = Dict(name => DataFrame() for name in (:leaves, :plants, :light))
    for name in tables
        info = get(metadata["tables"], string(name), nothing)
        isnothing(info) && continue # The run did not retain this table.
        path = joinpath(output_dir, info["file"])
        isfile(path) && _agripv_saved_file_sha256(path) == info["sha256"] ||
            throw(ArgumentError("The saved $name CSV is missing or changed: $path"))
        table = _agripv_open_light(path) do io
            CSV.read(io, DataFrame)
        end
        name == :light && _agripv_restore_light_timestep!(table, recipe["day"])
        loaded[name] = _validate_saved_output_table!(table, scene)
    end
    return (; scene, leaves=loaded[:leaves], plants=loaded[:plants], light=loaded[:light],
        config, day=Date(recipe["day"]), metadata)
end

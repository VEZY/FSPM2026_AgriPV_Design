using Dates, CSV, DataFrames, TOML
using PlantMeteo, TableOperations, PlantMeteo.Tables

isdefined(@__MODULE__, :day_simulation) || include("simulation.jl")
isdefined(@__MODULE__, :write_day_outputs) || include("saved_simulation.jl")

"""
    plant_simulation_days(; plant_dir=..., plant_pattern="*.obj")

Discover plant OBJ/MTG pairs whose OBJ names end in `YYYY-MM-DD.obj`.
Return chronologically sorted `day`, `obj_path`, `mtg_path` records. Only
these dates are simulated; gaps are not filled. Ambiguous dates and missing
MTGs are errors. Narrow `plant_pattern` when several crop series coexist.
"""
function plant_simulation_days(;
    plant_dir=joinpath(_agripv_project_root(), "2_outputs", "archicrop"),
    plant_pattern="*.obj",
)
    sources = NamedTuple{(:day, :obj_path, :mtg_path),Tuple{Date,String,String}}[]
    for obj in sort(glob(plant_pattern, abspath(plant_dir)))
        isfile(obj) && endswith(obj, ".obj") || continue
        matched = match(r"(\d{4}-\d{2}-\d{2})\.obj$", basename(obj))
        isnothing(matched) && continue
        day = Date(only(matched.captures))
        obj_path, mtg_path = _agripv_plant_paths(day, obj, nothing)
        push!(sources, (; day, obj_path, mtg_path))
    end
    isempty(sources) && throw(ArgumentError("No dated plant OBJ/MTG pairs in $plant_dir ($plant_pattern)."))
    sort!(sources; by=x -> x.day)
    days = getproperty.(sources, :day)
    allunique(days) || throw(ArgumentError(
        "Several plant OBJs have the same date. Select one crop series with plant_pattern.",
    ))
    return sources
end

"""
    year_simulation(; pvconfig, config_id, plant_dir=..., plant_pattern="*.obj",
        days=nothing, meteo=nothing, keep_leaves=true, keep_light=true,
        scene_kwargs=(), output_dir=...)

Run the daily coupled ArchimedLight/PlantBiophysics simulation for every
available plant date. `days` can restrict the run to a subset of those dates.
Read climate once, rebuild the growing plant scene each day, and append each
daily table to a CSV per configuration and table in `output_dir`. Retain at
most one day's model and outputs in memory. Panels use the supplied PV config;
plant rotations are reused throughout the period.

Rows keep the daily schema and add `day` and `config_id`. Node identities and
`timestep` are local to each day; plant cumulative quantities reset daily.
`plant_instance_id` tracks the same planting position across days within this
configuration, provided the planting layout stays fixed.
The TOML sidecar stores each scene recipe and fingerprint. Files are published
after all daily simulations succeed; a simulation failure preserves prior outputs.
Return output paths, simulated dates and row counts, rather than all tables.
"""
function year_simulation(; pvconfig, config_id,
    plant_dir=joinpath(_agripv_project_root(), "2_outputs", "archicrop"),
    plant_pattern="*.obj", days=nothing, meteo=nothing,
    keep_leaves=true, keep_light=true, scene_kwargs=NamedTuple(),
    output_dir=joinpath(_agripv_project_root(), "2_outputs", "simulations", "yearly"),
)
    sources = plant_simulation_days(; plant_dir, plant_pattern)
    if !isnothing(days)
        selected = Set(Date.(collect(days)))
        isempty(selected) && throw(ArgumentError("Select at least one plant date."))
        absent = setdiff(selected, Set(getproperty.(sources, :day)))
        isempty(absent) || throw(ArgumentError("No plant maquette for $(sort!(collect(absent)))."))
        filter!(source -> source.day in selected, sources)
    end
    dates = getproperty.(sources, :day)
    meteo = isnothing(meteo) ? get_meteo(dates) : meteo
    forcing_days = Set(Date(row.date) for row in meteo)
    missing_days = setdiff(Set(dates), forcing_days)
    isempty(missing_days) || throw(ArgumentError("No meteorology for $(sort!(collect(missing_days)))."))

    output_dir = abspath(output_dir)
    mkpath(output_dir)
    filenames = (
        leaves="out_config_$(config_id).csv",
        plants="plants_config_$(config_id).csv",
        light="light_config_$(config_id).csv",
        metadata="scene_config_$(config_id).toml",
    )
    counts = Dict(name => 0 for name in (:leaves, :plants, :light))
    scenes = Dict{String,Any}[]
    rotations = get(scene_kwargs, :plant_rotations, nothing)

    mktempdir(output_dir; prefix=".config_$(config_id)_") do staging
        for (index, source) in enumerate(sources)
            @info "Simulating growth period" config_id day=source.day progress="$index/$(length(sources))"
            daily_meteo = TableOperations.filter(row -> Date(Tables.getcolumn(row, :date)) == source.day, meteo) |>
                rows -> TimeStepTable(rows, PlantMeteo.metadata(meteo))
            kwargs = merge(scene_kwargs, (
                obj_path=source.obj_path, mtg_path=source.mtg_path, plant_rotations=rotations,
            ))
            result = day_simulation(; pvconfig, day=source.day, meteo=daily_meteo,
                keep_leaves, keep_light, scene_kwargs=kwargs)
            recipe = deepcopy(result.scene.mtg[:agripv_scene_recipe])
            rotations = recipe["plant_rotations_rad"]
            for family in ("obj", "mtg")
                path = recipe[family * "_path"]
                _agripv_saved_file_sha256(path) == recipe[family * "_sha256"] ||
                    throw(ArgumentError("Plant source changed during simulation: $path"))
                recipe[family * "_path"] = relpath(path, _agripv_project_root())
            end
            push!(scenes, Dict("scene" => recipe,
                "scene_sha256" => agripv_scene_fingerprint(result.scene)))
            for name in (:leaves, :plants, :light)
                table = getproperty(result, name)
                ncol(table) == 0 && continue
                table.day = fill(source.day, nrow(table))
                table.config_id = fill(config_id, nrow(table))
                path = joinpath(staging, getproperty(filenames, name))
                CSV.write(path, table; append=isfile(path))
                counts[name] += nrow(table)
            end
            # Release model state and daily outputs before the next scene.
            result = nothing
            table = nothing
        end
        tables = Dict{String,Any}()
        for name in (:leaves, :plants, :light)
            filename = getproperty(filenames, name)
            path = joinpath(staging, filename)
            isfile(path) || continue
            tables[string(name)] = Dict("file" => filename, "rows" => counts[name],
                "sha256" => _agripv_saved_file_sha256(path))
        end
        metadata = Dict(
            "format_version" => 1, "simulation" => "growth_period",
            "config_id" => config_id, "days" => string.(dates),
            "identity_scope" => "day", "cumulative_scope" => "day",
            "plant_instance_identity_scope" => "configuration",
            "scenes" => scenes, "tables" => tables,
        )
        open(joinpath(staging, filenames.metadata), "w") do io
            TOML.print(io, metadata)
        end
        for name in (:leaves, :plants, :light, :metadata)
            path = joinpath(staging, getproperty(filenames, name))
            destination = joinpath(output_dir, getproperty(filenames, name))
            if isfile(path)
                mv(path, destination; force=true)
            elseif isfile(destination)
                rm(destination) # A rerun may deliberately omit leaves/light.
            end
        end
    end
    paths = (; (name => (name == :metadata || isfile(joinpath(output_dir, getproperty(filenames, name))) ?
        joinpath(output_dir, getproperty(filenames, name)) : nothing)
        for name in (:leaves, :plants, :light, :metadata))...)
    return (; paths, days=dates, rows=(; counts...))
end

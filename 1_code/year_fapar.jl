using CSV, DataFrames, Dates, TOML, SHA
using PlantMeteo, ArchimedLight, TableOperations, PlantMeteo.Tables

isdefined(@__MODULE__, :_agripv_open_light) || include("light_output_io.jl")

isdefined(@__MODULE__, :archimed_meteo) || include("meteo.jl")

_fapar_project_root() = normpath(joinpath(@__DIR__, ".."))

function _year_fapar_forcing(metadata)
    days = Date.(metadata["days"])
    configs = [entry["scene"]["config"] for entry in metadata["scenes"]]
    all(==(first(configs)), configs) || throw(ArgumentError("The PV configuration changes within this file."))
    # Match prepare_day_simulation's sky preparation; no radiation is rerun.
    options = LightOptions(turtle_sectors=46, pixel_size=0.01, toricity=true,
        scattering=true, cache_radiation=true, all_in_turtle=true,
        include_sky_fraction=true, scene_rotation_deg=first(configs)["panel_orientation"])
    return archimed_meteo(get_meteo(days), options)
end

function _fapar_accumulate!(absorbed, counts, lookup, expected_steps, config_id,
    datetime, day, timestep, row_config, plant_id, scale, ra_par, area)
    for row in eachindex(datetime)
        stamp = datetime[row]
        ismissing(stamp) && throw(ArgumentError("Missing datetime in light results."))
        index = get(lookup, stamp, 0)
        index > 0 || throw(ArgumentError("No incoming forcing for light timestamp $stamp."))
        (isnothing(day) || isequal(day[row], Date(stamp))) &&
            (isnothing(timestep) || isequal(timestep[row], expected_steps[index])) &&
            (isnothing(row_config) || isequal(row_config[row], config_id)) || throw(ArgumentError("Inconsistent light date, timestep or configuration at $stamp."))
        flux, surface = ra_par[row], area[row]
        !ismissing(flux) && !ismissing(surface) && isfinite(flux) && isfinite(surface) &&
            flux >= 0 && surface >= 0 || throw(ArgumentError("Invalid Ra_PAR_f or area at $stamp."))
        group = if !ismissing(plant_id[row])
            1 # All plant geometry, including stems and senescent sections.
        elseif ismissing(scale[row])
            throw(ArgumentError("Missing scale on non-plant geometry at $stamp."))
        elseif scale[row] == "Panel"
            2
        elseif scale[row] == "Cobblestone"
            3
        else
            throw(ArgumentError("Unclassified non-plant light geometry: $(scale[row])."))
        end
        absorbed[group, index] += flux * surface # W; duration applied once below.
        counts[group, index] += 1
    end
    return nothing
end

"""
    summarize_year_fapar(; config_id, input_dir=..., batch_bytes=32*1024^2,
        forcing=nothing, verify_hash=true)

Read compact `.csv.gz` or legacy `.csv` light results in bounded byte batches.
Gzip is decompressed as a stream, including appended daily gzip members.
Require its `scene_config_ID.toml` sidecar. Return small `hourly` and `daily`
DataFrames, plus row count and source SHA256. No full-file read or memory map
is used. The generated light CSV has one record per physical line.

Absorbed PAR energy is `Ra_PAR_f * area * duration_s`. Plants include all
geometry with a plant ancestor, panels are `Panel`, and ground is `Cobblestone`.
Unknown geometry, invalid values and incomplete timestamp coverage are errors.
Sky incoming energy is prepared climate `Ri_PAR_f * horizontal_domain_area *
duration_s`, using the saved configuration and the same sky preparation as the
simulation. The organ-level `Ri_PAR_f` in the light CSV is not the denominator.

`forcing` may supply the exact prepared forcing used for the run (columns
`date`, `duration`, `Ri_PAR_f`). Otherwise the project's climate and current
sky preparation must match the original simulation. No geometry or physics is
rerun. Daily fractions divide summed energies, rather than averaging hourly
fractions. Dark hourly fractions are `missing`. Values are not clipped or
renormalized; `nonabsorbed_fraction = 1 - fapar_total` includes escaping PAR and
numerical residuals. The source hash covers the stored file bytes (compressed bytes for gzip).
A separate bounded hash pass avoids retaining compressed data in memory.
"""
function summarize_year_fapar(; config_id,
    input_dir=joinpath(_fapar_project_root(), "2_outputs", "simulations", "yearly"),
    batch_bytes=32*1024^2, forcing=nothing, verify_hash=true)
    batch_bytes isa Integer && batch_bytes > 0 || throw(ArgumentError("batch_bytes must be a positive integer."))
    input_dir = abspath(input_dir)
    metadata = TOML.parsefile(joinpath(input_dir, "scene_config_$(config_id).toml"))
    get(metadata, "simulation", nothing) == "growth_period" && metadata["config_id"] == config_id ||
        throw(ArgumentError("Expected growth-period metadata for configuration $config_id."))
    light_info = get(metadata["tables"], "light", nothing)
    isnothing(light_info) && throw(ArgumentError("This simulation did not retain light outputs."))
    path = joinpath(input_dir, light_info["file"])
    areas = Dict{Date,Float64}()
    for entry in metadata["scenes"]
        recipe = entry["scene"]
        day = Date(recipe["day"])
        haskey(areas, day) && throw(ArgumentError("Duplicate saved scene date $day."))
        config = recipe["config"]
        surface = config["panel_x_distance"] * config["panel_y_distance"]
        isfinite(surface) && surface > 0 || throw(ArgumentError("Invalid scene domain area."))
        areas[day] = surface
    end
    Set(keys(areas)) == Set(Date.(metadata["days"])) || throw(ArgumentError("Saved scene dates differ from period dates."))
    forcing = isnothing(forcing) ? _year_fapar_forcing(metadata) : forcing
    rows = sort!(collect(Tables.rows(forcing)); by=row -> DateTime(row.date))
    isempty(rows) && throw(ArgumentError("Incoming forcing is empty."))
    stamps = DateTime[row.date for row in rows]
    allunique(stamps) || throw(ArgumentError("Repeated incoming forcing timestamps."))
    all(stamp -> haskey(areas, Date(stamp)), stamps) || throw(ArgumentError("Forcing dates differ from the saved period."))
    Set(Date.(stamps)) == Set(keys(areas)) || throw(ArgumentError("Missing forcing for saved scene dates."))
    seconds = Float64[row.duration isa Real ? row.duration : Dates.toms(row.duration) / 1000 for row in rows]
    sky = Float64[row.Ri_PAR_f for row in rows]
    all(x -> isfinite(x) && x > 0, seconds) && all(x -> isfinite(x) && x >= 0, sky) ||
        throw(ArgumentError("Invalid incoming PAR or timestep duration."))
    incoming = [sky[i] * seconds[i] * areas[Date(stamps[i])] for i in eachindex(stamps)]
    lookup = Dict(stamp => i for (i, stamp) in enumerate(stamps))
    expected_steps = Int[]
    previous_day = nothing
    step = 0
    for stamp in stamps
        day = Date(stamp)
        step = day == previous_day ? step + 1 : 1
        push!(expected_steps, step)
        previous_day = day
    end
    absorbed = zeros(3, length(stamps))
    counts = zeros(Int, 3, length(stamps))
    selected = [:datetime, :day, :timestep, :config_id, :plant_id, :scale, :Ra_PAR_f, :area]
    types = Dict(:datetime => DateTime, :day => Date, :timestep => Int,
        :config_id => Int, :plant_id => Int, :scale => String, :Ra_PAR_f => Float64, :area => Float64)
    required = [:datetime, :plant_id, :scale, :Ra_PAR_f, :area]
    nrows = 0
    last_report = time()
    _agripv_open_light(path) do io
        header = readline(io; keep=true)
        names = Symbol.(split(chomp(header), ','))
        isempty(setdiff(required, names)) || throw(ArgumentError("Light CSV is missing required columns $required."))
        selected = intersect(selected, names)
        batch_types = Dict(name => types[name] for name in selected)
        while !eof(io)
            buffer = IOBuffer(; sizehint=batch_bytes)
            while position(buffer) < batch_bytes && !eof(io)
                copyline(buffer, io; keep=true)
            end
            bytes = take!(buffer)
            table = CSV.File(bytes; header=names, select=selected, types=batch_types,
                ntasks=1, strict=true, pool=true)
            _fapar_accumulate!(absorbed, counts, lookup, expected_steps, config_id,
                table.datetime, :day in selected ? table.day : nothing,
                :timestep in selected ? table.timestep : nothing,
                :config_id in selected ? table.config_id : nothing,
                table.plant_id, table.scale, table.Ra_PAR_f, table.area)
            nrows += length(table)
            table = nothing
            if time() - last_report >= 20
                @info "Reading yearly light CSV" config_id rows=nrows
                last_report = time()
            end
        end
    end
    source_sha256 = bytes2hex(open(SHA.sha256, path))
    verify_hash && source_sha256 != light_info["sha256"] && throw(ArgumentError("Light CSV hash differs from the saved simulation."))
    nrows == light_info["rows"] || throw(ArgumentError("Light CSV row count differs from its saved metadata."))
    all(>(0), vec(sum(counts; dims=1))) || throw(ArgumentError("Some forcing timesteps have no light rows."))
    hourly = DataFrame(config_id=fill(config_id, length(stamps)), day=Date.(stamps),
        datetime=stamps, timestep=expected_steps, duration_s=seconds, incoming_PAR_J=incoming)
    for (index, group) in enumerate((:plants, :panels, :ground))
        hourly[!, Symbol("apar_$(group)_J")] = absorbed[index, :] .* seconds
        hourly[!, Symbol("rows_$(group)")] = counts[index, :]
    end
    hourly.apar_total_J = hourly.apar_plants_J .+ hourly.apar_panels_J .+ hourly.apar_ground_J
    daily = combine(groupby(hourly, [:config_id, :day]),
        [:incoming_PAR_J, :apar_plants_J, :apar_panels_J, :apar_ground_J, :apar_total_J] .=> sum .=>
            [:incoming_PAR_J, :apar_plants_J, :apar_panels_J, :apar_ground_J, :apar_total_J])
    for table in (hourly, daily)
        for group in (:plants, :panels, :ground, :total)
            table[!, Symbol("fapar_$(group)")] = Union{Missing,Float64}[
                input > 0 ? absorbed / input : missing for (absorbed, input) in
                zip(table[!, Symbol("apar_$(group)_J")], table.incoming_PAR_J)]
        end
        table.nonabsorbed_fraction = 1 .- table.fapar_total
    end
    return (; hourly, daily, rows=nrows, source_sha256)
end

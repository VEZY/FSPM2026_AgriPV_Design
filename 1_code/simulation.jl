include("meteo.jl")
include("scene.jl")

function day_simulation(; pvconfig, day)
    models = agripv_models()
    @time scene = agripv_scene(
        c=pvconfig,
        day=day
    )

    options = LightOptions(
        turtle_sectors=46,
        pixel_size=0.01,
        toricity=true,
        scattering=true,
        cache_radiation=true,
        all_in_turtle=true,
        include_sky_fraction=true,
        scene_rotation_deg=pvconfig.panel_orientation
    )

    # Take only the desired day:
    meteo_rows = get_meteo(day)
    meteo = prepare_meteo(meteo_rows, options)

    sim = LightSimulation(scene, models; options=options)

    @time series = run_light(sim, meteo)

    return sim, series
end

# map = (
#     Ri_PAR_0_f=(:incident_flux, :initial, :par),
#     Ri_NIR_0_f=(:incident_flux, :initial, :nir),
#     Ri_PAR_f=(:incident_flux, :total, :par),
#     Ri_NIR_f=(:incident_flux, :total, :nir),
#     Ri_PAR_0_q=(:incident_energy, :initial, :par),
#     Ri_NIR_0_q=(:incident_energy, :initial, :nir),
#     Ri_PAR_q=(:incident_energy, :total, :par),
#     Ri_NIR_q=(:incident_energy, :total, :nir),
#     Ra_PAR_0_f=(:absorbed_flux, :initial, :par),
#     Ra_NIR_0_f=(:absorbed_flux, :initial, :nir),
#     Ra_PAR_f=(:absorbed_flux, :total, :par),
#     Ra_NIR_f=(:absorbed_flux, :total, :nir),
#     Ra_PAR_0_q=(:absorbed_energy, :initial, :par),
#     Ra_NIR_0_q=(:absorbed_energy, :initial, :nir),
#     Ra_PAR_q=(:absorbed_energy, :total, :par),
#     Ra_NIR_q=(:absorbed_energy, :total, :nir),
# )

function read_component_values(; csv_path)
    component_values = CSV.read(csv_path, DataFrame; delim=(';'))
    sdf = filter(:type => ==("LeafSection"), component_values)
    # sdf = filter(:step_number => ==(1), component_values)
    values_dict = Dict(Int(i) => Float64(v) for (i, v) in zip(sdf.node_id, sdf.Ra_PAR_q))

    return values_dict
end

function read_aPAR_from_component_values(; csv_path)
    component_values = CSV.read(csv_path, DataFrame; delim=(';'))
    df = filter(:group => ==("wheat"), component_values)
    values_df = combine(groupby(df, [:step_number, :object_id]), :Ra_PAR_q => sum => :Ra_PAR_q_sum)

    return values_df
end
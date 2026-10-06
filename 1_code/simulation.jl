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
    # update_options!(
    #     sim,
    #     LightOptions(sim.options; scene_rotation_deg=config.panel_orientation),
    # )

    @time series = run_light(sim, meteo)

    # Attach the results to the MTG for visualization:
    # attach_light_series!(
    #     scene,
    #     series;
    #     fields=[:incident_par_flux, :absorbed_par_flux, :absorbed_par_energy, :absorbed_nir_flux, :absorbed_nir_energy, :sky_fraction, :area],
    # )

    # Adapting variables for PlantBiophysics :
    # MultiScaleTreeGraph.transform!(
    #     scene.mtg,
    #     [:Ra_PAR_f, :Ra_NIR_f] => ((x, y) -> x .+ y) => :Ra_SW_f,
    #     ignore_nothing=true
    # )

    # # Simulate energy balance and photosynthesis with PlantBiophysics::
    # vars = Dict{Symbol,Any}(:Leaf => (:Tₗ, :A, :Gₛ))
    # models =
    #     ModelMapping(
    #         "LeafSection" => (
    #             Translucent(), # This model reads ArchimedLight outputs one time-step at a time
    #             Monteith(),
    #             Fvcb(),
    #             Medlyn(0.03, 12.0),
    #             Status(d=0.01) #! update this with the true value in the MTG
    #         ),
    #     )
    # @time outs = PlantSimEngine.run!(scene.mtg, models, meteo, tracked_outputs=vars)
    # # Writing the outputs back to the MTG for visualization:
    # for ts_node in groupby(DataFrame(outs[:LeafSection]), :node)
    #     node = ts_node.node[1]
    #     node.Tₗ = ts_node.Tₗ
    #     node.A = ts_node.A
    #     node.A_per_organ = ts_node.A .* node.area
    #     node.Gₛ = ts_node.Gₛ
    # end

    # # Compute the absorbed PAR and A by each plant over the day, by summing the absorbed PAR energy of all the leaves of each plant at each timestep:
    # plant_df = let
    #     apar_plant = []
    #     assimilation_quantity_plant = [] # Assimilation in μmol per plant per timestep, i.e. A (μmol m⁻² s⁻¹) * leaf area (m²) * duration of the timestep (s)
    #     plan_index = []
    #     traverse!(scene.mtg) do node
    #         if symbol(node) == :Plant
    #             push!(apar_plant, [sum(leaf[timestep] for leaf in descendants(node, :Ra_PAR_q, symbol=:Leaf)) for timestep in 1:length(meteo)] * 1e-6) # Convert from J to MJ
    #             push!(assimilation_quantity_plant, [sum(leaf[timestep] for leaf in descendants(node, :A_per_organ, symbol=:Leaf)) * Dates.toms(r.duration) * 1e-3 for (timestep, r) in enumerate(meteo)])
    #             push!(plan_index, fill(node_id(node), length(meteo)))
    #         end
    #     end
    #     DataFrame(plant_id=vcat(plan_index...), date=repeat(meteo.date, outer=length(plan_index)), apar=vcat(apar_plant...), assimilation=vcat(assimilation_quantity_plant...))
    # end

    return sim, series#, plant_df
end

mapping = (
    Ri_PAR_0_f=(:incident_flux, :initial, :par),
    Ri_NIR_0_f=(:incident_flux, :initial, :nir),
    Ri_PAR_f=(:incident_flux, :total, :par),
    Ri_NIR_f=(:incident_flux, :total, :nir),
    Ri_PAR_0_q=(:incident_energy, :initial, :par),
    Ri_NIR_0_q=(:incident_energy, :initial, :nir),
    Ri_PAR_q=(:incident_energy, :total, :par),
    Ri_NIR_q=(:incident_energy, :total, :nir),
    Ra_PAR_0_f=(:absorbed_flux, :initial, :par),
    Ra_NIR_0_f=(:absorbed_flux, :initial, :nir),
    Ra_PAR_f=(:absorbed_flux, :total, :par),
    Ra_NIR_f=(:absorbed_flux, :total, :nir),
    Ra_PAR_0_q=(:absorbed_energy, :initial, :par),
    Ra_NIR_0_q=(:absorbed_energy, :initial, :nir),
    Ra_PAR_q=(:absorbed_energy, :total, :par),
    Ra_NIR_q=(:absorbed_energy, :total, :nir),
)

function read_component_values(; csv_path)
    component_values = CSV.read(csv_path, DataFrame; delim=(';'))
    sdf = filter(:step_number => ==(1), component_values)
    values_dict = Dict(Int(i) => Float64(v) for (i, v) in zip(sdf.node_id, sdf.Ri_PAR_f))

    return values_dict
end
using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using GLMakie
using ArchimedLight
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables
using AlgebraOfGraphics, DataFrames, Statistics, CSV
using PlantBiophysics, PlantSimEngine

function wheat_models()
    models_for(
        "wheat" => (
            "Stem" => translucent(par=0.15, nir=0.90),
            "Leaf" => translucent(par=0.15, nir=0.90),
        ),
        "panel" => (
            "Panel" => translucent(par=0.0, nir=0.0),
        ),
        "pavement" => (
            "Cobblestone" => translucent(par=0.12, nir=0.60),
        ),
    )
end

function wheat_scene(;
    plant_density=60.0,
    interrow=0.20,
    n_rows=2,
    panel_length=4.2,
    panel_inclination=25.0,
    panel_height=4.0,
    panel_y_distance=10.0,
)
    intrarow = 1.0 / (plant_density * interrow)
    plants_per_row = max(1, floor(Int, panel_y_distance / intrarow) - 1)
    panel_width = interrow * n_rows
    wheat_plant = read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
    panel = Agrivoltaics.Fixed(
        panel_dimensions=(panel_width, panel_length),
        inclination=panel_inclination,
        panel_height=panel_height,
    ) |> structure

    return PlantGeom.make_scene(domain=(0.0, 0.0, panel_width, panel_y_distance)) do s
        add_object!(s, panel; group="panel", type="Panel", id=1)

        for i in 1:(plants_per_row * n_rows)
            row = (i - 1) ÷ plants_per_row
            col = (i - 1) % plants_per_row
            add_plant!(
                s,
                wheat_plant;
                group="wheat",
                id=i + 1,
                at=((row + 0.5) * interrow, (col + 0.5) * intrarow, 0.0),
                rotate=(z=randn() * 5.0,),
                deg=true,
            )
        end

        add_ground!(s; nx=60, ny=60, group="pavement", type="Cobblestone")
    end
end

models = wheat_models()

# meteo = CSV.read("0_simulations/meteo/meteo_data_2025_montpellier.csv", DataFrame)
meteo = read_weather("0_simulations/meteo/meteo_data_2025_montpellier.csv", duration=x -> Hour(1));
# Take only one day near the harvest:
# filter!(row -> row.timestamp > DateTime(2025, 6, 24) && row.timestamp <= DateTime(2025, 6, 25), meteo)
# meteo_rows = TableOperations.filter(x -> DateTime(2025, 6, 24) < Tables.getcolumn(x, :date) <= DateTime(2025, 6, 25), meteo) |> Tables.rowtable
meteo_rows = TableOperations.filter(x -> Date(2025, 6, 25) == Date(Tables.getcolumn(x, :date)), meteo) |> TimeStepTable;

options = LightOptions(
    # turtle_sectors=46,
    turtle_sectors=16,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
    cache_radiation=true,
    all_in_turtle=true,
    include_sky_fraction=true,
)

row = prepare_meteo(meteo_rows, options);

function make_simulation(; panel_length=4.2, panel_inclination=25.0, models, meteo, options)
    n_rows = 2
    interrow = 0.20
    scene = wheat_scene(
        plant_density=60.0,
        interrow=interrow,
        n_rows=n_rows,
        panel_length=panel_length,
        panel_inclination=panel_inclination,
        panel_height=4.0,
        panel_y_distance=10.0,
    )
    # f, ax, p = plantviz(scene_ref.mtg, figure=(size=(1080, 720),))
    sim = LightSimulation(scene, models; options=options)
    series = run_light(sim, meteo)

    # Attach the results to the MTG for visualization:
    attach_light_series!(
        scene,
        series;
        fields=[:incident_par_flux, :absorbed_par_flux, :absorbed_par_energy, :absorbed_nir_flux, :absorbed_nir_energy, :sky_fraction, :area],
    )

    # Adapting variables for PlantBiophysics :
    MultiScaleTreeGraph.transform!(
        scene.mtg,
        [:Ra_PAR_f, :Ra_NIR_f] => ((x, y) -> x .+ y) => :Ra_SW_f,
        ignore_nothing=true
    )

    # Simulate energy balance and photosynthesis with PlantBiophysics::
    vars = Dict{Symbol,Any}(:Leaf => (:Tₗ, :A, :Gₛ))
    models =
        ModelMapping(
            "Leaf" => (
                Translucent(), # This model reads ArchimedLight outputs one time-step at a time
                Monteith(),
                Fvcb(),
                Medlyn(0.03, 12.0),
                Status(d=0.01) #! update this with the true value in the MTG
            ),
        )
    outs = PlantSimEngine.run!(scene.mtg, models, meteo, tracked_outputs=vars)
    # Writing the outputs back to the MTG for visualization:
    for ts_node in groupby(DataFrame(outs[:Leaf]), :node)
        node = ts_node.node[1]
        node.Tₗ = ts_node.Tₗ
        node.A = ts_node.A
        node.A_per_organ = ts_node.A .* node.area
        node.Gₛ = ts_node.Gₛ
    end

    # Compute the absorbed PAR and A by each plant over the day, by summing the absorbed PAR energy of all the leaves of each plant at each timestep:
    plant_df = let
        apar_plant = []
        assimilation_quantity_plant = [] # Assimilation in μmol per plant per timestep, i.e. A (μmol m⁻² s⁻¹) * leaf area (m²) * duration of the timestep (s)
        plan_index = []
        traverse!(scene.mtg) do node
            if symbol(node) == :Plant
                push!(apar_plant, [sum(leaf[timestep] for leaf in descendants(node, :Ra_PAR_q, symbol=:Leaf)) for timestep in 1:length(meteo)] * 1e-6) # Convert from J to MJ
                push!(assimilation_quantity_plant, [sum(leaf[timestep] for leaf in descendants(node, :A_per_organ, symbol=:Leaf)) * Dates.toms(r.duration) * 1e-3 for (timestep, r) in enumerate(meteo)])
                push!(plan_index, fill(node_id(node), length(meteo)))
            end
        end
        DataFrame(plant_id=vcat(plan_index...), date=repeat(meteo.date, outer=length(plan_index)), apar=vcat(apar_plant...), assimilation=vcat(assimilation_quantity_plant...))
    end

    return scene, series, plant_df
end

scene_ref, series_ref, plant_df_ref = make_simulation(panel_length=4.2, panel_inclination=25.0, models=models, meteo=row, options=options)
# Same GCR, different structure:
scene_0, series_0, plant_df_0 = make_simulation(panel_length=3.8, panel_inclination=0.0, models=models, meteo=row, options=options)

# Make the plot with the incident PAR on the tiled geometry of the noon timestep,
# and an inset with the plant geometry colored in green,
# and the daily absorbed PAR by the crop:
wheat_plant = read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
# tiled_ref = ArchimedLight.tile_light_geometry(scene_ref, series_ref; nx=40, ny=3)
# tiled_0 = ArchimedLight.tile_light_geometry(scene_0, series_0; nx=40, ny=3)
tiled_ref = ArchimedLight.tile_light_geometry(scene_ref, series_ref; nx=1, ny=1)
tiled_0 = ArchimedLight.tile_light_geometry(scene_0, series_0; nx=1, ny=1)

begin
    f = Figure(size=(900, 700))
    ax1 = Axis3(
        f[1:2, 1:2],
        aspect=:data,
        title="A. Incident PAR at 12:00 on design 1",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0,
    )
    p = ArchimedLight.lightplot!(ax1, tiled_ref, series_ref; color=:Ri_PAR_f, colormap=:thermal, timestep=12)

    ax2 = Axis3(
        f[1:2, 3:4],
        aspect=:data,
        title="B. Incident PAR at 12:00 on design 2",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0
    )
    zlims!(ax2, zmin(scene_ref.mtg), zmax(scene_ref.mtg)) # Set the same z limits for both plots to make them comparable
    p = ArchimedLight.lightplot!(ax2, tiled_0, series_0; color=:Ri_PAR_f, colormap=:thermal, timestep=12)

    # Plant alone:
    ax_3 = Axis3(
        f[3, 1:2],
        aspect=:data,
        title="C. Individual wheat plant",
        xticks=[-0.2, 0.2],
        yticks=[-0.2, 0.2],
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
    )

    plantviz!(
        ax_3,
        wheat_plant;
        color=:green,
    )

    Colorbar(f[1:2, 5], p, label="Incident PAR (W m⁻²)")

    ax4 = Axis(f[3, 3:5], title="D. Assimilation per plant over the day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)", xticks=0:2:24)
    plt = data(plant_df_ref) *
          mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation, group=:plant_id) *
          visual(Lines, alpha=0.05)
    plant_df_ref_avg = combine(groupby(plant_df_ref, :date), :assimilation => mean => :assimilation_mean)
    plt_avg = data(plant_df_ref_avg) *
              mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
              visual(Lines, color=:red, linewidth=3)
    plt_0 = data(plant_df_0) *
            mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation, group=:plant_id) *
            visual(Lines, alpha=0.05, color=:black, linestyle=:dash)
    plant_df_0_avg = combine(groupby(plant_df_0, :date), :assimilation => mean => :assimilation_mean)
    plt_avg_0 = data(plant_df_0_avg) *
                mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
                visual(Lines, color=:red, linewidth=3, linestyle=:dash)

    draw!(ax4, plt + plt_0 + plt_avg + plt_avg_0)
    # draw!(ax4, plt)

    # hidedecorations!(ax_inset)
    f
end
save("2_outputs/daily_apar_crop_3d.png", f, update=false, px_per_unit=3.0)


CSV.write("2_outputs/daily_apar_crop_horizontal_design.csv", plant_df_0)
CSV.write("2_outputs/daily_apar_crop_tilted_design.csv", plant_df_ref)

plant_df_0 = CSV.read("2_outputs/daily_apar_crop_horizontal_design.csv", DataFrame)
plant_df_ref = CSV.read("2_outputs/daily_apar_crop_tilted_design.csv", DataFrame)

apar_sum_plant_0 = combine(groupby(plant_df_0, :plant_id), :apar => sum => :apar_sum)
apar_sum_plant_ref = combine(groupby(plant_df_ref, :plant_id), :apar => sum => :apar_sum)
minimum(apar_sum_plant_0.apar_sum), maximum(apar_sum_plant_0.apar_sum), mean(apar_sum_plant_0.apar_sum)
minimum(apar_sum_plant_ref.apar_sum), maximum(apar_sum_plant_ref.apar_sum), mean(apar_sum_plant_ref.apar_sum)

minimum(apar_sum_plant_0.apar_sum) / maximum(apar_sum_plant_0.apar_sum)


plant_df_0_avg = combine(groupby(plant_df_0, :date), :apar => mean => :apar_mean)
plant_df_ref_avg = combine(groupby(plant_df_ref, :date), :apar => mean => :apar_mean)

horizontal_design_compared_to_ref = (sum(plant_df_0_avg.apar_mean) / sum(plant_df_ref_avg.apar_mean) * 100) - 100

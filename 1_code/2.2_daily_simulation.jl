using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using OrderedCollections: OrderedDict
using PlantGeom # For the growth and visualization API
using GLMakie
using ArchimedLight
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables
using AlgebraOfGraphics, DataFrames, Statistics

# Add custome module:
includet("0_make_scene.jl") # Requires Revise to be installed. Else, remove the "t" in includet and re-run the code after editing 0_make_scene.jl to see the changes.
using .MakeScene

models = MakeScene.models("wheat")

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
)

row = prepare_meteo(meteo_rows, options);

function make_simulation(; panel_length=4.2, panel_inclination=25.0, models, meteo, options)
    n_rows = 2
    interrow = 0.20
    panel_width = interrow * n_rows
    scene = MakeScene.make_scene(
        plant_density=60.0, interrow=interrow, n_rows=n_rows, panel_dimensions=(panel_width, panel_length),
        panel_y_distance=10.0, panel_inclination=panel_inclination, panel_height=4.00, type="wheat"
    )
    # f, ax, p = plantviz(scene_ref.mtg, figure=(size=(1080, 720),))
    @time series_ref = run_light_series(scene, models, meteo, options)

    # Attach the results to the MTG for visualization:
    attach_light_series!(scene, series_ref; fields=[:incident_par_flux, :absorbed_par_energy, :absorbed_par_flux])

    plant_absorbed_par_energy = descendants(scene.mtg, :Ra_PAR_q, symbol=:Leaf)

    # Compute the absorbed PAR by the crop over the day, by summing the absorbed PAR energy of all the leaves at each timestep:
    apar_crop = [sum(leaf[timestep] for leaf in plant_absorbed_par_energy) for timestep in 1:length(meteo)] * 1e-6 # Convert from J to MJ

    # Compute the absorbed PAR by each plant over the day, by summing the absorbed PAR energy of all the leaves of each plant at each timestep:
    plant_df = let
        apar_plant = []
        plan_index = []
        traverse!(scene.mtg) do node
            if symbol(node) == :Plant
                push!(apar_plant, [sum(leaf[timestep] for leaf in descendants(node, :Ra_PAR_q, symbol=:Leaf)) for timestep in 1:length(meteo)] * 1e-6) # Convert from J to MJ
                push!(plan_index, fill(node_id(node), length(meteo)))
            end
        end
        DataFrame(plant_id=vcat(plan_index...), date=repeat(meteo.date, outer=length(plan_index)), apar=vcat(apar_plant...))
    end

    return scene, series_ref, plant_df
end

scene_ref, series_ref, plant_df_ref = make_simulation(panel_length=4.2, panel_inclination=25.0, models=models, meteo=row, options=options)
# Same GCR, different structure:
scene_0, series_0, plant_df_0 = make_simulation(panel_length=3.8, panel_inclination=0.0, models=models, meteo=row, options=options)

# Make the plot with the incident PAR on the tiled geometry of the noon timestep,
# and an inset with the plant geometry colored in green,
# and the daily absorbed PAR by the crop:

wheat_plant = read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
tiled_ref = ArchimedLight.tile_light_geometry(scene_ref, series_ref; nx=40, ny=3)
tiled_0 = ArchimedLight.tile_light_geometry(scene_0, series_0; nx=40, ny=3)

begin
    f = Figure(size=(900, 700))
    ax1 = Axis3(
        f[1:2, 1:2],
        aspect=:data,
        title="A. Incident PAR at 12:00 on design 1",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0
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
    p = ArchimedLight.lightplot!(ax2, tiled_0, series_0; color=:Ri_PAR_f, colormap=:thermal, timestep=12)

    # Plant alone:
    ax_3 = Axis3(
        f[3, 1:2],
        aspect=:data,
        title="Individual wheat plant",
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

    ax4 = Axis(f[3, 2:3], title="aPAR per plant over the day", xlabel="Time of day", ylabel="aPAR (MJ m⁻²)")
    plt = data(plant_df_ref) *
          mapping(:date => (x -> Hour(x).value) => "Hour", :apar, group=:plant_id) *
          visual(Lines, alpha=0.05)
    plant_df_ref_avg = combine(groupby(plant_df_ref, :date), :apar => mean => :apar_mean)
    plt_avg = data(plant_df_ref_avg) *
              mapping(:date => (x -> Hour(x).value) => "Hour", :apar_mean) *
              visual(Lines, color=:black, linewidth=3)
    plt_0 = data(plant_df_0) *
            mapping(:date => (x -> Hour(x).value) => "Hour", :apar, group=:plant_id) *
            visual(Lines, alpha=0.05, color=:blue)
    plant_df_0_avg = combine(groupby(plant_df_0, :date), :apar => mean => :apar_mean)
    plt_avg_0 = data(plant_df_0_avg) *
                mapping(:date => (x -> Hour(x).value) => "Hour", :apar_mean) *
                visual(Lines, color=:blue, linewidth=3)

    draw!(ax4, plt + plt_0 + plt_avg + plt_avg_0)
    # draw!(ax4, plt)

    # hidedecorations!(ax_inset)
    f
end
save("2_outputs/daily_apar_crop_3d.png", f, update=false, px_per_unit=3.0)
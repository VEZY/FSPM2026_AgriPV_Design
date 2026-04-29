using ArchimedLight
using PlantGeom
using GLMakie
using MultiScaleTreeGraph
using GeometryBasics
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables

# Add custome module:
includet("0_make_scene.jl") # Requires Revise to be installed. Else, remove the "t" in includet and re-run the code after editing 0_make_scene.jl to see the changes.
using .MakeScene


plant_density = 60.0
interrow = 0.20
intrarow = 1.0 / (plant_density * interrow)
plant_file = "0_simulations/archimed/objects/scene1_plant1_1.opf"
plant_type = "wheat"


plant_mtg = read_opf(plant_file, mtg_type=NodeMTG)
plant_mtg[:functional_group] = plant_type

# Make the scene node:
scene_mtg = Node(NodeMTG(:/, :Scene, 1, 1))
# Set scene dimensions
scene_mtg.scene_dimensions = (
    Point3(0.0, 0.0, 0.0),
    Point3(interrow, intrarow, 0.0)
)

pmin, pmax = scene_mtg.scene_dimensions

plant = deepcopy(plant_mtg)
place_in_scene!(
    plant;
    scene=scene_mtg,
    scene_id=1,
    plant_id=2,
    functional_group=plant_mtg[:functional_group],
    pos=( (pmin[1]+pmax[1])/2 , (pmin[2]+pmax[2])/2, pmin[3] ), # (x, y, z) position of the plant in the scene
    rebind_scene=false,
    # rotation=rot_plant,
)
MultiScaleTreeGraph.columnarize!(scene_mtg)

scene = prepare_scene(scene_mtg)
add_ground!(
    scene;
    nx=60,
    ny=60,
    # xy_bounds=(0.0, 0.0, 1.0, 10.0),
    group="pavement",
    type="Cobblestone",
)

# plantviz(scene.mtg, figure=(size=(820, 560),))

models = MakeScene.models("wheat")

meteo = read_weather("0_simulations/meteo/meteo_data_2025_montpellier.csv", duration=x -> Hour(1));
meteo_rows = TableOperations.filter(x -> Date(2025, 6, 25) == Date(Tables.getcolumn(x, :date)), meteo) |> TimeStepTable;

options = LightOptions(
    # turtle_sectors=46,
    turtle_sectors=8,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
    cache_radiation=true,
    all_in_turtle=true,
)

row = prepare_meteo(meteo_rows, options);



function make_simulation(; models, meteo, options)
    # f, ax, p = plantviz(scene_ref.mtg, figure=(size=(1080, 720),))
    @time series_ref = run_light_series(scene, models, meteo, options)

    # Attach the results to the MTG for visualization:
    attach_light_series!(scene, series_ref; fields=[:incident_par_flux, :absorbed_par_energy, :absorbed_par_flux])

    # Compute the absorbed PAR by each plant over the day, by summing the absorbed PAR energy of all the leaves of each plant at each timestep:
    # plant_df = let
    #     apar_plant = []
    #     plan_index = []
    #     traverse!(scene.mtg) do node
    #         if symbol(node) == :Plant
    #             push!(apar_plant, [sum(leaf[timestep] for leaf in descendants(node, :Ra_PAR_q, symbol=:Leaf)) for timestep in 1:length(meteo)] * 1e-6) # Convert from J to MJ
    #             push!(plan_index, fill(node_id(node), length(meteo)))
    #         end
    #     end
    #     DataFrame(plant_id=vcat(plan_index...), date=repeat(meteo.date, outer=length(plan_index)), apar=vcat(apar_plant...))
    # end

    return scene, series_ref    #, plant_df
end

# scene_ref, series_ref, plant_df_ref = make_simulation(models=models, meteo=row, options=options)
scene_ref, series_ref = make_simulation(models=models, meteo=row, options=options)
tiled_ref = ArchimedLight.tile_light_geometry(scene_ref, series_ref; nx=1, ny=1)

begin
    f = Figure(size=(900, 700))
    ax1 = Axis3(
        f[1:2, 1],
        aspect=:data,
        title="A. Incident PAR at 12:00 on design 1",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0,
    )
    p = ArchimedLight.lightplot!(ax1, tiled_ref, series_ref; color=:Ri_PAR_f, colormap=:thermal, timestep=12)

    Colorbar(f[1:2, 2], p, label="Incident PAR (W m⁻²)")
    
    f
end
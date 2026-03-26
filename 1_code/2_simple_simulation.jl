using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using OrderedCollections: OrderedDict
using PlantGeom # For the growth and visualization API
using GLMakie
using ArchimedLight

function make_simple_plant()
    # Defining the reference meshes for the plant components (stem and leaf) and their prototypes:
    stem_ref = RefMesh(
        "stem",
        GeometryBasics.mesh(
            GeometryBasics.Cylinder(
                Point(0.0, 0.0, 0.0),
                Point(1.0, 0.0, 0.0),
                0.5,
            ),
        ),
        RGB(0.48, 0.36, 0.25),
    )

    leaf_ref = lamina_refmesh(
        "leaf";
        length=1.0,
        max_width=1.0,
        n_long=36,
        n_half=7,
        material=RGB(0.19, 0.61, 0.29),
    )

    prototypes = Dict(
        :Internode => RefMeshPrototype(stem_ref, true),
        :Leaf => PointMapPrototype(
            leaf_ref;
            defaults=(base_angle_deg=42.0, bend=0.30, tip_drop=0.08),
            intrinsic_shape=params -> LaminaMidribMap(
                base_angle_deg=params.base_angle_deg,
                bend=params.bend,
                tip_drop=params.tip_drop,
            ),
        ),
    )

    # Defining the plant:
    small_plant = Node(NodeMTG(:/, :Plant, 1, 1))

    first_phy = emit_phytomer!(
        small_plant;
        internode=(link=:/, index=1, length=0.20, width=0.022),
        leaf=(index=1, offset=0.15, length=0.22, width=0.05, thickness=0.02, y_insertion_angle=52.0),
    )

    emit_phytomer!(
        first_phy.internode;
        internode=(index=2, length=0.18, width=0.020),
        leaf=(index=2, offset=0.14, length=0.24, width=0.055, thickness=0.02, phyllotaxy=180.0, y_insertion_angle=54.0),
    )

    rebuild_geometry!(small_plant, prototypes)

    return small_plant
end

# Read the solar panel:
# panel = read_opf("0_simulations/archimed/objects/panel.opf", mtg_type=NodeMTG)
panel = Agrivoltaics.Fixed(panel_dimensions=(1.0, 4.2), inclination=25.0, panel_height=4.00) |> structure

# Make the plant:
small_plant = make_simple_plant()

# Make the scene node:
scene_mtg = Node(NodeMTG(:/, :Scene, 1, 1))

# Define scene dimensions (primary input)
# This includes margins around the plant stand
scene_width = 1.0      # m (total scene width including margins)
scene_height = 10.0      # m (total scene height including margins)

# Plant stand definition:
plant_density = 60.0   # plants m^-2
interrow = 0.20         # m between rows

# From density and interrow, derive in-row spacing.
intrarow = 1.0 / (plant_density * interrow)
# Calculate how many plants per row fit in the scene (accounting for one margin on each side)
plants_per_row = max(1, scene_width / intrarow)
# Calculate how many rows fit in the scene (accounting for one margin on each side)
n_rows = max(1, scene_height / interrow)
n_plants = plants_per_row * n_rows

# Set scene dimensions
scene_mtg.scene_dimensions = (
    Point3(0.0, 0.0, 0.0),
    Point3(scene_width, scene_height, 0.0)
)

# Place the solar panel in the scene:
place_in_scene!(
    panel;
    scene=scene_mtg,
    scene_id=1,
    plant_id=1,
    functional_group="panel",
    pos=(0.0, 0.0, 0.0),
    # scale=1.15,
    # rotation=-0.35,
    # inclination_angle=0.12,
)

# Place the plants in rows:
pmin, _ = scene_mtg.scene_dimensions
xmin, ymin, zmin = pmin[1], pmin[2], pmin[3]

for i in 1:n_plants
    col = (i - 1) % plants_per_row
    row = (i - 1) ÷ plants_per_row
    x = xmin + (col + 1) * intrarow
    y = ymin + (row + 1) * interrow

    rot_plant = randn() * 5.0  # Random rotation for visual interest

    plant = deepcopy(small_plant)
    place_in_scene!(
        plant;
        scene=scene_mtg,
        scene_id=1,
        plant_id=i + 1,
        functional_group="example_plant",
        pos=(x, y, zmin),
        rotation=rot_plant,
    )
end

f, ax, p = plantviz(scene_mtg, figure=(size=(1080, 720),))

save("2_outputs/simple_plant_scene.png", f, update=false, px_per_unit=3.0)

# Make the Archimed Light scene and add the ground:
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

models = prepare_models([
    GroupModel(
        "example_plant";
        types=OrderedDict(
            "Internode" => TypeModel(
                interception=InterceptionModel(
                    model="Translucent",
                    transparency=0.0,
                    optical_properties=OpticalProperties(0.15, 0.90),
                ),
            ),
            "Leaf" => TypeModel(
                interception=InterceptionModel(
                    model="Translucent",
                    transparency=0.0,
                    optical_properties=OpticalProperties(0.15, 0.90),
                ),
            ),
        ),
    ),
    GroupModel(
        "pavement";
        types=OrderedDict(
            "Cobblestone" => TypeModel(
                interception=InterceptionModel(
                    model="Translucent",
                    transparency=0.0,
                    optical_properties=OpticalProperties(0.12, 0.60),
                ),
            ),
        ),
    ),
    GroupModel(
        "panel";
        types=OrderedDict(
            "Panel" => TypeModel(
                interception=InterceptionModel(
                    model="Translucent",
                    transparency=0.0,
                    optical_properties=OpticalProperties(0.0, 0.0),
                ),
            ),
        ),
    ),
])

sky = SkyState(
    135.0,  # sun azimuth in degrees
    60.0,   # sun elevation in degrees
    350.0,  # PAR irradiance on horizontal ground, W m^-2
    250.0,  # NIR irradiance on horizontal ground, W m^-2
    0.60,   # direct fraction
    0.40,   # diffuse fraction
)

options = LightOptions(
    turtle_sectors=16,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
)

turtle = build_turtle(options, sky)
fluxes = compute_directional_fluxes(sky, turtle, options)
first = compute_first_order(scene, models, turtle, fluxes, options)
scat = compute_scattering(scene, models, turtle, first, options)
budget = integrate_light(scene, models, first, scat, options; step_duration_seconds=1800.0)

step = LightStepResult(sky, turtle, fluxes, first, scat, budget, Dict{String,Float64}())

# Attach the results to the MTG for visualization:
attach_light_step!(scene, step; fields=[:incident_par_flux, :absorbed_par_energy, :absorbed_par_flux])

# Make the plot:
begin
    f = Figure(size=(900, 700))
    # ax = Axis3(f[1, 1], azimuth=0.0)
    ax = Axis3(f[1, 1], aspect=:data, title="Incident PAR with a simple plant stand and a solar panel")
    p = plantviz!(
        ax,
        scene.mtg;
        color=:Ri_PAR_f,
        # color=:Ra_PAR_f,
        colormap=:thermal,
        color_missing=:gray85,
    )

    # ax.show_axis[] = false
    PlantGeom.colorbar(f[1, 2], p, label="Incident PAR (W m^-2)")
    f
end

save("2_outputs/simple_plant_scene_light_scat.png", f, update=false, px_per_unit=3.0)
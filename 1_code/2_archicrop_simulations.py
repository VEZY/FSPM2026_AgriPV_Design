# Imports
from openalea.archicrop.archicrop import ArchiCrop
from openalea.archicrop.stics_io import get_stics_data
from openalea.archicrop.simulation import define_params_1_plant
from openalea.archicrop.display import build_scene
from openalea.archicrop.export_mtg import save_mtg


# STICS files
tec_file='0_simulations/stics/wheat/neodur_tec.xml' # Path to the STICS management XML file
plant_file='0_simulations/stics/wheat/plant/DurumWheat_NEODUR_plt.xml' # Path to the STICS plant XML file
stics_output_file='0_simulations/stics/wheat/neodur_2025/mod_sneodur_2025.sti' # Path to the STICS output file

# Plant architecture and development parameters
archi_wheat = {
    "species": "wheat",

    "nb_phy": 10, # number of phytomers on the main stem 
    "nb_short_phy": 5, # number of short phytomers on the main stem (included in number of phytomers)
    "short_phy_len": 3, # length of short phytomers

    # Stem
    "height": 90, # potential plant height (modified when defining viable params)
    "stem_q": 1, # parameter for ligule height distribution along axis 
    "diam_base": 0.8, # stem base diameter 
    "diam_top": 0.3, # stem top diameter

    # Leaf area distribution along the axis
    "leaf_area": 1500, # potential plant leaf area (modified when defining viable params)
    "rmax": [0.5,1], # relative position of the largest leaf
    "skew": [-10,0], # parameter for leaf area distribution along axis 
    
    # blade area 
    "wl": 0.079, # leaf blade width-to-length ratio 
    "klig": 0.6, # parameter for leaf blade shape
    "swmax": 0.55, # parameter for leaf blade shape
    "f1": 0.64, # parameter for leaf blade shape
    "f2": 0.92, # parameter for leaf blade shape

    # Leaf blade position in space
    "insertion_angle": 40, # leaf blade insertion angle 
    "scurv": 0.7, # leaf blade relative inflexion point 
    "curvature": 140, # leaf blade insertion-to-tip angle
    "phyllotactic_angle": 180, # phyllotactic angle 
    "phyllotactic_deviation": 90, # half-deviation to phyllotactic angle 

    # Development
    "phyllochron": [20,60], # phyllochron, i.e. phytomer appearance rate 
    "leaf_duration": 1.6, # delay, as factor of phyllochron, between the appearance of two successive phytomers

    # Tillering
    "nb_tillers": 6, # number of tillers
    "tiller_angle": 5, # tiller insertion angle
    "tiller_delay": 1, # delay, as factor of phyllochron, between the appearance of a phytomer and the appearance of its tiller
    "reduction_factor": 0.8, # reduction factor between tillers of consecutive order
    "tropism_coefficient": 0.12 # tiller tropism, i.e. bending, coefficient
    }

# Retrieve daily crop growth dynamics and spatial configuration
density, daily_dynamics, _, _, inter_row = get_stics_data(
        file_tec_xml=tec_file,  
        file_plt_xml=plant_file, 
        stics_output_file=stics_output_file, 
    )

dates = [value["Date"] for value in daily_dynamics.values() if value is not None]

# Extract 1 set of plant parameters from viable ones for given growth dynamics
params_wheat = define_params_1_plant(
    dynamics_file=stics_output_file, 
    plant_file=plant_file, 
    tec_file=tec_file,
    archi_params=archi_wheat)

# Generate and grow plant with ArchiCrop, following the given growth dynamics
wheat = ArchiCrop(daily_dynamics=daily_dynamics, **params_wheat)
wheat.generate_potential_plant()
growing_plant = wheat.grow_plant() # returns a list of MTGs

# From https://github.com/openalea/ArchiCrop/blob/ec69d4b3ea3efe6daf11a24ff1573fa90a39eca8/src/openalea/archicrop/simulation.py#L551
# For each time step
for d in dates:
    i = dates.index(d)
    mtg = growing_plant[d]
    print(f"Date: {d}, MTG: {mtg}")
    # Build and illuminate scene
    sc, _ = build_scene(mtg=mtg, position=(0, 0, 0), senescence=True)
    # Viewer.display(scene)
    # Viewer.frameGL.saveImage(f'scene_{i}.png')
    mtg_fn = f"2_outputs/archicrop/wheat_{i}_{d}.mtg"
    obj_fn = f"2_outputs/archicrop/wheat_{i}_{d}.obj"
    save_mtg(mtg, sc, mtg_fn, obj_fn)
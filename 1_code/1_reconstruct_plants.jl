using FileIO
using GLMakie
using MultiScaleTreeGraph, PlantGeom
using GeometryBasics
using CSV, DataFrames

# meshes = load.(filter(x -> endswith(x, ".obj"), readdir("0_simulations/archicrop/wheat", join=true)))
obj_files = filter(x -> endswith(x, ".obj"), readdir("0_simulations/archicrop/wheat", join=true))

meshes = Dict{String,GeometryBasics.Mesh}()
for obj_file in obj_files
    Id = split(split(basename(obj_file), ".")[1], "_")[end]
    Id in ["10", "12", "25", "27", "42", "8"] && continue
    # I get this error for those files, so I skip them for now. I don't know how to fix it, but it seems to be a problem with the .obj files themselves, not with the code.
    # ERROR: Failed to verify normal attribute:
    # Faces address 6 vertex attributes but only 4 are present.
    mesh_ = load(obj_file)
    meshes[Id] = mesh_.mesh
end

# whole_mesh = merge([mesh_ for (id, mesh_) in meshes])
# mesh(whole_mesh)

mtg = read_mtg("0_simulations/archicrop/wheat/plant_1995-06-24.mtg")

# Re-attach the geometry to the MTG using the Ids from the .obj files and the MTG attribute
traverse!(mtg) do node
    Id = string(node[:Id])
    if Id !== nothing && haskey(meshes, Id)
        node[:geometry] = PlantGeom.Geometry(
            ref_mesh=RefMesh(Id, meshes[Id]),
        )
    end
end

# write_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg)

# Add scene dimensions:
domain = CSV.read("0_simulations/stics/domain_per_plant.csv", DataFrame)
filter!(x -> x.situation == "wheat", domain)

scene = Node(MutableNodeMTG("/", "Scene", 1, 0))
reparent!(mtg, scene)
rechildren!(scene, [mtg])

scene[:scene_dimensions] = (
    (domain[1, :xmin], domain[1, :ymin], 0.0),
    (domain[1, :xmax], domain[1, :ymax])
)

mtg[:functional_group] = "wheat"
mtg[:pos] = Point(0.0, 0.0, 0.0)

write_ops("0_simulations/archimed/wheat.ops", scene)

# Make a visualization of the plant:
plantviz(scene)
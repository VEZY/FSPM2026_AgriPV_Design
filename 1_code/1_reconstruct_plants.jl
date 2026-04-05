using FileIO
using GLMakie
using MultiScaleTreeGraph, PlantGeom
using GeometryBasics
using CSV, DataFrames
using CoordinateTransformations, LinearAlgebra, StaticArrays


mesh_wheat = load("0_simulations/archicrop/wheat-blender.obj")

splitted_mesh = split_mesh(GeometryBasics.Mesh(mesh_wheat))
mesh_wheat[:object] #! use this to index by object id!!

# Map the meshes object ids from the .obj file to the splitted meshes, and scale from cm to m:
scale = 0.01
meshes = Dict{String,GeometryBasics.Mesh}()
for (i, obj) in enumerate(mesh_wheat[:object])
    # i=1; obj = mesh_wheat[:object][i]
    mesh_ = splitted_mesh[i]
    c, f = coordinates(mesh_), faces(mesh_)
    meshes[split(obj, "_")[end]] = GeometryBasics.Mesh(scale * c, f)
end

mtg = read_mtg("0_simulations/archicrop/wheat.mtg")

# Re-attach the geometry to the MTG using the Ids from the .obj files and the MTG attribute
traverse!(mtg) do node
    Id = string(node[:Id])
    if Id !== nothing && haskey(meshes, Id)
        node[:geometry] = PlantGeom.Geometry(
            ref_mesh=RefMesh(Id, meshes[Id]),
        )
    end
end

write_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg)

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
plantviz(scene, color=:green)
module AgripvSceneOrientationTests

using Test, ArchimedLight
include(joinpath(@__DIR__, "..", "scene_orientation.jl"))

const SCENE_ORIENTATION_TEST_RESULT = @testset "Geographic orientation of saved scenes" begin
    # Compare the visualization basis to the actual radiative-transfer change
    # of coordinates, including non-cardinal angles to catch sign mistakes.
    for rotation in (0.0, 45.0, 90.0, 180.0, 270.0, -32.0)
        directions = agripv_local_cardinal_directions(rotation)
        options = LightOptions(; scene_rotation_deg=rotation)
        @test collect(directions.north) ≈ collect(ArchimedLight._scene_local_direction((0.0, 1.0, 0.0), options))
        @test collect(directions.east) ≈ collect(ArchimedLight._scene_local_direction((1.0, 0.0, 0.0), options))
        phi = agripv_local_camera_azimuth(rotation)
        actual_local_view = ArchimedLight._scene_local_direction((cospi(1/4), sinpi(1/4), 0.0), options)
        @test [cos(phi), sin(phi), 0.0] ≈ collect(actual_local_view)
    end
    @test agripv_local_cardinal_directions(180.0).north == (0.0, -1.0, 0.0)
    @test agripv_local_cardinal_directions(90.0).north == (1.0, 0.0, 0.0)
    @test agripv_local_cardinal_directions(90.0).east == (0.0, -1.0, 0.0)

    recipe = Dict(:agripv_scene_recipe => Dict("config" => Dict("panel_orientation" => 90.0)))
    @test agripv_scene_rotation_deg(recipe) == 90.0
    @test_throws ArgumentError agripv_scene_rotation_deg(Dict(:agripv_scene_recipe => nothing))
    @test_throws ArgumentError agripv_scene_rotation_deg(
        Dict(:agripv_scene_recipe => Dict("config" => Dict("panel_orientation" => NaN))))

    # Domain origins need not be zero. The arrow follows geographic north,
    # remains horizontal, and lies outside the original planting domain.
    domain = (2.0, -3.0, 4.5, -0.9)
    for rotation in (90.0, 180.0)
        layout = _agripv_north_arrow_layout(domain, rotation)
        @test eltype(layout.points) == Point3f
        base, tip = layout.points[1:2]
        expected = agripv_local_cardinal_directions(rotation).north
        vector = tip - base
        @test collect(vector) / sqrt(sum(abs2, vector)) ≈ collect(expected)
        @test base[3] == tip[3]
        @test !(domain[1] <= base[1] <= domain[3] && domain[2] <= base[2] <= domain[4])
        @test all(i -> all(point -> layout.bounds[i][1] <= point[i] <= layout.bounds[i][2],
            [layout.points; [layout.label]]), 1:3)
    end
    @test _agripv_orientation_domain(Dict(:scene_dimensions => [(2.0, -3.0), (4.5, -0.9)])) == domain
    @test_throws ArgumentError _agripv_north_arrow_layout((0.0, 0.0, 0.0, 1.0), 90.0)
    @test_throws ArgumentError agripv_local_camera_azimuth(Inf)
    @test_throws ArgumentError agripv_local_cardinal_directions(NaN)
end

end

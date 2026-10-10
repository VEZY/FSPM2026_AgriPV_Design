module AgripvIntegratedOutputTests

using Test, Dates, DataFrames, TOML
include(joinpath(@__DIR__, "..", "attach_assimilation_to_scene.jl"))

const CONFIG_ID = 73
const DAYS = [Date(2025, 3, 4), Date(2025, 3, 5)]

function integration_fixture()
    plants = DataFrame(datetime=DateTime[], plant_instance_id=Int[], plant_id=Int[],
        leaf_area=Float64[], assimilation_step=Float64[])
    light = DataFrame(datetime=DateTime[], plant_instance_id=Int[], node_id=Int[],
        scale=String[], kind=String[], area=Float64[], Ra_PAR_f=Float64[])
    forcing = DataFrame(date=DateTime[], duration=Float64[])
    for (day_index, day) in enumerate(DAYS), step in 1:2
        stamp = DateTime(day) + Hour(step)
        push!(forcing, (stamp, step == 1 ? 1800.0 : 3600.0))
        for id in 2:3
            area = id == 2 ? 2.0 * day_index : day_index == 1 ? 0.0 : 1.0
            assimilation = id == 2 ? day_index * (step == 1 ? -100.0 : 300.0) : -25.0
            # Day-local MTG IDs change; persistent placement IDs remain 2 and 3.
            push!(plants, (stamp, id, 100 * day_index + id, area, assimilation))
            area > 0 && push!(light, (stamp, id, 1000 * day_index + id,
                "LeafSection", "active_leaf", area, 10.0 * step))
            push!(light, (stamp, id, 2000 * day_index + id,
                "Stem", "stem", 99.0, 999.0))
        end
    end
    return (; plants, light, forcing)
end

function save_integration_fixture(directory, fixture; complete=true, config_id=CONFIG_ID)
    metadata = Dict{String,Any}("config_id" => config_id, "days" => string.(DAYS),
        "plant_instance_identity_scope" => "configuration", "tables" => Dict{String,Any}(),
        "scenes" => [Dict("scene" => Dict("day" => string(day), "plant_rotations_rad" => [0.0, 0.0])) for day in DAYS])
    for role in (:plants, :light, :forcing)
        files = _agripv_write_parquet(getproperty(fixture, role), joinpath(directory, string(role));
            day=first(DAYS), batch_rows=3)
        for file in files
            file["file"] = joinpath(string(role), file["file"])
        end
        info = _agripv_parquet_info(files)
        info["complete"] = complete
        role == :forcing ? (metadata["forcing"] = info) : (metadata["tables"][string(role)] = info)
    end
    open(joinpath(directory, "scene_config_$(CONFIG_ID).toml"), "w") do io
        TOML.print(io, metadata)
    end
end

const INTEGRATED_OUTPUT_TEST_RESULT = @testset "Saved growth-cycle integrals" begin
    mktempdir() do directory
        fixture = integration_fixture()
        save_integration_fixture(directory, fixture)
        result = integrated_plant_outputs(; config_id=CONFIG_ID, output_dir=directory)
        @test result.plant_instance_id == [2, 3]
        @test result.n_days == [2, 2]
        @test result.cumulative_appfd_mol_m2 ≈ [0.8226, 0.4113]
        @test result.absorbed_photons_mol_plant ≈ [2.4678, 0.4113]
        @test result.net_assimilation_mol_CO2_plant ≈ [0.0006, -0.0001]
        assimilation = integrated_plant_assimilation(; config_id=CONFIG_ID, output_dir=directory)
        @test assimilation.total_assimilation ≈ result.net_assimilation_mol_CO2_plant
        summary_dir = joinpath(directory, "summaries")
        written = write_integrated_plant_outputs(; config_ids=[CONFIG_ID], output_dir=directory, summary_dir)
        @test written[CONFIG_ID] == result
        provenance = TOML.parsefile(joinpath(summary_dir, "provenance.toml"))
        @test provenance["configs"][1]["days"] == string.(DAYS)
        @test provenance["photons_per_J"] == 4.57
    end
    for alteration in (:repeated_plant, :incomplete_plant, :missing_light,
        :missing_forcing, :invalid_forcing, :changing_area, :incomplete_cycle, :missing_identity,
        :absent_whole_plant, :wrong_config, :repeated_light, :wrong_leaf_area)
        mktempdir() do directory
            fixture = integration_fixture()
            alteration == :repeated_plant && push!(fixture.plants, fixture.plants[1, :])
            alteration == :incomplete_plant && deleteat!(fixture.plants, 1)
            alteration == :missing_light && deleteat!(fixture.light,
                findall(row -> row.kind == "active_leaf" && row.plant_instance_id == 3, eachrow(fixture.light)))
            alteration == :missing_forcing && deleteat!(fixture.forcing, 1)
            alteration == :invalid_forcing && (fixture.forcing.duration[1] = -1)
            alteration == :changing_area && (fixture.plants.leaf_area[1] = 3)
            alteration == :missing_identity && DataFrames.select!(fixture.plants, Not(:plant_instance_id))
            alteration == :absent_whole_plant && filter!(:plant_instance_id => !=(3), fixture.plants)
            alteration == :repeated_light && push!(fixture.light, fixture.light[1, :])
            alteration == :wrong_leaf_area && (fixture.light.area[1] = 3)
            save_integration_fixture(directory, fixture; complete=alteration != :incomplete_cycle,
                config_id=alteration == :wrong_config ? CONFIG_ID + 1 : CONFIG_ID)
            @test_throws ArgumentError integrated_plant_outputs(; config_id=CONFIG_ID, output_dir=directory)
        end
    end
end

end

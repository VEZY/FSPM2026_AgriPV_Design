module AgripvMissingRepairTests
using Test, Dates, DataFrames, TOML
include(joinpath(@__DIR__, "..", "..", "2_outputs", "overnight_scripts", "run_missing_outputs.jl"))
const Repair = AgripvMissingOutputRepair

@testset "Missing-table publication preserves existing results" begin
    mktempdir() do root
        days = [Date(2025,3,4), Date(2025,3,5)]
        file = joinpath(root,"scene_config_0.toml")
        preserved = Dict("available"=>true,"rows"=>42,"file"=>"untouched.parquet")
        metadata=Dict("days"=>string.(days),"tables"=>Dict(
            "plants"=>deepcopy(preserved),"light"=>Dict("available"=>false,"files"=>[])))
        open(file,"w") do io
            TOML.print(io,metadata)
        end
        for day in days
            job=(;config_id=0,role=:light,day)
            staging=mktempdir(root)
            data=DataFrame(datetime=[DateTime(day)],value=[1.5])
            entries=Repair._agripv_write_parquet(data,staging;day)
            for entry in entries
                entry["file"]=joinpath("config_0","light","day=$day",entry["file"])
            end
            provenance=Dict("day"=>string(day))
            Repair._repair_publish(staging,entries,provenance,job,root,Repair._agripv_hash(file))
            saved=TOML.parsefile(file)
            @test saved["tables"]["plants"]==preserved
            @test Repair._missing_output_day_available(root,saved,:light,day)
            @test saved["tables"]["light"]["complete"]==(day==last(days))
            @test_throws ErrorException Repair._repair_publish(mktempdir(root),entries,provenance,job,root,Repair._agripv_hash(file))
            if day==first(days)
                @test_throws ArgumentError Repair._agripv_saved_files(root,saved["tables"]["light"])
            end
        end
        saved=TOML.parsefile(file)
        @test length(Repair._agripv_saved_files(root,saved["tables"]["light"]))==2
        @test length(saved["repair_history"])==2
    end
end

@testset "Archived comparisons reject mismatches" begin
    t=DataFrame(node_id=[1],timestep=[1],datetime=[DateTime(2025,3,4)],
        plant_id=[7],plant_instance_id=[1],A=[-2.0])
    @test Repair._repair_compare(t,t;columns=(:A,),label="fixture")["max_absolute_difference"]==0
    wrong=deepcopy(t);wrong.A .= 3.0
    @test_throws ArgumentError Repair._repair_compare(wrong,t;columns=(:A,),label="fixture")
end
end

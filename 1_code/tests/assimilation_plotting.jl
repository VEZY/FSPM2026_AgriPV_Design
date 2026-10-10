module AgripvAssimilationPlottingTests

using Test, DataFrames
include(joinpath(@__DIR__, "..", "assimilation_plotting.jl"))

const ASSIMILATION_PLOTTING_TEST_RESULT = @testset "Assimilation facet data contracts" begin
    # Identical planting numbers in separate configurations remain separate curves.
    source = DataFrame(config=[0, 0, 0, 0, 1, 1, 1, 1], plant=[10, 20, 10, 20, 10, 20, 10, 20],
        hour=[0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0],
        assimilation=[-4.0, -2.0, 4.0, 8.0, -10.0, -6.0, 20.0, 40.0])
    tables = _assimilation_facet_tables(reverse(source);
        x=:hour, y=:assimilation, config=:config, plant=:plant)
    @test tables.means.config_id == [0, 0, 1, 1]
    @test tables.means.value_mean == [-3.0, 6.0, -8.0, 30.0]
    @test tables.means.config_label == ["Config 0", "Config 0", "Config 1", "Config 1"]
    @test nrow(tables.individuals) == nrow(source)
    @test tables.individuals[1:2, :plot_x] == [0.0, 1.0]
    @test tables.individuals[1:2, :value] == [-4.0, 4.0]
    @test propertynames(source) == [:config, :plant, :hour, :assimilation]
    kwargs = (; x=:hour, y=:assimilation, config=:config, plant=:plant)
    @test_throws ArgumentError _assimilation_facet_tables(vcat(source, source[1:1, :]); kwargs...)
    @test_throws ArgumentError _assimilation_facet_tables(source[2:end, :]; kwargs...)
    invalid = copy(source)
    invalid.assimilation[1] = NaN
    @test_throws ArgumentError _assimilation_facet_tables(invalid; kwargs...)
end

end

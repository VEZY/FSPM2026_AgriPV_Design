using CSV, DataFrames
using DuckDB
using AlgebraOfGraphics

huge_file_path = "2_outputs/simulations/yearly/out_config_0.csv"
# DEPRECATED: Use DuckDB from the CLI to process out_config_x.csv files.
#=
huge_file_path = "2_outputs/simulations/yearly/out_config_0.csv"

# db = DuckDB.DB()
# con = DBInterface.connect(db)
# con = DBInterface.connect(DuckDB.DB, ":memory:")
con = DBInterface.connect(DuckDB.DB)

df_integrated = DataFrame(DBInterface.execute(con, """
	SELECT node_id, plant_instance_id, object_id, SUM(assimilation_step) AS assimilation_step
	FROM read_csv_auto('$huge_file_path')
	GROUP BY node_id, plant_instance_id, object_id
"""))

# df_integrated = DataFrame(DBInterface.execute(con, """
# 	DESCRIBE SELECT *
# 	FROM read_csv_auto('$huge_file_path')
# """))
=#

sort!(df_integrated, [:plant_instance_id])
rename!(df_integrated, :assimilation_step => :total_assimilation)
CSV.write("2_outputs/simulations/yearly/integrated_outs_config_0.csv", df_integrated)

df_nb_of_nodes_per_plant = combine(groupby(df_integrated, :plant_instance_id), nrow => :nb_of_nodes)

bar =
    data(df_nb_of_nodes_per_plant) *
    mapping(
        :plant_instance_id => "Plant Instance ID",
        :nb_of_nodes => "Number of Nodes"
    ) *
    visual(Bars, color=:plant_instance_id, colormap=:viridis)

draw(bar; figure=(size=(900, 700), title="Number of nodes per plant instance ID"))
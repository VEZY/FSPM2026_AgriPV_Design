# Objective: Run stics simulations of sole crops and their equivalent intercropping systems, with Beer and 2.5D formalisms, to compare with 3D simulations from ArchiCrop+Caribu.
# Output from this script are (inputs for ArchiCrop+Caribu for each simulation):
# 1. Dynamic outputs from STICS of LAI (laimax, laisen(n)), crop height (hauteur), thermal time corrected by stresses (somupvtsem), intercepted radiation (raint), incoming/transmitted radiation (trg(n) from each crop),
#  fraction of absorbed PAR (fapar), phenology (ilevs, iamfs, ilaxs), actual density (densite)
# 2. Inputs from STICS (from the meteo file) incoming radiation: trg(n) (this is for Caribu)
# 3. Parameters:
#   1. from tec file: interrow distance (plant-plant / species-species), row orientation, nrows per strip
#   2. from plant file: leaf lifespan (lifespanF) and ratio of lifespan between juvenile stage and exponential phase (ratiodurvieI)

library(SticsRPacks)
library(ggplot2)
source("1-code/0-helpers.R")

workspace <- normalizePath("0-data/workspace_v11")
usms <- get_usms_list(file.path(workspace, "usms.xml"))
output_path <- file.path("2-outputs", "usms_txt_monocrops")
javastics_path <- "/Users/rvezy/Documents/dev/stics/JavaSTICS-v11.0.0-rc2"

# usms <- SticsRFiles::get_usms_list(file.path(workspace, "usms.xml"))
sim_options <- stics_wrapper_options(
  javastics = javastics_path,
  workspace = output_path,
  parallel = TRUE
)

# Run Beer simulations:
activate_light(workspace = workspace, algorithm = "Beer")
gen_usms_xml2txt(
  # javastics = javastics_path,
  workspace = workspace,
  out_dir = output_path,
  parallel = TRUE,
  usm = c("sorghum_monocrop", "maize_BEOU_monocrop")
)
sim_run_beer <- stics_wrapper(sim_options)

# Run 2.5D simulations:
activate_light(workspace = workspace, algorithm = "2.5D")
gen_usms_xml2txt(
  workspace = workspace,
  out_dir = output_path,
  parallel = TRUE,
  usm = c("sorghum_monocrop", "maize_BEOU_monocrop")
)

sim_run_2.5D <- stics_wrapper(sim_options)

p <- plot(
  Beer = sim_run_beer$sim_list,
  "2.5D" = sim_run_2.5D$sim_list,
  type = "dynamic",
  all_situations = TRUE,
  var = c(
    "laimax",
    "hauteur",
    "somupvtsem",
    "laisen_n",
    "raint",
    "trg_n"
  )
)
p[["maize_BEOU_monocrop"]]
p[["sorghum_monocrop"]]

ggsave(
  p[["maize_BEOU_monocrop"]],
  filename = file.path(
    "2-outputs",
    "plots_monocrop",
    "simulations_stics_monocrops_maize.png"
  ),
  width = 12,
  height = 6
)
ggsave(
  p[["sorghum_monocrop"]],
  filename = file.path(
    "2-outputs",
    "plots_monocrop",
    "simulations_stics_monocrops_sorghum.png"
  ),
  width = 12,
  height = 6
)

sim_beer <- CroPlotR::bind_rows(sim_run_beer$sim_list)
sim_2.5D <- CroPlotR::bind_rows(sim_run_2.5D$sim_list)

sim_beer$algorithm <- "Beer"
sim_2.5D$algorithm <- "2.5D"

# Concatenate the two dataframes:
sim_all <- merge(sim_beer, sim_2.5D, all = TRUE)

write.csv(
  sim_all,
  file.path("2-outputs", "simulations_stics_monocrops.csv"),
  row.names = FALSE
)

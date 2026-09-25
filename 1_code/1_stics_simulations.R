library(SticsRPacks)
library(ggplot2)

workspace <- normalizePath("0_simulations/stics/wheat")
usms <- get_usms_list(file.path(workspace, "usms.xml"))
output_path <- file.path("2-outputs", "usms_txt_monocrops")
javastics_path <- "/Users/rvezy/Documents/dev/stics/JavaSTICS-10.5.0-STICS-10.5.0" # Change this path to your local JavaSTICS installation

# usms <- SticsRFiles::get_usms_list(file.path(workspace, "usms.xml"))
sim_options <- stics_wrapper_options(
  javastics = javastics_path,
  workspace = workspace,
  parallel = TRUE
)

# Run Beer simulations:
gen_usms_xml2txt(
  workspace = workspace,
  parallel = FALSE
)
sim <- stics_wrapper(sim_options)

p <- plot(
  sim$sim_list,
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

ggsave(
  p[[1]],
  filename = file.path(
    "2_outputs",
    "stics_wheat.png"
  ),
  width = 12,
  height = 6
)

sim <- CroPlotR::bind_rows(sim$sim_list)

write.csv(
  sim,
  file.path(workspace, "simulations_stics_wheat.csv"),
  row.names = FALSE
)

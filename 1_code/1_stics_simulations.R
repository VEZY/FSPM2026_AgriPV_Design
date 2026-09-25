library(SticsRPacks)
library(ggplot2)

workspace <- normalizePath("0_simulations/stics/wheat")
usm <- "neodur_2025"
javastics_path <- "/Users/rvezy/Documents/dev/stics/JavaSTICS-10.5.0-STICS-10.5.0" # Change this path to your local JavaSTICS installation
stics_exe <- file.path(javastics_path, "bin", "stics_modulo_mac")
stopifnot(
  file.exists(stics_exe),
  usm %in% get_usms_list(file.path(workspace, "usms.xml"))
)

# Generate the STICS input files:
generated <- gen_usms_xml2txt(
  javastics = javastics_path,
  workspace = workspace,
  usm = usm,
  stics_version = "V10.5.0",
  parallel = FALSE
)

sim_options <- stics_wrapper_options(
  javastics = javastics_path,
  stics_exe = stics_exe,
  workspace = workspace,
  parallel = FALSE
)

# Run Neodur for the full 2025 calendar year
sim <- stics_wrapper(sim_options, situation = usm)

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

dir.create("2_outputs", recursive = TRUE, showWarnings = FALSE)
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

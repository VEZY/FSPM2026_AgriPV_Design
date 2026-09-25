from __future__ import annotations

import math
import sys
import time as t
from math import ceil
from multiprocessing import Pool
from pathlib import Path
import csv

sys.path.append('../0_simulations')
from archi_dict import archi_sorghum as archi_1
from archi_dict import archi_maize as archi_2

from openalea.archicrop.simulation import define_archicrop_parameters_IC, run_archicrop_parallel_IC
from openalea.archicrop.stics_io import read_csv_file_IC, read_doe_intercrop

if __name__ == '__main__':

    path = Path("../../1-simul_stics/0-data/workspace_v11_gen/")

    plant_1 = "sorghum"
    plant_2 = "maize"

    # print("Nb CPU : ")
    # n_cpu = int(input())
    id_sim = range(1,46) 
    id_usm = [f"usm_{i}" for i in id_sim]
    n_cpu = len(id_sim)

    # Define the inputs for the simulation
    # tec_files_1=list(path.glob("sorghum_*_tec.xml"))
    # tec_files_2=list(path.glob("maize_*_tec.xml"))
    plant_file_1="../../1-simul_stics/0-data/workspace_v11_gen/plant/sorgho_trop_plt.xml"
    plant_file_2="../../1-simul_stics/0-data/workspace_v11_gen/plant/corn_LI_step2_BEOU_plt.xml"

    tec_files_1 = []
    tec_files_2 = []
    for i in id_sim:
        tec_files_1.append(path.glob(f"{plant_1}_{i}_tec.xml"))
        tec_files_2.append(path.glob(f"{plant_2}_{i}_tec.xml"))

    file_csv = "../../1-simul_stics/2-outputs/simulations_stics_intercrops.csv"

    d_outputs = read_csv_file_IC(file_csv)

    pot_factor_lai = 5
    pot_factor_height = 10

    save_scenes = True
    conv_coef = 100 # Conversion coefficient from meters to centimeters

    param_sets = {}

    for i, (usm, t1, t2) in enumerate(zip(id_usm, tec_files_1, tec_files_2)):

        # usm = f"usm_{i+1}"
        param_sets[usm] = {}

        for algo in ["Beer", "2.5D"]:
            param_sets[usm][algo] = {}

            param_sets_1, density_1 = define_archicrop_parameters_IC(archi_params = archi_1, 
                                                    tec_file = t1, 
                                                    plant_file = plant_file_1, 
                                                    d_outputs = d_outputs[usm][algo][plant_1],
                                                    pot_factor_lai = pot_factor_lai,
                                                    pot_factor_height = pot_factor_height)
            
            param_sets_2, density_2 = define_archicrop_parameters_IC(archi_params = archi_2, 
                                                    tec_file = t2, 
                                                    plant_file = plant_file_2, 
                                                    d_outputs = d_outputs[usm][algo][plant_2],
                                                    pot_factor_lai = pot_factor_lai,
                                                    pot_factor_height = pot_factor_height)
            
            param_sets[usm][algo][plant_1] = (param_sets_1, density_1)
            param_sets[usm][algo][plant_2] = (param_sets_2, density_2)
  

    row_orientation_values = {
    "N-S" : 0,
    "E-W" : math.pi / 2
    }

    interrow_distance_per_species = {
    "sorghum" : {
        "high" : 0.8,
        "middle" : 0.4,
        "low" : 0.2
    },
    "maize_trop" : {
        "high" : 0.8,
        "middle" : 0.4,
        "low" : 0.2
    }
    }

    n_rows_per_species = {
    "sorghum" : {
        "one" : 1, # For non-strip, this is just one row
        "high" : 6,
        "middle" : 4,
        "low" : 2
    },
    "maize_trop" : {
        "one" : 1,
        "high" : 6,
        "middle" : 4,
        "low" : 2
    }
    }

    intrarow_distance_per_species = {
    "sorghum" : {
        "high" : 0.8,
        "middle" : 0.4, # ~6 plants per m2 with 0.4m interrow distance, gives 0.41m intrarow distance
        "low" : 0.2
    },
    "maize_trop" : {
        "high" : 0.8,
        "middle" : 0.4,
        "low" : 0.2
    }
    }

    doe_file = "../../1-simul_stics/2-outputs/doe.csv"
    doe = read_doe_intercrop(doe_file)

    doe_adapt = {}

    for usm,spat_conf in doe.items():
        if usm in id_usm:
            # spat_conf["row_orientation"] = row_orientation_values[spat_conf["row_orientation"]]
            spat_conf["interrow_distance_principal"] = interrow_distance_per_species[spat_conf["species_principal"]][spat_conf["interrow_distance_principal"]]
            spat_conf["interrow_distance_secondary"] = interrow_distance_per_species[spat_conf["species_secondary"]][spat_conf["interrow_distance_secondary"]]
            spat_conf["n_rows_principal"] = 0 if spat_conf["design"] == "intercrop mixed" else n_rows_per_species[spat_conf["species_principal"]][spat_conf["n_rows_principal"]]
            spat_conf["n_rows_secondary"] = 0 if spat_conf["design"] == "intercrop mixed" else n_rows_per_species[spat_conf["species_secondary"]][spat_conf["n_rows_secondary"]]
            spat_conf["intrarow_distance"] = intrarow_distance_per_species[spat_conf["species_principal"]][spat_conf["intrarow_distance"]]

            doe_adapt[usm] = {}

            for algo in param_sets[usm]:

                density_1 = param_sets[usm][algo][plant_1][1]
                density_2 = param_sets[usm][algo][plant_2][1]
                inter_row_1 = spat_conf["interrow_distance_principal"]
                inter_row_2 = spat_conf["interrow_distance_secondary"]
                intra_row_1 = 1/density_1/inter_row_1
                intra_row_2 = 1/density_2/inter_row_2

                doe_adapt[usm][algo] = {
                    # "design" : spat_conf["design"],
                    "orientation" : spat_conf["row_orientation"],
                    "density_1" : density_1,
                    "density_2" : density_2,
                    "inter_row_1" : inter_row_1,
                    "inter_row_2" : inter_row_2,
                    "width" : 2 * inter_row_1 if spat_conf["design"] == "intercrop mixed" else (spat_conf["n_rows_principal"]-1) * inter_row_1 + (spat_conf["n_rows_secondary"]-1) * inter_row_2 + 2*max(inter_row_1, inter_row_2),
                    "length" : 2 * max(intra_row_1, intra_row_2) if spat_conf["design"] == "intercrop mixed" else max(intra_row_1, intra_row_2),
                    "nb_rows_1" : spat_conf["n_rows_principal"],
                    "nb_rows_2" : spat_conf["n_rows_secondary"],
                    # "sowing_delay" : 1 if spat_conf["sowing_date_latest_crop"] == "later" else 0
                }

    domain_file = "../../3-3D_light_inter/0-data/domains.csv"
    header = ["usms", "x_first_corner", "y_first_corner", "x_last_corner", "y_last_corner"]
    rows = []

    for usm, algo in doe_adapt.items():
        for a,conf in algo.items():
            if conf["orientation"] == "N-S":
                domain = ((0, 0), (conf["length"] * conv_coef, conf["width"] * conv_coef))
            elif conf["orientation"] == "E-W":
                domain = ((0, 0), (conf["width"] * conv_coef, conf["length"] * conv_coef))
            if a == "Beer":
                rows.append([usm, domain[0][0], domain[0][1], domain[1][0], domain[1][1]])

    with open(domain_file, "w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(header)
        writer.writerows(rows) 


    with Pool(n_cpu) as p:
        start_time = t.time()
        p.starmap_async(run_archicrop_parallel_IC, 
                        [({usm:param_sets[usm]}, {usm:d_outputs[usm]}, {usm:doe_adapt[usm]}, '../../3-3D_light_inter/0-data/mtg_obj/', save_scenes) 
                        for i,usm in enumerate(id_usm)]).get()
        end_time = t.time()
        elapsed_time = (end_time - start_time)/3600
        print(f"Simulation time: {elapsed_time:.2f} hours for {len(param_sets)*2} simulations on {n_cpu} CPU")



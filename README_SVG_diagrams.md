# SVG Diagrams for AgriPV Simulation Framework

This directory contains two SVG diagrams that illustrate the integration of the STICS crop model, Archicrop, ArchimedLight, and PlantBioPhysics in the AgriPV simulation framework.

## Files

1. `crop_model_integration.svg` - High-level overview showing the main connections between the four components.
2. `detailed_integration.svg` - Detailed diagram with:
   - Component boxes with logos (STICS, Archicrop, ArchimedLight, PlantBioPhysics)
   - Solid connection arrows showing data/input flow
   - Dashed green arrows for main data coupling (growth forcing, aPPFD)
   - Dashed orange arrows for feedback loops (water/nitrogen stress, shading effects)
   - Icons representing each component's domain
   - Outputs box showing generated CSV files

## Creation Process

The diagrams were created and refined through an iterative process:
- Initial SVG created with basic shapes and connections
- Fixed XML parsing errors (escaped special characters like "&" to "&amp;")
- Moved logos from external positions to inside component boxes next to titles
- Adjusted logo positions (left/up by 10px) for better alignment
- Preserved all semantic connections and labels

## Usage

These diagrams can be used in documentation, presentations, or reports to visualize the AgriPV simulation workflow showing how:
1. STICS generates crop growth dynamics
2. Archicrop creates 3D plant geometries from STICS outputs
3. Scene Builder combines plant geometries with PV panel layout
4. ArchimedLight simulates light interception and absorption
5. PlantBioPhysics models physiological processes (photosynthesis, transpiration)
6. Outputs collect leaf-level, light-level, and plant-level simulation results

## Last Updated

October 10, 2026 - Based on code review of the 1_code/ simulation scripts.

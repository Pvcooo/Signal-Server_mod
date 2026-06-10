# Signal-Server_mod

Fork of [Signal Server](https://github.com/Alex-QCVS/Signal-Server) RF propagation simulator adapted for high-resolution LiDAR/GeoTIFF terrain data (EPSG:25830). To work properly, it's necessary to have the Digital Terrain Models files in the Signal-Server_mod/data/dtm directory or to indicate the path to them.

---

## Changes from the original Signal Server

### Binary (`signalserverLIDAR`)

|     	     	   Area  	   	 |  	   	    Change   	   	  |
|----------------------------------------|----------------------------------------|
|            **Tile loading**  		 | Directory scan via `-lid <dir>`: automatically finds all `.asc`/`.tif`/`.tiff` files in the folder without listing each one individually.|
|           **Spatial filter** 		 | Before loading pixel data, each tile's bounding box is checked against the TX location + radius. Only tiles that overlap the area of interest are loaded, drastically reducing load time when the directory contains hundreds of tiles (e.g. all-Navarra MDT). |
|         **Seamless terrain** 		 | The ROI tiles are warped to a single WGS84 mosaic in one pass with GDALWarp, instead of reprojecting each tile independently. This removes the straight seams (misaligned grids and 0 m edge wedges) at tile boundaries. Because GDALWarp accepts sources with **different CRS**, a region spanning several UTM zones (e.g. Spanish husos 30 and 31) is fused seamlessly. The temporary mosaic lives in memory and is discarded after the run. |
| 	     **Reprojection**  		 | Tiles in any CRS (e.g. any UTM zone) are automatically reprojected to WGS84 via GDAL using the CRS embedded in the GeoTIFF (or a `.prj` sidecar for `.asc`). An `.asc` with no readable CRS is assumed to be WGS84 lat/lon, and the binary now prints a warning in that case. |
| 	**Bilinear interpolation**	 | `GetElevation()` uses bilinear interpolation between the four nearest DEM pixels instead of nearest-neighbour, reducing staircase artefacts at high resolution. |
| **yppd (longitude pixels-per-degree)** | Computed from the actual tile width in degrees rather than assumed square, correcting coordinate distortion after UTM→WGS84 reprojection. |
| 	   **Report buffer**		 | `PathReport()`: `report_name` buffer increased from 80 to 512 bytes, fixing truncation of long output paths. |
| 	  **LOS profile line**		 | `SeriesData()`: the line-of-sight series uses a correct linear interpolation between TX and RX antenna heights AMSL instead of the original formula that collapsed to TX AMSL for all path points due to floating-point cancellation at Earth-radius scale. |
| 	**Terrain sentinel guard**	 | Points where `GetElevation()` returns −5000 ft (no tile loaded) are excluded from the gnuplot terrain and LOS data files, preventing −1524 m spikes in the profile chart. |
|     **Output directory creation** 	 | The binary creates the output directory tree (`mkdir -p` equivalent) if it does not exist. |

---

## Terrain data downloader (`scripts/download_dtm_ign_spain.py`)

Downloads Digital Terrain Models (MDT) for peninsular Spain from the IGN WCS as a single standardized product: **MDT 5 m, EPSG:25830, GeoTIFF**. By default the tiles are saved into `data/dtm` (the folder the simulator reads).

```bash
pip install -r requirements.txt

# list the available regions
python scripts/download_dtm_ign_spain.py --regions

# download one region (saved to data/dtm)
python scripts/download_dtm_ign_spain.py castilla_la_mancha

# save to a custom terrain-models folder instead
python scripts/download_dtm_ign_spain.py castilla_la_mancha -i /path/to/models
```

### Input flags

|        Flag          | Value  |                                  Description                                  |
|----------------------|--------|-------------------------------------------------------------------------------|
| `region`             | name   | Region to download, lowercase with `_` (e.g. `castilla_la_mancha`, `espana_peninsular`). Run `--regions` for the full list. |
| `-i`, `--input-path` | path   | Folder with terrain models — the download destination and the folder the simulator reads. **If omitted, defaults to `data/dtm`.** |
| `-t`, `--tile`       | metres | Tile side length in metres (default: 10000). |
| `-w`, `--workers`    | int    | Number of parallel download threads (default: 6). |
| `-f`, `--filter`     | string | Only download tiles whose filename contains this substring. |
| `--limit`            | int    | Download at most N tiles (useful for testing). |
| `--list`             | —      | Dry-run: list/count the tiles and print the request URLs without downloading. |
| `--regions`          | —      | Print the list of available regions and exit. |

> Note: 5 m is the maximum resolution available over the WCS/API without a login. The 2 m product (MDT02) is only served by the CNIG download centre and requires a registered account.

---

## Wrapper script (`runsig_lidar.sh`)
The script wraps the binary with automatic KMZ generation, gnuplot profile chart, and JSON output.

# Usage
	-->   ./scripts/runsig_lidar.sh [options] -o OUTPUT_PATH
`OUTPUT_PATH` is a base path without extension (e.g. `/results/Link_A/Link_A`).
The script creates a subdirectory `<basename>/` and writes all output files there.


### Input flags

# Required
|  Flag  |    Value    |			    Description 			      |
|--------|-------------|----------------------------------------------------------------------|
| `-o` 	 |     path    | Base output path (no extension). Directory is created automatically. |
| `-lat` | decimal deg | Transmitter latitude. 			      			      |
| `-lon` | decimal deg | Transmitter longitude (negative = West). 			      |
| `-f` 	 |     MHz     | Frequency (20 MHz – 100 GHz). 			      		      |
| `-erp` |    Watts    | Transmitter ERP (including TX+RX gain). 			      |


# Antenna / geometry
|  Flag  |    Value    |		    Description			       |
|--------|-------------|-------------------------------------------------------|
| `-txh` |      m      | TX antenna height above ground (AGL). 		       |
| `-rla` | decimal deg | RX latitude — enables **point-to-point (P2P)** mode.  |
| `-rlo` | decimal deg | RX longitude. 					       |
| `-rxh` | 	m      | RX antenna height AGL (default: 0.1). 		       |
| `-txn` |   string    | TX site name shown in KML and report (default: `Tx`). |
| `-rxn` |   string    | RX site name shown in KML and report (default: `Rx`). |


# Propagation model
|    Flag   | Value | 			Description			      |
|-----------|-------|---------------------------------------------------------|
| `-pm`     |  1–12 | Propagation model: 1=ITM (default), 2=LOS, 3=Hata, 4=ECC33, 5=SUI, 6=COST-Hata, 7=FSPL, 8=ITWOM, 9=Ericsson, 10=Plane earth, 11=Egli, 12=Soil. |
| `-pe`     |  1–3  | Model environment: 1=Urban, 2=Suburban, 3=Rural. 	      |
| `-ked`    |   —   | Enable knife-edge diffraction (already active for ITM). |
| `-rel`    |  1–99 | ITM reliability (% of time). Default: 50. 	      |
| `-conf`   |  1–99 | ITM confidence (% of situations). Default: 50. 	      |
| `-cl`     |  1–7  | Radio climate: 1=Equatorial, 2=Continental subtropical, 3=Maritime subtropical, 4=Desert, 5=Continental temperate, 6=Maritime temperate (land), 7=Maritime temperate (sea). |
| `-te`     |  1–6  | Terrain type: 1=Water, 2=Marsh, 3=Farmland, 4=Mountain, 5=Desert, 6=Urban. Sets dielectric/conductivity. |
| `-terdic` | float | Earth dielectric constant (2–80). 		      |
| `-tercon` | float | Earth conductivity (0.000001–0.01 S/m). 		      |
| `-gc`     |   m   | Random ground clutter height. 			      |
| `-m`      |   —   | Use metric units in the text report. 		      |


# Coverage / area mode
| 	Flag 	  |  Value | 		   Description 		    |
|-----------------|--------|----------------------------------------|
| `-R` 		  |   km   | Analysis radius. Required for area coverage. In P2P mode without `-R`, the script auto-computes the TX→RX distance + 1 km margin so all path tiles are loaded. |
| `-coverage` 	  |   —    | (P2P mode only) Also run an area coverage analysis and include it as a layer in the KMZ. Requires `-R`. |
| `-covpm` 	  |  1–12  | Propagation model used **only** for the coverage run (independent of `-pm`). Useful to use a faster model (e.g. `3`=Hata, `7`=FSPL) for the coverage overlay while keeping ITM for the P2P report. |
| `-covresample`  |  int   | Resample factor applied **only** to the coverage run (default: 5). A factor of 5 gives ×25 fewer pixels and greatly reduces computation time. Pass `1` to disable. |
| `-resample` 	  |  int   | Resample factor applied to the P2P run (max 10). Reduces LiDAR resolution for both tile loading and path computation. |
| `-rt` 	  | dB/dBm | Receiver threshold for coverage colour rendering. |
| `-dbm` 	  |   —    | Plot received signal power (dBm) instead of field strength (dBuV/m). |


# Antenna pattern
|   Flag   |  Value  |				  Description				   |
|----------|---------|---------------------------------------------------------------------|
| `-ant`   |   path  | Antenna pattern file base path (loads `<path>.az` and `<path>.el`). |
| `-rot`   |  0–359° | Antenna pattern rotation. 					   |
| `-dt`    | −10–90° | Antenna downtilt angle. 						   |
| `-dtdir` |  0–359° | Antenna downtilt direction. 					   |
| `-hp`    |    —    | Horizontal polarisation (default: vertical). 			   |
| `-rxg`   |   dBd   | RX antenna gain (included in text report). 			   |


# Miscellaneous
|     Flag     |  Value | 			Description			       |
|--------------|--------|--------------------------------------------------------------|
| `-udt`       |  file  | User-defined point clutter file (`lat,lon,height` per line). |
| `-clt`       |  file  | MODIS 17-class wide-area clutter ASCII grid. 		       |
| `-color`     |  file  | Pre-load `.scf`/`.lcf`/`.dcf` colour palette file.           |
| `-nothreads` |   —    | Disable multi-threaded processing (single-threaded mode).    |
| `-dbg`       |   —    | Verbose debug output from the binary.			       |




### Output files
All files are written to `<OUTPUT_DIR>/<BASENAME>/`:

|	   File		 | 			     Description			       |
|------------------------|---------------------------------------------------------------------|
| `BASENAME.txt`  	 | Full link report (propagation parameters, path loss, obstructions). |
| `BASENAME.json` 	 | Structured JSON with all report fields. 			       |
| `BASENAME.dcf`  	 | dBm colour palette definition. 				       |
| `BASENAME_profile.png` | Terrain profile chart (gnuplot): terrain, LOS line, Fresnel zones.  |
| `BASENAME.kml` 	 | KML source (placemarks, link line, optional coverage overlay).      |
| `BASENAME.kmz` 	 | KMZ package (KML + all associated files). Ready for Google Earth.   |
| `BASENAME.png` 	 | Coverage PNG (area mode or when `-coverage` is used). 	       |
| `BASENAME.tiff` 	 | Coverage GeoTIFF (area mode or when `-coverage` is used).           |




### Examples
**Point-to-point only:**
```bash
./scripts/runsig_lidar.sh \
  -ant /path/to/Signal-Server_mod/data/antennas/Monopole/Monopole_9dBi -rxg 6.86 \
  -lat 64.31920992106285 -lon -15.239195936909075 \
  -rla 64.28813853450863 -rlo -15.146888767722631 \
  -txh 2.75 -rxh 1.5 -txn "Site A" -rxn "Site B" \
  -f 2450 -erp 61 -R 15 \
  -pm 1 -pe 2 -rel 80 -conf 90 -cl 5 -te 4 \
  -dbm -m -resample 2 \
  -o /path/to/results/Link_AB
```


**P2P + coverage overlay:**
```bash
./scripts/runsig_lidar.sh \
  -ant /path/to/Signal-Server_mod/data/antennas/Monopole/Monopole_9dBi -rxg 6.86 \
  -lat 64.31920992106285 -lon -15.239195936909075 \
  -rla 64.28813853450863 -rlo -15.146888767722631 \
  -txh 2.75 -rxh 1.5 -txn "Site A" -rxn "Site B" \
  -f 2450 -erp 61 -R 15 \
  -pm 1 -pe 2 -rel 80 -conf 90 -cl 5 -te 4 \
  -dbm -m -resample 2 \
  -coverage -covresample 2 \
  -o /path/to/results/Link_AB_coverage
```

**Area coverage only:**
```bash
./scripts/runsig_lidar.sh \
  -ant /path/to/Signal-Server_mod/data/antennas/Monopole/Monopole_9dBi \
  -lat 64.31920992106285 -lon -15.239195936909075 \
  -txh 1.75 -txn "Base Station" \
  -f 2450 -erp 61 -R 15 \
  -pm 1 -pe 2 -rel 80 -conf 90 -cl 5 -te 4 \
  -dbm -m -resample 2 \
  -o /path/to/results/Coverage_BS
```

---

## Batch launcher (`launch_simulations.sh`)

Runs many `runsig_lidar.sh` simulations from a single plain-text data file:

- **COVERAGE**: one per HOME × each Tx height.
- **P2P**: one per HOME × each receiver point × each Tx height × each Rx height.

```bash
./scripts/launch_simulations.sh examples/example_input.txt
```

### Data file format

```
tx_height: 1.75, 15, 30                 # transmitter heights (list)
rx_height: 5, 10                        # P2P receiver heights (list)

Site_Reykjavik.bin                      # a location (the .bin suffix is stripped)
HOME:    64.146600, -21.942600, -R 5    # HOME: lat, lon, extra-args (verbatim)
Relay_1: 64.161000, -21.910000, -R 4    # receiver point: name, lat, lon, extra
Relay_2: 64.130000, -21.880000, -R 4
```

- Each `Name: lat, lon, <extra>` line is a point; everything after the 2nd comma (`<extra>`, e.g. `-R 5`) is appended verbatim to that command (COVERAGE uses HOME's extra, P2P uses the receiver's).
- Point names must be unique within a location (duplicates get `_2`, `_3`, ...).
- A line without `:` starts a new location.

See `examples/example_input.txt` for a complete example.

### Options (environment variables)

|       Variable          |                              Description                                |
|-------------------------|-------------------------------------------------------------------------|
| `JOBS=N`                | Run up to **N simulations in parallel** (default: 1). |
| `DRY_RUN=1`             | Print the commands without running anything. |
| `SKIP_EXISTING=1`       | Skip a simulation if its output already exists. |
| `STOP_ON_ERROR=1`       | Abort the batch on the first failure (serial mode only). |
| `ONLY=coverage` / `p2p` | Run only one type of simulation. |
| `OUTBASE=<dir>`         | Output base folder for all results. **Default: the repository's `results/` folder.** |

**Parallelism note:** each simulation is already multi-threaded, so the total load is roughly `JOBS × threads-per-sim`. Choose `JOBS` near `CPU_cores / threads-per-sim` and watch RAM (each job loads terrain tiles into memory). To use every core cleanly with low memory pressure, set `JOBS=$(nproc)` and add `-nothreads` to `COMMON_PARAMS` (one thread per job). In parallel mode each job's output goes to a per-job log file (its path is printed if the job fails).

```bash
# example: 4 simulations at a time
JOBS=4 ./scripts/launch_simulations.sh examples/example_input.txt
```

---

### Dependencies

```bash
sudo bash install_dependencies.sh
```

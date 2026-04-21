# Signal-Server_mod

Fork of [Signal Server](https://github.com/Alex-QCVS/Signal-Server) RF propagation simulator adapted for high-resolution LiDAR/GeoTIFF terrain data (EPSG:25830).

---

## Changes from the original Signal Server

### Binary (`signalserverLIDAR`)

|     	     	   Area  	   	 |  	   	    Change   	   	  |
|----------------------------------------|----------------------------------------|
|            **Tile loading**  		 | Directory scan via `-lid <dir>`: automatically finds all `.asc`/`.tif`/`.tiff` files in the folder without listing each one individually.|
|           **Spatial filter** 		 | Before loading pixel data, each tile's bounding box is checked against the TX location + radius. Only tiles that overlap the area of interest are loaded, drastically reducing load time when the directory contains hundreds of tiles (e.g. all-Navarra MDT). |
| 	     **Reprojection**  		 | Tiles in any CRS (e.g. EPSG:25830 UTM) are automatically reprojected to WGS84 via GDAL. A `.prj` sidecar file is used when present. |
| 	**Bilinear interpolation**	 | `GetElevation()` uses bilinear interpolation between the four nearest DEM pixels instead of nearest-neighbour, reducing staircase artefacts at high resolution. |
| **yppd (longitude pixels-per-degree)** | Computed from the actual tile width in degrees rather than assumed square, correcting coordinate distortion after UTM→WGS84 reprojection. |
| 	   **Report buffer**		 | `PathReport()`: `report_name` buffer increased from 80 to 512 bytes, fixing truncation of long output paths. |
| 	  **LOS profile line**		 | `SeriesData()`: the line-of-sight series uses a correct linear interpolation between TX and RX antenna heights AMSL instead of the original formula that collapsed to TX AMSL for all path points due to floating-point cancellation at Earth-radius scale. |
| 	**Terrain sentinel guard**	 | Points where `GetElevation()` returns −5000 ft (no tile loaded) are excluded from the gnuplot terrain and LOS data files, preventing −1524 m spikes in the profile chart. |
|     **Output directory creation** 	 | The binary creates the output directory tree (`mkdir -p` equivalent) if it does not exist. |

---

## Wrapper script (`runsig_lidar.sh`)
The script wraps the binary with automatic KMZ generation, gnuplot profile chart, and JSON output.

# Usage
	-->   ./runsig_lidar.sh [options] -o OUTPUT_PATH
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
./runsig_lidar.sh \
  -lat 42.7356 -lon -1.7424 -txh 6 \
  -rla 42.6931 -rlo -1.7672 -rxh 2 \
  -f 2450 -erp 10 -m \
  -txn "Site A" -rxn "Site B" \
  -o /results/Link_AB/Link_AB
```

**P2P + coverage overlay (fast):**
```bash
./runsig_lidar.sh \
  -lat 42.7356 -lon -1.7424 -txh 6 \
  -rla 42.6931 -rlo -1.7672 -rxh 2 \
  -f 2450 -erp 10 -m \
  -txn "Site A" -rxn "Site B" \
  -coverage -R 15 -covpm 3 -covresample 5 \
  -o /results/Link_AB/Link_AB
```

**Area coverage only:**
```bash
./runsig_lidar.sh \
  -lat 42.7356 -lon -1.7424 -txh 30 \
  -f 800 -erp 50 -m -R 30 \
  -txn "Base Station" \
  -o /results/Coverage_BS/Coverage_BS
```

---

### Dependencies

```bash
sudo sh Install_depencies.sh
```

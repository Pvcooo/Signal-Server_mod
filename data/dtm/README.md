# DIGITAL TERRAIN MODELS

Place here the Digital Terrain Models of the area you want to simulate.

Accepted formats (loaded via `-lid`):
- GeoTIFF (`.tif` / `.tiff`) in any CRS — automatically reprojected to WGS84.
- ESRI ASCII grid (`.asc`), with a `.prj` sidecar when the CRS is projected.

The IGN downloader (`scripts/download_dtm_ign_spain.py`) fills this folder with
MDT 5 m GeoTIFF tiles in EPSG:25830 by default. This fork was tested with
EPSG:25830 data.

The model files themselves are git-ignored (they are large); only this README
is tracked so the folder exists.

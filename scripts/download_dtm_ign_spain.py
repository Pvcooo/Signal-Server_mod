#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""

=========================
Unified downloader of IGN Digital Terrain Models (MDT) for peninsular Spain,
from a single standardized source:

  IGN WCS  ->  https://servicios.idee.es/wcs-inspire/mdt
  Coverage: Elevacion25830_5   (MDT 5 m, EPSG:25830)
  Format:   GEOTIFFINT16       (georeferenced integer-elevation GeoTIFF)

Tiles are requested by BBOX in EPSG:25830 (each request <= ~2048 px per side).
Homogeneous output: GeoTIFF 5 m, EPSG:25830, for ANY region. This means the
simulator only has to support a single format/CRS.

By default the tiles are saved into the simulator's terrain folder
(data/dtm). Use -i/--input-path to save them to a different folder.

Resolution note: 5 m is the maximum available over WCS/API without a login.
The 2 m product (MDT02, 2nd coverage) is only served by the CNIG download
centre and requires a registered account; there is no API/WCS for 2 m.

Dependencies: see requirements.txt  (requests, tqdm)
CLI:
    python scripts/download_dtm_ign_spain.py --regions
    python scripts/download_dtm_ign_spain.py castilla_la_mancha --list
    python scripts/download_dtm_ign_spain.py castilla_la_mancha --limit 4
    python scripts/download_dtm_ign_spain.py castilla_la_mancha -i /path/to/models
"""

import os
import sys
import time
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

try:
    from tqdm import tqdm
except ImportError:
    def tqdm(it, **kwargs):
        return it

# Default terrain-models folder: the simulator's data/dtm, relative to this
# script (which lives in the scripts/ folder).
DEFAULT_MODELS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data", "dtm")
MAX_WORKERS = 6
RETRIES = 3
TIMEOUT = 180
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; MDT-IGN-downloader/1.0)"}

# -------- IGN source (WCS) ------------------------------------------- #
WCS_ENDPOINT = "https://servicios.idee.es/wcs-inspire/mdt"
WCS_VERSION = "1.0.0"
COVERAGE = "Elevacion25830_5"          # MDT 5 m in EPSG:25830
CRS_DOWNLOAD = "EPSG:25830"
WCS_FORMAT = "GEOTIFFINT16"            # georeferenced Int16-elevation GeoTIFF
RES_M = 5
TILE_M = 10000                         # tile side in metres (2000 px at 5 m)


# Approximate bounding boxes (with margin) of each peninsular region in
# EPSG:25830, derived from their geographic extent. Adjustable.
BBOX_25830 = {
    "andalucia": (82274, 3980953, 629183, 4307644),
    "aragon": (562260, 4402866, 836919, 4765646),
    "asturias": (149724, 4742177, 386260, 4855891),
    "cantabria": (337285, 4724506, 494922, 4826741),
    "castilla_la_mancha": (264317, 4202845, 691775, 4595103),
    "castilla_y_leon": (142962, 4430309, 613888, 4799945),
    "cataluna": (749890, 4484873, 1045474, 4778176),
    "comunidad_valenciana": (619225, 4181615, 828787, 4531698),
    "extremadura": (92477, 4192927, 367524, 4501983),
    "galicia": (-39388, 4625639, 205601, 4878474),
    "la_rioja": (484568, 4641225, 614892, 4731385),
    "madrid": (355845, 4408109, 503000, 4570823),
    "murcia": (544726, 4125295, 715717, 4305868),
    "navarra": (529391, 4630199, 698084, 4810918),
    "pais_vasco": (455851, 4691190, 614102, 4825780),
    "espana_peninsular": (-39388, 3980953, 1045474, 4878474),
}


class DownloadError(Exception):
    pass


def _cfg(bbox):
    return {
        "endpoint": WCS_ENDPOINT, "wcs_version": WCS_VERSION,
        "coverage": COVERAGE, "crs": CRS_DOWNLOAD, "format": WCS_FORMAT,
        "res_m": RES_M, "tile_m": TILE_M, "bbox": bbox,
    }


# ----------------------- URL_<region> functions ---------------------- #
# Each one returns the download configuration (IGN WCS + EPSG:25830 bbox).

def URL_andalucia():            return _cfg(BBOX_25830["andalucia"])
def URL_aragon():               return _cfg(BBOX_25830["aragon"])
def URL_asturias():             return _cfg(BBOX_25830["asturias"])
def URL_cantabria():            return _cfg(BBOX_25830["cantabria"])
def URL_castilla_la_mancha():   return _cfg(BBOX_25830["castilla_la_mancha"])
def URL_castilla_y_leon():      return _cfg(BBOX_25830["castilla_y_leon"])
def URL_cataluna():             return _cfg(BBOX_25830["cataluna"])
def URL_comunidad_valenciana(): return _cfg(BBOX_25830["comunidad_valenciana"])
def URL_extremadura():          return _cfg(BBOX_25830["extremadura"])
def URL_galicia():              return _cfg(BBOX_25830["galicia"])
def URL_la_rioja():             return _cfg(BBOX_25830["la_rioja"])
def URL_madrid():               return _cfg(BBOX_25830["madrid"])
def URL_murcia():               return _cfg(BBOX_25830["murcia"])
def URL_navarra():              return _cfg(BBOX_25830["navarra"])
def URL_pais_vasco():           return _cfg(BBOX_25830["pais_vasco"])
def URL_espana_peninsular():    return _cfg(BBOX_25830["espana_peninsular"])


REGIONS = {
    "andalucia": URL_andalucia, "aragon": URL_aragon,
    "asturias": URL_asturias, "cantabria": URL_cantabria,
    "castilla_la_mancha": URL_castilla_la_mancha,
    "castilla_y_leon": URL_castilla_y_leon, "cataluna": URL_cataluna,
    "comunidad_valenciana": URL_comunidad_valenciana,
    "extremadura": URL_extremadura, "galicia": URL_galicia,
    "la_rioja": URL_la_rioja, "madrid": URL_madrid, "murcia": URL_murcia,
    "navarra": URL_navarra, "pais_vasco": URL_pais_vasco,
    "espana_peninsular": URL_espana_peninsular,
}

ALIAS = {
    "euskadi": "pais_vasco", "paisvasco": "pais_vasco",
    "valencia": "comunidad_valenciana", "c_valenciana": "comunidad_valenciana",
    "catalunya": "cataluna", "rioja": "la_rioja",
    "clm": "castilla_la_mancha", "cyl": "castilla_y_leon",
    "espana": "espana_peninsular", "espana_peninsula": "espana_peninsular",
}


def _available_names():
    return ", ".join(sorted(REGIONS))


def _resolve_region(region):
    """Validate/normalize the name; raise ValueError listing valid names."""
    if not isinstance(region, str):
        raise ValueError("The name must be a string.\nAvailable: " +
                         _available_names())
    key = region.strip().lower()
    key = ALIAS.get(key, key)
    if key not in REGIONS:
        raise ValueError(
            "Unknown region: '" + str(region) + "'.\n"
            "Write it in lowercase with spaces as '_'.\n"
            "Available: " + _available_names())
    return key


# ------------------------- Tiling and URLs --------------------------- #

def _tiles(bbox, tile_m):
    xmin, ymin, xmax, ymax = bbox
    x = xmin
    while x < xmax:
        x2 = min(x + tile_m, xmax)
        y = ymin
        while y < ymax:
            y2 = min(y + tile_m, ymax)
            yield (x, y, x2, y2)
            y = y2
        x = x2


def _wcs_url(cfg, tile):
    xmin, ymin, xmax, ymax = tile
    w = max(1, int(round((xmax - xmin) / cfg["res_m"])))
    h = max(1, int(round((ymax - ymin) / cfg["res_m"])))
    return ("%s?SERVICE=WCS&VERSION=%s&REQUEST=GetCoverage&COVERAGE=%s"
            "&CRS=%s&BBOX=%.1f,%.1f,%.1f,%.1f&WIDTH=%d&HEIGHT=%d&FORMAT=%s"
            % (cfg["endpoint"], cfg["wcs_version"], cfg["coverage"],
               cfg["crs"], xmin, ymin, xmax, ymax, w, h, cfg["format"]))


def _tile_name(cfg, tile):
    epsg = cfg["crs"].split(":")[-1]
    return ("MDT%02d_%s_%d_%d.tif" %
            (cfg["res_m"], epsg, int(round(tile[0])), int(round(tile[1]))))


def _download_tile(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return "SKIP " + dest
    for attempt in range(RETRIES):
        try:
            with requests.get(url, headers=HEADERS, stream=True,
                              timeout=TIMEOUT) as r:
                r.raise_for_status()
                ctype = r.headers.get("Content-Type", "").lower()
                if "tiff" not in ctype:
                    # the WCS returns XML (ServiceException) with HTTP 200
                    return ("ERROR " + dest + " -> WCS returned non-raster (" +
                            ctype + "): " + r.text[:200].replace("\n", " "))
                with open(dest, "wb") as f:
                    for chunk in r.iter_content(chunk_size=1 << 16):
                        if chunk:
                            f.write(chunk)
            if os.path.getsize(dest) == 0:
                os.remove(dest)
                return "ERROR " + dest + " -> empty file"
            return "OK " + dest
        except Exception as e:
            if attempt < RETRIES - 1:
                time.sleep(2)
            else:
                if os.path.exists(dest):
                    try:
                        os.remove(dest)
                    except OSError:
                        pass
                return "ERROR " + dest + " -> " + str(e)


def _summary(results):
    ok = sum(1 for r in results if r.startswith("OK"))
    skip = sum(1 for r in results if r.startswith("SKIP"))
    err = sum(1 for r in results if r.startswith("ERROR"))
    for r in results:
        if r.startswith("ERROR"):
            print("  ", r)
    print("\nSUMMARY  downloaded=%d  skipped=%d  errors=%d" % (ok, skip, err))
    return {"ok": ok, "skip": skip, "error": err}


# ----------------------------- Dispatcher ---------------------------- #

def download_mdt(region, models_dir=DEFAULT_MODELS_DIR, name_filter=None,
                 max_workers=MAX_WORKERS, list_only=False, limit=None,
                 tile_m=None):
    """Download the MDT (IGN WCS, 5 m, EPSG:25830, GeoTIFF) for a region.

    region      : name in lowercase with '_' (or 'espana_peninsular').
    models_dir  : terrain-models folder where tiles are saved.
    name_filter : substring that the tile name must contain.
    list_only   : dry-run (do not download; list/count and show URLs).
    limit       : maximum number of tiles (for testing).
    tile_m      : tile side in metres (default TILE_M=10000).
    """
    key = _resolve_region(region)
    cfg = REGIONS[key]()
    if tile_m:
        cfg["tile_m"] = tile_m
    print("=" * 60)
    print("Region   : " + key)
    print("Source   : IGN WCS  (" + cfg["coverage"] + ")")
    print("Product  : MDT %d m  %s  %s" %
          (cfg["res_m"], cfg["crs"], cfg["format"]))
    print("bbox     : %s   tile=%d m" % (str(cfg["bbox"]), cfg["tile_m"]))
    print("Models   : " + models_dir)
    print("=" * 60)

    tasks = [(t, os.path.join(models_dir, _tile_name(cfg, t)))
             for t in _tiles(cfg["bbox"], cfg["tile_m"])]
    if name_filter is not None:
        if isinstance(name_filter, str):
            tasks = [(t, d) for (t, d) in tasks if name_filter in d]
        else:
            tasks = [(t, d) for (t, d) in tasks
                     if any(f in d for f in name_filter)]
    print("tiles: " + str(len(tasks)))
    if limit:
        tasks = tasks[:limit]
        print("limited to: " + str(len(tasks)))

    if list_only:
        for t, d in tasks[:8]:
            print("  -", os.path.basename(d))
            print("    ", _wcs_url(cfg, t))
        if len(tasks) > 8:
            print("  ... (+%d more)" % (len(tasks) - 8))
        return {"found": len(tasks), "ok": 0, "skip": 0, "error": 0}

    os.makedirs(models_dir, exist_ok=True)
    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = [ex.submit(_download_tile, _wcs_url(cfg, t), d)
                for (t, d) in tasks]
        for fut in tqdm(as_completed(futs), total=len(futs),
                        desc="Downloading MDT"):
            results.append(fut.result())
    r = _summary(results)
    r["found"] = len(tasks)
    return r


def _main():
    p = argparse.ArgumentParser(
        description="Download IGN MDT 5 m (EPSG:25830, GeoTIFF) by region.")
    p.add_argument("region", nargs="?", help="e.g. castilla_la_mancha")
    p.add_argument("-i", "--input-path", dest="input_path",
                   default=DEFAULT_MODELS_DIR,
                   help="Folder with terrain models (download destination and "
                        "simulator input). Default: data/dtm")
    p.add_argument("-f", "--filter", default=None)
    p.add_argument("-w", "--workers", type=int, default=MAX_WORKERS)
    p.add_argument("-t", "--tile", type=int, default=None,
                   help="tile side in metres (default 10000)")
    p.add_argument("--list", action="store_true", help="dry-run")
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--regions", action="store_true")
    args = p.parse_args()
    if args.regions or not args.region:
        print("Available regions:")
        for n in sorted(REGIONS):
            print("  -", n)
        return
    try:
        download_mdt(args.region, models_dir=args.input_path,
                     name_filter=args.filter, max_workers=args.workers,
                     list_only=args.list, limit=args.limit,
                     tile_m=args.tile)
    except (ValueError, DownloadError) as e:
        print("\n[ERROR] " + str(e))
        sys.exit(1)


if __name__ == "__main__":
    _main()

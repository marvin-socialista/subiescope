#!/usr/bin/env python3
"""Builds the two car tables in Sources/SSMKit/Resources/Cars.

  known_ecus.json   every ECU ID in RomRaider's ROM definitions (definitions/ecu_defs.xml):
                    the car it came in, its calibration ID, its processor and its flash method
  dyno_cars.json    weight, gearing, tyres and drag of the cars in RomRaider's dyno list

Both come from the Subaru definitions the RomRaider community keeps, collected by Merp
(https://github.com/Merp/SubaruDefs). Only the facts are taken over, in a format of our own.

  scripts/build-car-data.py                  downloads the dyno list from the pinned commit
  scripts/build-car-data.py --cars FILE      uses a local cars_def.xml
"""
import argparse
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFINITIONS = ROOT / "definitions" / "ecu_defs.xml"
OUT = ROOT / "Sources" / "SSMKit" / "Resources" / "Cars"
# The last commit that changed the dyno list (version 14, 2011-11-03).
CARS_URL = ("https://raw.githubusercontent.com/Merp/SubaruDefs/"
            "46cfd66bdee1e826ea83aa1e42435b4e1a526143/RomRaider/dyno/cars_def.xml")
POUND_KG = 0.45359237


def year_text(raw):
    """'09' -> '2009', '08/09' -> '2008/09', '04-07' -> '2004-07'."""
    return "20" + raw if raw else None


def known_ecus():
    transmissions = {"MT": "manual", "AT": "automatic", "MT/AT": "manual or automatic"}
    rows = []
    for romid in ET.parse(DEFINITIONS).getroot().iter("romid"):
        field = lambda name: (romid.findtext(name) or "").strip() or None
        if not field("ecuid"):
            continue  # the base definitions are templates, not ROMs
        rows.append({
            "ecuID": field("ecuid").upper(),
            "calID": field("xmlid"),
            "year": year_text(field("year")),
            "market": field("market"),
            "model": " ".join(filter(None, [field("model"), field("submodel")])),
            "transmission": transmissions.get(field("transmission")),
            "processor": field("memmodel"),
            "flashMethod": field("flashmethod"),
        })
    rows.sort(key=lambda r: (r["ecuID"], r["calID"]))
    return rows


def dyno_cars(xml_text):
    words = {"FXT": "Forester XT", "LGT": "Legacy GT", "OBXT": "Outback XT", "WGN": "Wagon", "LTD": "Limited"}
    cars = []
    for car in ET.fromstring(xml_text).iter("car"):
        number = lambda name: float(car.findtext(name))
        kind = car.findtext("type").strip()
        year, rest = kind[:2], kind[3:]
        # A star marks a setup the car did not leave the factory with.
        custom = rest.endswith("*")
        name = " ".join(words.get(word, word) for word in rest.rstrip("*").split())
        gears = [float(g.text) for g in sorted((e for e in car if re.fullmatch(r"gearratio\d", e.tag)), key=lambda e: e.tag)]
        cars.append({
            "name": f"20{year} {name}" + (" (not a factory setup)" if custom else ""),
            "year": 2000 + int(year),
            "curbWeightKg": round(number("carmass") * POUND_KG),
            "finalDrive": number("finalratio"),
            "dragCoefficient": number("dragcoeff"),
            "gearRatios": gears,
            "tireWidthMM": number("tirewidth"),
            "tireAspect": number("tireaspect"),
            "rimInches": number("wheelsize"),
            "automatic": car.findtext("transmission").strip() == "automatic",
        })
    names = [c["name"] for c in cars]
    assert len(names) == len(set(names)), "two cars with the same name"
    cars.sort(key=lambda c: (c["year"], c["name"]))
    return cars


def write(name, rows):
    OUT.mkdir(parents=True, exist_ok=True)
    lines = ",\n".join(json.dumps(row, ensure_ascii=False, separators=(", ", ": ")) for row in rows)
    (OUT / name).write_text("[\n" + lines + "\n]\n", encoding="utf-8")
    print(f"{name}: {len(rows)} rows")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cars", help="a local cars_def.xml instead of the pinned download")
    args = parser.parse_args()
    if args.cars:
        cars_xml = Path(args.cars).read_text(encoding="utf-8")
    else:
        with urllib.request.urlopen(CARS_URL, timeout=30) as response:
            cars_xml = response.read().decode("utf-8")
    write("known_ecus.json", known_ecus())
    write("dyno_cars.json", dyno_cars(cars_xml))


if __name__ == "__main__":
    sys.exit(main())

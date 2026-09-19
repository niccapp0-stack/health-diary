"""Re-render the ride pages with the current templates at deploy time.

The PC refresh commits bosch_dashboard.html and bosch_ride_map.html built with
whatever templates its copy of the script carried. This step pulls the data
blobs out of those committed pages and renders them again with the templates
in this folder, so template fixes reach the website without touching the PC.

Usage:  python3 site/render.py <repo_root> <output_dir>
"""

import re
import shutil
import sys
from pathlib import Path


def grab(text: str, pattern: str) -> str | None:
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else None


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    here = root / "site"
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(root, out, ignore=shutil.ignore_patterns(".git", ".github", "_site", "site", "*.csv", "*.log", "*.ps1"))

    dash_src = (root / "bosch_dashboard.html").read_text(encoding="utf-8")
    map_src = (root / "bosch_ride_map.html").read_text(encoding="utf-8")
    rides = grab(dash_src, r"^const RIDES = (.*);$")
    geo = grab(dash_src, r"^const GEO = (.*);$")
    today = grab(dash_src, r"^const TODAY = new Date\('([0-9-]+)T00:00:00Z'\);$")
    data = grab(map_src, r"^const DATA = (.*);$")

    if rides and geo:
        t = (here / "ridebook_template.html").read_text(encoding="utf-8")
        t = t.replace("__DATA__", rides).replace("__GEO__", geo)
        if today:
            t = t.replace("const TODAY = new Date('2026-09-18T00:00:00Z');", f"const TODAY = new Date('{today}T00:00:00Z');")
        (out / "bosch_dashboard.html").write_text(t, encoding="utf-8")
        print("dashboard re-rendered")
    else:
        print("dashboard left as committed (data not found)")

    if data:
        t = (here / "ridemap_osm_template.html").read_text(encoding="utf-8")
        (out / "bosch_ride_map.html").write_text(t.replace("__DATA__", data), encoding="utf-8")
        print("ride map re-rendered")
    else:
        print("ride map left as committed (data not found)")


if __name__ == "__main__":
    main()

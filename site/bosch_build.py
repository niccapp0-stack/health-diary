"""Build the ride dashboard and ride map pages from bosch_rides.csv and bosch_tracks.csv.

Usage:  python bosch_build.py <folder> <template_dir>

Reads <folder>/bosch_rides.csv and <folder>/bosch_tracks.csv, and writes
<folder>/bosch_dashboard.html and <folder>/bosch_ride_map.html using the
templates ridebook_template.html and ridemap_osm_template.html.
"""

import csv
import json
import math
import sys
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

LAT0, LON0 = -37.82, 145.05
K = 111.32 * math.cos(math.radians(LAT0))
LANDMARKS = [
    ("Melbourne CBD", -37.8136, 144.9631), ("St Kilda", -37.8676, 144.9740), ("Elwood", -37.8820, 144.9820),
    ("Brighton", -37.9061, 144.9970), ("Williamstown", -37.8590, 144.8980), ("Richmond", -37.8230, 144.9980),
    ("Hawthorn", -37.8220, 145.0350), ("Kew", -37.8060, 145.0310), ("Glen Iris", -37.8575, 145.0583),
    ("Malvern", -37.8580, 145.0290), ("Caulfield", -37.8770, 145.0420), ("Camberwell", -37.8421, 145.0708),
    ("Burwood", -37.8497, 145.1129), ("Box Hill", -37.8192, 145.1224), ("Glen Waverley", -37.8783, 145.1648),
    ("Oakleigh", -37.9000, 145.0890), ("Moorabbin", -37.9425, 145.0580), ("Cheltenham", -37.9670, 145.0540),
    ("Mordialloc", -38.0050, 145.0880), ("Doncaster", -37.7883, 145.1235), ("Templestowe", -37.7560, 145.1230),
    ("Heidelberg", -37.7566, 145.0700), ("Coburg", -37.7443, 144.9640), ("Dandenong", -37.9874, 145.2149),
    ("Frankston", -38.1414, 145.1225), ("Sorrento", -38.3395, 144.7427), ("Woodend", -37.3574, 144.5286),
    ("Lilydale", -37.7565, 145.3510), ("Yarra Junction", -37.7811, 145.6144), ("Warburton", -37.7529, 145.6906),
    ("Eltham", -37.7150, 145.1490), ("Ringwood", -37.8140, 145.2290),
]


def xy(la, lo):
    return ((lo - LON0) * K, (la - LAT0) * 110.57)


def num(r, c):
    return float(r[c]) if r.get(c, "") not in ("", None) else None


PRIVACY_M = 400  # metres hidden around the start and end of every ride


def metres(a, b):
    return math.hypot((a[0] - b[0]) * 110570, (a[1] - b[1]) * 88000)


def privacy_trim(p, zones):
    """Drop every point within PRIVACY_M of the ride's own start and finish, and of the fixed zones."""
    if len(p) < 3:
        return []
    centres = [p[0], p[-1]] + list(zones)
    out = [q for q in p if all(metres(q, c) >= PRIVACY_M for c in centres)]
    return out if len(out) >= 2 else []


def load(folder: Path):
    rides = list(csv.DictReader((folder / "bosch_rides.csv").open(encoding="utf-8")))
    tracks = defaultdict(list)
    tp = folder / "bosch_tracks.csv"
    if tp.exists():
        for r in csv.DictReader(tp.open(encoding="utf-8")):
            if r["lat"] and r["lon"]:
                tracks[r["rideId"]].append((
                    float(r["lat"]), float(r["lon"]), float(r["distM"] or 0),
                    float(r["elevM"]) if r["elevM"] else None,
                    float(r["speedKmh"] or 0), float(r["powerW"] or 0),
                ))
    raw_starts = [p[0] for p in tracks.values() if p]
    home, zones = None, []
    if raw_starts:
        lat = sorted(q[0] for q in raw_starts)[len(raw_starts) // 2]
        lon = sorted(q[1] for q in raw_starts)[len(raw_starts) // 2]
        zones.append((lat, lon))
        # any place where 4 or more rides begin is treated as a home zone too
        seen = []
        for s in raw_starts:
            for z in seen:
                if metres(s, z[0]) < 600:
                    z[1] += 1
                    break
            else:
                seen.append([s, 1])
        zones += [z[0] for z in seen if z[1] >= 4]
        name, hla, hlo = min(LANDMARKS, key=lambda l: metres((l[1], l[2]), (lat, lon)))
        home = [hla, hlo, name]
    tracks = {rid: privacy_trim(p, zones) for rid, p in tracks.items()}
    tracks = {rid: p for rid, p in tracks.items() if p}
    return rides, tracks, home


def ride_records(rides):
    out = []
    for r in rides:
        out.append({
            "id": r["id"], "d": r["date"], "t": r["startTime"][11:16], "dur": int(num(r, "durationSec") or 0),
            "km": num(r, "distanceKm"), "sp": num(r, "avgSpeedKmh"), "msp": num(r, "maximumSpeed") if "maximumSpeed" in r else num(r, "maxSpeedKmh"),
            "cad": num(r, "avgCadence"), "pw": num(r, "avgRiderPowerW"), "mpw": num(r, "maxRiderPowerW"),
            "up": num(r, "elevationGainM"), "dn": num(r, "elevationLossM"), "cal": num(r, "caloriesBurnt"),
            "sh": num(r, "riderEnergySharePct"), "co2": num(r, "co2SavedGrams"),
            "abs": num(r, "absInterventions"), "brk": num(r, "normalBrakeEvents"), "title": r.get("title", ""),
            "m": [num(r, "assist_OFF_m") or 0, num(r, "assist_ECO_m") or 0, num(r, "assist_TOUR+_m") or 0,
                  num(r, "assist_AUTO_m") or 0, num(r, "assist_TURBO_m") or 0],
        })
    return out


def geo_data(tracks):
    lm = [[n, round(xy(la, lo)[0], 2), round(xy(la, lo)[1], 2)] for n, la, lo in LANDMARKS]

    def near(x, y):
        return min(((math.hypot(lx - x, ly - y), n) for n, lx, ly in lm))[1]

    def lmxy(n):
        return next((x, y) for m, x, y in lm if m == n)

    ids = list(tracks)
    cells = {rid: set((int(x // 0.4), int(y // 0.4)) for x, y in (xy(a, b) for a, b, *_ in tracks[rid])) for rid in ids}
    parent = {r: r for r in ids}

    def find(r):
        while parent[r] != r:
            parent[r] = parent[parent[r]]
            r = parent[r]
        return r

    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            if cells[a] and cells[b] and len(cells[a] & cells[b]) / len(cells[a] | cells[b]) >= 0.45:
                parent[find(a)] = find(b)
    groups = defaultdict(list)
    for r in ids:
        groups[find(r)].append(r)
    gl = sorted(groups.values(), key=len, reverse=True)

    out_tracks, far = {}, {}
    for rid, p in tracks.items():
        step = max(1, math.ceil(len(p) / 80))
        pts = [xy(a, b) for a, b, *_ in p][::step]
        if len(p) > 1:
            pts.append(xy(p[-1][0], p[-1][1]))
        out_tracks[rid] = [[round(x, 2), round(y, 2)] for x, y in pts]
        sx, sy = xy(p[0][0], p[0][1])
        far[rid] = round(max(math.hypot(x - sx, y - sy) for x, y in (xy(a, b) for a, b, *_ in p)), 1)

    clusters = []
    for g in gl:
        if len(g) < 2:
            continue
        starts = Counter(near(*out_tracks[rid][0]) for rid in g)
        home = starts.most_common(1)[0][0]
        hx, hy = lmxy(home)
        fars = []
        for rid in g:
            t = out_tracks[rid]
            fp = max(t, key=lambda q: math.hypot(q[0] - hx, q[1] - hy))
            fars.append((math.hypot(fp[0] - hx, fp[1] - hy), fp))
        fars.sort(key=lambda z: z[0])
        mid = fars[len(fars) // 2]
        clusters.append({"start": home, "dest": near(*mid[1]), "far": round(mid[0], 1), "ids": g})

    bins = defaultdict(lambda: [0, 0.0, 0.0])
    for rid, p in tracks.items():
        for i in range(1, len(p)):
            d = p[i][2] - p[i - 1][2]
            if d < 20 or p[i][3] is None or p[i - 1][3] is None:
                continue
            g = 100 * (p[i][3] - p[i - 1][3]) / d
            b = max(-8, min(8, int(math.floor(g / 2)) * 2))
            bins[b][0] += 1
            bins[b][1] += p[i][4 + 1]
            bins[b][2] += p[i][4]
    return {
        "lm": lm,
        "bins": [[b, v[0], round(v[1] / v[0]), round(v[2] / v[0], 1)] for b, v in sorted(bins.items())],
        "clusters": clusters,
        "singles": [g[0] for g in gl if len(g) == 1],
        "tracks": out_tracks,
        "far": far,
    }


def map_data(records, tracks, home):
    out = []
    for rec in records:
        p = tracks.get(rec["id"], [])
        step = max(1, math.ceil(len(p) / 150))
        pts = p[::step]
        if len(p) > 1 and pts[-1] != p[-1]:
            pts.append(p[-1])
        m = dict(rec)
        m["pts"] = [[round(a, 5), round(b, 5), round(s / 1000, 2), None if h is None else round(h), round(v, 1), round(w)]
                    for a, b, s, h, v, w in pts]
        out.append(m)
    return {"rides": out, "home": home, "privacyM": PRIVACY_M}


def main():
    folder = Path(sys.argv[1])
    tdir = Path(sys.argv[2]) if len(sys.argv) > 2 else folder
    rides, tracks, home = load(folder)
    if not rides:
        print("No rides found.")
        sys.exit(1)
    records = ride_records(rides)
    geo = geo_data(tracks)
    today = date.today().isoformat()
    js = lambda o: json.dumps(o, separators=(",", ":"))

    dash = (tdir / "ridebook_template.html").read_text(encoding="utf-8-sig")
    dash = dash.replace("__DATA__", js(records)).replace("__GEO__", js(geo))
    dash = dash.replace("const TODAY = new Date('2026-09-18T00:00:00Z');", f"const TODAY = new Date('{today}T00:00:00Z');")
    (folder / "bosch_dashboard.html").write_text(dash, encoding="utf-8")

    mp = (tdir / "ridemap_osm_template.html").read_text(encoding="utf-8-sig")
    mp = mp.replace("__DATA__", js(map_data(records, tracks, home)))
    (folder / "bosch_ride_map.html").write_text(mp, encoding="utf-8")

    dates = sorted(r["date"] for r in rides)
    from datetime import datetime, timezone
    status = {
        "updated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "rides": len(rides),
        "km": round(sum(num(r, "distanceKm") or 0 for r in rides), 1),
        "firstRide": dates[0],
        "lastRide": dates[-1],
        "withGps": len(tracks),
    }
    (folder / "bosch_status.json").write_text(json.dumps(status), encoding="utf-8")
    print(f"Built pages for {len(rides)} rides ({dates[0]} to {dates[-1]}), {len(tracks)} with GPS.")
    print(f"  {folder / 'bosch_dashboard.html'}")
    print(f"  {folder / 'bosch_ride_map.html'}")


if __name__ == "__main__":
    main()

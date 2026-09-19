# Bosch ride refresh
# Pulls new rides and GPS tracks from Bosch eBike Flow, rebuilds bosch_dashboard.html and
# bosch_ride_map.html in your health-diary folder, and pushes to GitHub if the folder is a git clone.
#
# One time setup (installs the nightly task, then runs the first refresh):
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\bosch_refresh.ps1" -Install
# If the Bosch login ever expires:
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\bosch_refresh.ps1" -Login

param([switch]$Install, [switch]$Login)
$ErrorActionPreference = 'Continue'
$Folder = Join-Path $env:USERPROFILE 'health-diary'
$Work   = Join-Path $env:LOCALAPPDATA 'bosch-export'
$Config = Join-Path $Work 'config'
$Log    = Join-Path $Folder 'bosch_refresh.log'
New-Item -ItemType Directory -Force -Path $Folder, $Work, $Config | Out-Null
$env:BOSCH_FLOW_MCP_CONFIG_DIR = $Config
$env:BOSCH_FLOW_MCP_DB_PATH    = Join-Path $Work 'bosch_flow.db'
$env:Path = (Join-Path $env:USERPROFILE '.local\bin') + ';' + $env:Path

function Log($m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"; Write-Host $line; Add-Content -Path $Log -Value $line }
if ((Test-Path $Log) -and ((Get-Item $Log).Length -gt 1MB)) { Remove-Item $Log -Force }

# ---- uv (provides uvx) ------------------------------------------------------
if (-not (Test-Path (Join-Path $env:USERPROFILE '.local\bin\uvx.exe'))) {
    Log 'Installing uv...'
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
}

# ---- embedded programs and page templates -----------------------------------
@'
"""Pull the full Bosch eBike Flow ride history and write it to a CSV.

Usage:  python bosch_export.py <csv_path> [<capture_file>]

Runs on top of the bosch-flow-mcp package and reuses its own login, API and
ride parsing code, so the rows match what the bosch_get_activities MCP tool
returns. The optional capture file is written by a Windows protocol handler
when the browser hands the onebikeapp-ios:// redirect back to us, which avoids
the DevTools copy step. Manual paste still works as a fallback.
"""

import csv
import secrets
import sys
import threading
import time
import webbrowser
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

from bosch_flow_mcp import api
from bosch_flow_mcp.auth import _exchange_code, _generate_pkce, refresh_token
from bosch_flow_mcp.config import (
    ACTIVITY_API_BASE,
    ACTIVITY_LIST,
    BOSCH_AUTH_URL,
    BOSCH_TOKENS_PATH,
    CLIENT_ID,
    REDIRECT_URI,
    SCOPE,
)
from bosch_flow_mcp.tools.activity_tools import _fetch_all_summaries, _parse_summary

LOGIN_TIMEOUT_SEC = 600


def already_logged_in() -> bool:
    if not BOSCH_TOKENS_PATH.exists():
        return False
    try:
        refresh_token()
        api.get(f"{ACTIVITY_LIST}?size=1", base=ACTIVITY_API_BASE)
        return True
    except Exception:
        return False


def wait_for_redirect(capture: Path | None) -> str:
    """Return the redirect URL, from the capture file or a manual paste."""
    result: dict = {}

    def reader() -> None:
        try:
            line = input("> ").strip()
        except EOFError:
            return
        if line:
            result.setdefault("url", line)

    threading.Thread(target=reader, daemon=True).start()

    deadline = time.time() + LOGIN_TIMEOUT_SEC
    while time.time() < deadline:
        if "url" in result:
            return result["url"]
        if capture and capture.exists():
            text = capture.read_text(encoding="utf-8", errors="ignore").strip()
            if "code=" in text:
                return text
        time.sleep(0.5)
    print("Timed out waiting for the login.", file=sys.stderr)
    sys.exit(1)


def login(capture: Path | None) -> None:
    verifier, challenge = _generate_pkce()
    state = secrets.token_urlsafe(16)
    url = BOSCH_AUTH_URL + "?" + urlencode(
        {
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "response_type": "code",
            "scope": SCOPE,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "kc_idp_hint": "skid",
            "prompt": "login",
            "nonce": secrets.token_urlsafe(16),
            "state": state,
        }
    )
    if capture and capture.exists():
        capture.unlink()

    print("\nBosch eBike Flow login")
    print("=" * 50)
    print("A browser window will open. Sign in with your Bosch SingleKey ID.")
    print("When the browser asks to open a link or an app, click Open / Allow.")
    print("This window will then continue on its own.")
    print("\nIf the browser does not open, copy this address into it:\n")
    print(url)
    print("\nFallback: if nothing happens after signing in, paste the URL from")
    print("the DevTools Network row named oauth2redirect here and press Enter.\n")
    webbrowser.open(url)

    redirect_url = wait_for_redirect(capture)
    qs = parse_qs(urlparse(redirect_url).query)
    if "code" not in qs:
        print("No login code found in the redirect.", file=sys.stderr)
        sys.exit(1)
    if qs.get("state", [None])[0] != state:
        print("Login state did not match. Run the script again.", file=sys.stderr)
        sys.exit(1)
    _exchange_code(CLIENT_ID, qs["code"][0], verifier, REDIRECT_URI)
    if capture and capture.exists():
        capture.unlink()
    print("Login complete.\n")


def flatten(ride: dict, modes: list[str]) -> dict:
    row = {k: v for k, v in ride.items() if k != "assistModeMeters"}
    used = ride.get("assistModeMeters") or {}
    for m in modes:
        row[f"assist_{m}_m"] = used.get(m)
    return row


def export(csv_path: Path) -> None:
    print("Fetching ride history from Bosch...")
    raw, truncated = _fetch_all_summaries(max_pages=100)
    rides = [r for r in (_parse_summary(item) for item in raw) if r["date"] is not None]
    rides.sort(key=lambda r: r["startEpoch"] or 0)

    modes: list[str] = []
    for r in rides:
        for m in (r.get("assistModeMeters") or {}):
            if m not in modes:
                modes.append(m)

    base_cols = [k for k in (rides[0].keys() if rides else []) if k != "assistModeMeters"]
    if not rides:
        base_cols = [k for k in _parse_summary({}).keys() if k != "assistModeMeters"]
    cols = base_cols + [f"assist_{m}_m" for m in modes]

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rides:
            w.writerow(flatten(r, modes))

    print("\nDone.")
    print(f"Total rides pulled: {len(rides)}")
    if rides:
        print(f"Date range: {rides[0]['date']} to {rides[-1]['date']}")
    print(f"File: {csv_path}")
    if truncated:
        print("Note: the API page cap was reached, so some older rides may be missing.")


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    csv_path = Path(sys.argv[1])
    capture = None

    if already_logged_in():
        print("Using the saved Bosch login.")
    elif "--no-login" in sys.argv:
        print("The saved Bosch login has expired. Run the refresh script with -Login to sign in again.", file=sys.stderr)
        sys.exit(2)
    else:
        login(capture)
    export(csv_path)


if __name__ == "__main__":
    main()
'@ | Set-Content -Path (Join-Path $Work 'bosch_export.py') -Encoding ASCII

@'
"""Fetch the GPS track of every ride listed in bosch_rides.csv.

Usage:  python bosch_tracks.py <rides_csv> <tracks_csv>

Writes one row per track point: ride id, date, point index, latitude,
longitude, cumulative distance (m), speed (km/h), elevation (m), cadence (rpm)
and rider power (W). Rides already present in the output file are skipped, so
the script can be re-run to pick up new rides.
"""

import csv
import sys
import time
from pathlib import Path

from bosch_flow_mcp import api
from bosch_flow_mcp.config import ACTIVITY_API_BASE, ACTIVITY_DETAIL

COLS = ["rideId", "date", "idx", "lat", "lon", "distM", "speedKmh", "elevM", "cadence", "powerW"]


def main() -> None:
    rides_csv, tracks_csv = Path(sys.argv[1]), Path(sys.argv[2])
    rides = list(csv.DictReader(rides_csv.open(encoding="utf-8")))

    done = set()
    if tracks_csv.exists():
        with tracks_csv.open(encoding="utf-8") as f:
            done = {r["rideId"] for r in csv.DictReader(f)}
    todo = [r for r in rides if r["id"] not in done]
    print(f"{len(rides)} rides in file, {len(done)} already fetched, {len(todo)} to fetch")

    new_file = not tracks_csv.exists()
    failed = []
    with tracks_csv.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        if new_file:
            w.writeheader()
        for n, r in enumerate(todo, 1):
            rid, date = r["id"], r["date"]
            try:
                det = api.get(ACTIVITY_DETAIL.format(activity_id=rid), base=ACTIVITY_API_BASE)
            except api.BoschRateLimitError:
                print("  rate limited, waiting 30 s")
                time.sleep(30)
                det = api.get(ACTIVITY_DETAIL.format(activity_id=rid), base=ACTIVITY_API_BASE)
            except api.BoschAPIError as e:
                print(f"  {date}: {e}")
                failed.append(rid)
                continue
            pts = (((det or {}).get("data") or {}).get("attributes") or {}).get("activityData") or []
            for i, p in enumerate(pts):
                w.writerow({
                    "rideId": rid, "date": date, "idx": i,
                    "lat": p.get("lat"), "lon": p.get("lon"), "distM": p.get("s"),
                    "speedKmh": p.get("v"), "elevM": p.get("h"), "cadence": p.get("c"),
                    "powerW": p.get("p"),
                })
            f.flush()
            print(f"  {n}/{len(todo)}  {date}  {len(pts)} points")
            time.sleep(0.3)

    print("")
    print("Done.")
    print(f"File: {tracks_csv}")
    if failed:
        print(f"{len(failed)} rides had no track data.")


if __name__ == "__main__":
    main()
'@ | Set-Content -Path (Join-Path $Work 'bosch_tracks.py') -Encoding ASCII

@'
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
'@ | Set-Content -Path (Join-Path $Work 'bosch_build.py') -Encoding ASCII

@'
<title>Nic's Ride Book</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow+Semi+Condensed:wght@500;600;700&family=Source+Sans+3:ital,wght@0,400;0,600;1,400&display=swap">
<style>
:root{
  color-scheme:light;
  --plane:#f4f5f2; --surface:#fcfcfb; --ink:#101412; --ink-2:#545b57; --muted:#858b87;
  --grid:#e2e4df; --axis:#c4c7c1; --ring:rgba(16,20,18,.10); --hover:rgba(16,20,18,.05);
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#eda100; --s5:#e87ba4;
  --seq1:#cde2fb; --seq2:#9ec5f4; --seq3:#6da7ec; --seq4:#3987e5; --seq5:#256abf; --seq6:#184f95; --seq7:#0d366b;
  --good:#006300; --tip-bg:#101412; --tip-ink:#fcfcfb;
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    color-scheme:dark;
    --plane:#0e0f0e; --surface:#1a1b1a; --ink:#f4f4f1; --ink-2:#c3c5bf; --muted:#8d918c;
    --grid:#2b2d2a; --axis:#3b3d3a; --ring:rgba(255,255,255,.10); --hover:rgba(255,255,255,.06);
    --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181;
    --seq1:#184f95; --seq2:#1c5cab; --seq3:#256abf; --seq4:#2a78d6; --seq5:#3987e5; --seq6:#6da7ec; --seq7:#9ec5f4;
    --good:#0ca30c; --tip-bg:#f4f4f1; --tip-ink:#101412;
  }
}
:root[data-theme="dark"]{
  color-scheme:dark;
  --plane:#0e0f0e; --surface:#1a1b1a; --ink:#f4f4f1; --ink-2:#c3c5bf; --muted:#8d918c;
  --grid:#2b2d2a; --axis:#3b3d3a; --ring:rgba(255,255,255,.10); --hover:rgba(255,255,255,.06);
  --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181;
  --seq1:#184f95; --seq2:#1c5cab; --seq3:#256abf; --seq4:#2a78d6; --seq5:#3987e5; --seq6:#6da7ec; --seq7:#9ec5f4;
  --good:#0ca30c; --tip-bg:#f4f4f1; --tip-ink:#101412;
}
*{box-sizing:border-box}
body{margin:0;background:var(--plane);color:var(--ink);font:16px/1.5 "Source Sans 3",system-ui,-apple-system,"Segoe UI",sans-serif}
.wrap{max-width:1120px;margin:0 auto;padding-block:28px 64px;padding-inline:20px}
h1,h2,h3,.num{font-family:"Barlow Semi Condensed","Source Sans 3",system-ui,sans-serif;text-wrap:balance}
h1{font-size:2.4rem;line-height:1.05;margin:0;font-weight:700;letter-spacing:-.01em}
.sub{color:var(--ink-2);margin:6px 0 0;max-width:62ch}
header.top{display:flex;flex-wrap:wrap;gap:18px 32px;align-items:flex-end;justify-content:space-between;margin-bottom:22px}
.filters{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.filters label{font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-right:4px}
.chip{border:1px solid var(--ring);background:var(--surface);color:var(--ink);font:inherit;font-size:.9rem;padding:6px 12px;border-radius:999px;cursor:pointer}
.chip:hover{background:var(--hover)}
.chip[aria-pressed="true"]{background:var(--ink);color:var(--surface);border-color:var(--ink)}
.chip:focus-visible,.tog:focus-visible{outline:2px solid var(--s1);outline-offset:2px}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:2px;background:var(--ring);border:1px solid var(--ring);border-radius:10px;overflow:hidden;margin-bottom:40px}
.kpi{background:var(--surface);padding:14px 16px 12px}
.kpi .lab{font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.kpi .num{font-size:2rem;font-weight:600;line-height:1.1;margin-top:2px}
.kpi .num small{font-size:.95rem;font-weight:500;color:var(--ink-2);margin-left:3px}
.kpi .note{font-size:.85rem;color:var(--ink-2)}
section.block{margin-bottom:48px}
.block>h2{font-size:1.6rem;margin:0 0 4px;font-weight:600}
.block>p.lead{margin:0 0 18px;color:var(--ink-2);max-width:70ch}
.grid{display:grid;grid-template-columns:repeat(12,1fr);gap:16px}
.card{grid-column:span 12;background:var(--surface);border:1px solid var(--ring);border-radius:10px;padding:16px 18px 12px;min-width:0}
.card.half{grid-column:span 6}
.card.third{grid-column:span 4}
@media (max-width:820px){.card.half,.card.third{grid-column:span 12}}
.card header{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;margin-bottom:8px}
.card h3{font-size:1.15rem;margin:0;font-weight:600}
.card .why{margin:2px 0 0;font-size:.9rem;color:var(--ink-2)}
.tog{flex:none;border:1px solid var(--ring);background:transparent;color:var(--ink-2);font:inherit;font-size:.8rem;padding:3px 10px;border-radius:6px;cursor:pointer}
.tog:hover{background:var(--hover)}
.tog[aria-pressed="true"]{background:var(--ink);color:var(--surface);border-color:var(--ink)}
.viz svg{display:block;width:100%;height:auto;overflow:visible}
.viz{position:relative}
.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:.85rem;color:var(--ink-2);margin:6px 0 2px}
.legend span{display:inline-flex;align-items:center;gap:6px}
.legend i{display:inline-block;width:12px;height:12px;border-radius:2px}
.legend i.line{height:2px;width:16px;border-radius:1px}
.tbl{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:.9rem;font-variant-numeric:tabular-nums}
th,td{padding:6px 10px;text-align:right;border-bottom:1px solid var(--grid);white-space:nowrap}
th:first-child,td:first-child{text-align:left}
th{font-weight:600;color:var(--ink-2);font-size:.8rem;text-transform:uppercase;letter-spacing:.06em}
svg text{font-family:"Source Sans 3",system-ui,sans-serif;font-size:12px;fill:var(--muted)}
svg text.val{fill:var(--ink-2);font-variant-numeric:tabular-nums}
svg text.end{fill:var(--ink);font-weight:600}
svg .grid line{stroke:var(--grid);stroke-width:1}
svg .axis{stroke:var(--axis);stroke-width:1}
svg .dot{fill:var(--s1);opacity:.32}
svg .med{fill:none;stroke:var(--s1);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
svg .medpt{fill:var(--s1);stroke:var(--surface);stroke-width:2}
svg .bar{fill:var(--s1)}
svg .bar:hover,svg .cell:hover,svg .seg:hover{filter:brightness(1.18)}
svg .hit{fill:transparent;pointer-events:all}
svg .xh{stroke:var(--axis);stroke-width:1;pointer-events:none}
.tip{position:fixed;z-index:10;pointer-events:none;background:var(--tip-bg);color:var(--tip-ink);padding:8px 10px;border-radius:6px;font-size:.85rem;line-height:1.35;box-shadow:0 4px 14px rgba(0,0,0,.18);max-width:260px}
.tip .h{font-weight:600;margin-bottom:3px}
.tip .r{display:flex;gap:8px;align-items:center;justify-content:space-between}
.tip .r i{display:inline-block;width:12px;height:2px;border-radius:1px;flex:none}
.tip .r b{font-weight:600;font-variant-numeric:tabular-nums}
.tip .r span{opacity:.8}
.bars{display:grid;grid-template-columns:auto 1fr;gap:8px 14px;align-items:center;font-size:.92rem}
.bars .row{display:contents}
.bars .name{font-weight:600}
.bars .name small{display:block;font-weight:400;color:var(--muted);font-size:.8rem}
.bars .track{display:grid;gap:4px}
.bars .b{display:grid;grid-template-columns:92px 1fr 48px;align-items:center;gap:8px;font-size:.82rem;color:var(--ink-2)}
.bars .b i{display:block;height:10px;border-radius:0 3px 3px 0;background:var(--s1);min-width:2px}
.bars .b i.t{background:var(--s5)}
.bars .b b{text-align:right;font-variant-numeric:tabular-nums;color:var(--ink)}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px 20px;margin:4px 0 6px}
.stat .lab{font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.stat .num{font-size:1.6rem;font-weight:600;line-height:1.15}
.stat .num small{font-size:.9rem;font-weight:500;color:var(--ink-2);margin-left:2px}
.stat .note{font-size:.85rem;color:var(--ink-2)}
.foot{color:var(--muted);font-size:.85rem;margin-top:32px;max-width:70ch}
.zoom{display:flex;gap:6px;justify-content:flex-end;margin:-4px 0 8px}
.zoom .chip{font-size:.82rem;padding:4px 10px}
.routes{display:grid;gap:12px}
.route{display:grid;grid-template-columns:120px 1fr;gap:14px;align-items:center;padding:10px 0;border-top:1px solid var(--grid)}
.route:first-child{border-top:0;padding-top:0}
.route .mini{width:120px;height:84px;flex:none}
.rname{font-weight:600;font-size:1.02rem;display:flex;align-items:center;gap:8px}
.rname i{display:inline-block;width:18px;height:3px;border-radius:2px}
.rmeta{font-size:.85rem;color:var(--ink-2);margin:2px 0 6px}
.rstats{display:flex;flex-wrap:wrap;gap:4px 18px;font-size:.85rem}
.rstats div{display:flex;flex-direction:column}
.rstats span{color:var(--muted);font-size:.75rem;text-transform:uppercase;letter-spacing:.06em}
.rstats b{font-weight:600;font-variant-numeric:tabular-nums}
@media (max-width:520px){.route{grid-template-columns:1fr}.route .mini{width:100%;height:auto}}
body.embed h1{font-size:1.6rem}
body.embed .sub{display:none}
body.embed .wrap{padding-block:16px 48px}
@media (prefers-reduced-motion:no-preference){.chip,.tog{transition:background .15s}}
</style>

<div class="wrap">
  <header class="top">
    <div>
      <h1>Nic's Ride Book</h1>
      <p class="sub" id="subline"></p>
    </div>
    <div class="filters" role="group" aria-label="Date range">
      <label>Range</label>
      <button class="chip" data-range="all" aria-pressed="true" id="r-all">All rides</button>
      <button class="chip" data-range="2025" aria-pressed="false" id="r-2025">2025</button>
      <button class="chip" data-range="2026" aria-pressed="false" id="r-2026">2026</button>
      <button class="chip" data-range="12m" aria-pressed="false" id="r-12m">Last 12 months</button>
      <button class="chip" data-range="90d" aria-pressed="false" id="r-90d">Last 90 days</button>
    </div>
  </header>

  <div class="kpis" id="kpis"></div>

  <section class="block" id="where">
    <h2>Where you ride</h2>
    <p class="lead">Every ride with a GPS track, drawn from the Bosch app's route data. Rides that overlap the same streets are grouped into routes, named by the suburb they start from and the furthest point they reach. Hover a line for that ride's numbers.</p>
    <div class="grid" id="where-grid"></div>
  </section>

  <section class="block" id="fitness">
    <h2>Fitness trend</h2>
    <p class="lead">Rider power is what your legs put in, independent of the motor. Energy share is the slice of the total work you did yourself. Each dot is one ride; the line joins the monthly medians and breaks where a month had no rides.</p>
    <div class="grid" id="fit-grid"></div>
  </section>

  <section class="block" id="habit">
    <h2>Habit and consistency</h2>
    <p class="lead">How often the bike actually goes out, where the gaps are, and what a realistic weekly target looks like based on the weeks you did ride.</p>
    <div class="grid" id="habit-grid"></div>
  </section>

  <section class="block" id="effort">
    <h2>Effort profile</h2>
    <p class="lead">How hard the rides are and where the motor takes over. The gradient charts come from the GPS tracks, point by point, and show what your legs do when the road tilts up.</p>
    <div class="grid" id="effort-grid"></div>
  </section>

  <p class="foot">Source: Bosch eBike Flow ride summaries pulled through the rider activity API. Heart rate is not recorded because the bike has no sensor. Climbing is metres of elevation gain. Times are Melbourne local time.</p>
</div>
<div class="tip" id="tip" hidden></div>

<script>
const RIDES = __DATA__;
const MODES = ['Off','Eco','Tour+','Auto','Turbo'];
const MODE_COL = ['var(--s1)','var(--s2)','var(--s3)','var(--s4)','var(--s5)'];
const TODAY = new Date('2026-09-18T00:00:00Z');
const NS = 'http://www.w3.org/2000/svg';
const MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const DOW = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

RIDES.forEach(r => {
  r.dt = new Date(r.d + 'T00:00:00Z');
  r.ym = r.d.slice(0,7);
  r.dow = (r.dt.getUTCDay() + 6) % 7;
  r.hr = parseInt(r.t.slice(0,2), 10);
  const tot = r.m.reduce((a,b)=>a+b,0) || 1;
  r.turbo = 100 * r.m[4] / tot;
  r.climb = r.km > 0 ? r.up / r.km : 0;
  r.terrain = r.climb < 5 ? 0 : r.climb < 10 ? 1 : 2;
});
RIDES.sort((a,b)=>a.dt-b.dt);

/* ---------- helpers ---------- */
function el(tag, attrs, parent){ const e=document.createElementNS(NS,tag); for(const k in attrs) e.setAttribute(k, attrs[k]); if(parent) parent.appendChild(e); return e; }
function txt(parent,x,y,s,cls,anchor){ const t=el('text',{x,y,'text-anchor':anchor||'start'},parent); if(cls) t.setAttribute('class',cls); t.textContent=s; return t; }
function h(tag, cls, parent, text){ const e=document.createElement(tag); if(cls) e.className=cls; if(text!=null) e.textContent=text; if(parent) parent.appendChild(e); return e; }
function lin(d0,d1,r0,r1){ const f=v=>r0+(v-d0)*(r1-r0)/(d1-d0||1); f.inv=p=>d0+(p-r0)*(d1-d0)/(r1-r0||1); return f; }
function median(a){ if(!a.length) return null; const s=[...a].sort((x,y)=>x-y); const m=s.length>>1; return s.length%2? s[m] : (s[m-1]+s[m])/2; }
function mean(a){ return a.length? a.reduce((x,y)=>x+y,0)/a.length : null; }
function fmt(v,dp){ return v==null? '' : Number(v).toLocaleString('en-AU',{minimumFractionDigits:dp||0,maximumFractionDigits:dp||0}); }
function ymLabel(ym){ return MON[+ym.slice(5,7)-1]+' '+ym.slice(2,4); }
function niceMax(v){ const p=Math.pow(10,Math.floor(Math.log10(v||1))); const n=v/p; const s=n<=1?1:n<=2?2:n<=2.5?2.5:n<=5?5:10; return s*p; }
function monday(dt){ const d=new Date(dt); d.setUTCDate(d.getUTCDate()-((d.getUTCDay()+6)%7)); return d; }
function addDays(dt,n){ const d=new Date(dt); d.setUTCDate(d.getUTCDate()+n); return d; }
function iso(dt){ return dt.toISOString().slice(0,10); }
function dmy(d){ const dt=new Date(d+'T00:00:00Z'); return dt.getUTCDate()+' '+MON[dt.getUTCMonth()]+' '+dt.getUTCFullYear(); }

/* ---------- tooltip ---------- */
const tip = document.getElementById('tip');
function showTip(head, rows, ev){
  tip.replaceChildren();
  h('div','h',tip,head);
  rows.forEach(([lab,val,col])=>{ const r=h('div','r',tip); const l=h('span',null,r); if(col){ const i=document.createElement('i'); i.style.background=col; l.appendChild(i); l.appendChild(document.createTextNode(' ')); } l.appendChild(document.createTextNode(lab)); h('b',null,r,val); });
  tip.hidden=false; moveTip(ev);
}
function moveTip(ev){ const w=tip.offsetWidth, hgt=tip.offsetHeight; let x=ev.clientX+14, y=ev.clientY+14; if(x+w>window.innerWidth-8) x=ev.clientX-w-14; if(y+hgt>window.innerHeight-8) y=ev.clientY-hgt-14; tip.style.left=x+'px'; tip.style.top=y+'px'; }
function hideTip(){ tip.hidden=true; }
document.addEventListener('pointermove',ev=>{ if(!tip.hidden && !(ev.target.closest && ev.target.closest('svg'))) hideTip(); },{passive:true});
document.addEventListener('pointerdown',ev=>{ if(!(ev.target.closest && ev.target.closest('.hit,.seg,.cell,.bar'))) hideTip(); },{passive:true});
addEventListener('scroll',hideTip,{passive:true});
document.addEventListener('pointerleave',hideTip);

function guardSvg(svg){ svg.addEventListener('pointerleave',hideTip); return svg; }
/* ---------- card ---------- */
function card(parent, opts){
  const c=h('section','card'+(opts.size?' '+opts.size:''),parent);
  const hd=h('header',null,c); const tw=h('div',null,hd); h('h3',null,tw,opts.title); if(opts.why) h('p','why',tw,opts.why);
  const tog=h('button','tog',hd,'Table'); tog.setAttribute('aria-pressed','false'); tog.id='tog-'+opts.id;
  const viz=h('div','viz',c); const tbl=h('div','tbl',c); tbl.hidden=true;
  opts.render(viz); viz.querySelectorAll('svg').forEach(guardSvg);
  const t=opts.table(); const table=h('table',null,tbl); const thead=h('thead',null,table); const trh=h('tr',null,thead); t.cols.forEach(cn=>h('th',null,trh,cn));
  const tb=h('tbody',null,table); t.rows.forEach(row=>{ const tr=h('tr',null,tb); row.forEach(v=>h('td',null,tr,v==null?'':String(v))); });
  tog.addEventListener('click',()=>{ const on=tog.getAttribute('aria-pressed')!=='true'; tog.setAttribute('aria-pressed',String(on)); viz.hidden=on; tbl.hidden=!on; tog.textContent=on?'Chart':'Table'; });
  return c;
}
function legend(parent, items, kind){ const l=h('div','legend',parent); items.forEach(([name,col])=>{ const s=h('span',null,l); const i=document.createElement('i'); if(kind==='line') i.className='line'; i.style.background=col; s.appendChild(i); s.appendChild(document.createTextNode(name)); }); }

/* ---------- state ---------- */
let R = RIDES;
function applyRange(key){
  const y=v=>v.d.slice(0,4);
  if(key==='all') R=RIDES;
  else if(key==='2025'||key==='2026') R=RIDES.filter(r=>y(r)===key);
  else if(key==='12m'){ const from=new Date(TODAY); from.setUTCFullYear(from.getUTCFullYear()-1); R=RIDES.filter(r=>r.dt>=from); }
  else if(key==='90d'){ const from=addDays(TODAY,-90); R=RIDES.filter(r=>r.dt>=from); }
  document.querySelectorAll('.chip').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.range===key)));
  try{ localStorage.setItem('ridebook-range',key); }catch(e){}
  renderAll();
}
document.querySelectorAll('.chip').forEach(b=>b.addEventListener('click',()=>applyRange(b.dataset.range)));

/* ---------- KPIs ---------- */
function renderKpis(){
  const k=document.getElementById('kpis'); k.replaceChildren();
  const km=R.reduce((a,r)=>a+r.km,0), up=R.reduce((a,r)=>a+r.up,0), hrs=R.reduce((a,r)=>a+r.dur,0)/3600;
  const items=[
    ['Rides', fmt(R.length), '', R.length? dmy(R[0].d)+' to '+dmy(R[R.length-1].d) : 'No rides in range'],
    ['Distance', fmt(km), 'km', 'median ride '+fmt(median(R.map(r=>r.km)),1)+' km'],
    ['Climbing', fmt(up), 'm', fmt(km? up/km:0,1)+' m per km'],
    ['Saddle time', fmt(hrs,1), 'h', 'median ride '+fmt(median(R.map(r=>r.dur/60)))+' min'],
    ['Rider power', fmt(mean(R.map(r=>r.pw))), 'W', 'average across rides'],
    ['Your share', fmt(mean(R.map(r=>r.sh))), '%', 'of total energy, rest is motor'],
    ['CO2 saved', fmt(R.reduce((a,r)=>a+r.co2,0)/1000), 'kg', 'versus the same trips by car'],
  ];
  items.forEach(([lab,val,unit,note])=>{ const d=h('div','kpi',k); h('div','lab',d,lab); const n=h('div','num',d,val); if(unit) h('small',null,n,unit); h('div','note',d,note); });
  document.getElementById('subline').textContent = RIDES.length+' rides recorded by the Bosch eBike Flow app, '+dmy(RIDES[0].d)+' to '+dmy(RIDES[RIDES.length-1].d)+'. One bike, Melbourne and the Yarra Valley.';
}

/* ---------- monthly small multiple ---------- */
function monthsBetween(a,b){ const out=[]; let y=+a.slice(0,4), m=+a.slice(5,7); const ye=+b.slice(0,4), me=+b.slice(5,7); while(y<ye||(y===ye&&m<=me)){ out.push(y+'-'+String(m).padStart(2,'0')); m++; if(m>12){m=1;y++;} } return out; }
function monthlyChart(viz, key, unit, ymax, dp){
  if(!R.length){ h('p','why',viz,'No rides in this range.'); return; }
  const W=560,H=230,L=40,Rt=44,T=14,B=30;
  const months=monthsBetween(R[0].ym,R[R.length-1].ym);
  const x0=new Date(months[0]+'-01T00:00:00Z'), x1=new Date(months[months.length-1]+'-01T00:00:00Z'); x1.setUTCMonth(x1.getUTCMonth()+1);
  const vals=R.map(r=>r[key]); const top=ymax||niceMax(Math.max(...vals)*1.05);
  const x=lin(+x0,+x1,L,W-Rt), y=lin(0,top,H-B,T);
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':key},viz);
  const g=el('g',{class:'grid'},svg);
  const ticks=5; for(let i=0;i<=ticks;i++){ const v=top*i/ticks; el('line',{x1:L,x2:W-Rt,y1:y(v),y2:y(v)},g); txt(svg,L-6,y(v)+4,fmt(v),'val','end'); }
  el('line',{x1:L,x2:W-Rt,y1:y(0),y2:y(0),class:'axis'},svg);
  months.forEach((ym,i)=>{ const m=+ym.slice(5,7); if(i===0||m===1||m===4||m===7||m===10){ const d=new Date(ym+'-01T00:00:00Z'); txt(svg,x(+d)+2,H-B+16,ymLabel(ym)); } });
  R.forEach(r=>{ el('circle',{cx:x(+r.dt),cy:y(r[key]),r:3.5,class:'dot'},svg); });
  const med=months.map(ym=>{ const rs=R.filter(r=>r.ym===ym); const d=new Date(ym+'-01T00:00:00Z'); d.setUTCDate(15); return {ym,n:rs.length,v:median(rs.map(r=>r[key])),cx:x(+d)}; });
  let path='', pen=false;
  med.forEach(m=>{ if(m.v==null){pen=false;return;} path+=(pen?'L':'M')+m.cx.toFixed(1)+' '+y(m.v).toFixed(1)+' '; pen=true; });
  el('path',{d:path,class:'med'},svg);
  med.forEach(m=>{ if(m.v!=null) el('circle',{cx:m.cx,cy:y(m.v),r:3.5,class:'medpt'},svg); });
  const last=[...med].reverse().find(m=>m.v!=null); if(last) txt(svg,last.cx+8,y(last.v)+4,fmt(last.v,dp)+unit,'end');
  const xh=el('line',{y1:T,y2:H-B,class:'xh',visibility:'hidden'},svg);
  const hit=el('rect',{x:L,y:T,width:W-Rt-L,height:H-B-T,class:'hit'},svg);
  const pt=svg.createSVGPoint();
  hit.addEventListener('pointermove',ev=>{ pt.x=ev.clientX; pt.y=ev.clientY; const p=pt.matrixTransform(svg.getScreenCTM().inverse()); let best=null; med.forEach(m=>{ if(m.n&&(best===null||Math.abs(m.cx-p.x)<Math.abs(best.cx-p.x))) best=m; }); if(!best) return; xh.setAttribute('x1',best.cx); xh.setAttribute('x2',best.cx); xh.setAttribute('visibility','visible'); const rs=R.filter(r=>r.ym===best.ym); showTip(ymLabel(best.ym)+' · '+best.n+(best.n===1?' ride':' rides'),[['Median',fmt(best.v,dp)+' '+unit,'var(--s1)'],['Range',fmt(Math.min(...rs.map(r=>r[key])),dp)+' to '+fmt(Math.max(...rs.map(r=>r[key])),dp)]],ev); });
  hit.addEventListener('pointerleave',()=>{ hideTip(); xh.setAttribute('visibility','hidden'); });
  return med;
}
function monthlyTable(key,dp){ const months=R.length? monthsBetween(R[0].ym,R[R.length-1].ym):[]; return {cols:['Month','Rides','Median','Low','High'],rows:months.map(ym=>{ const v=R.filter(r=>r.ym===ym).map(r=>r[key]); return [ymLabel(ym),v.length,v.length?fmt(median(v),dp):'',v.length?fmt(Math.min(...v),dp):'',v.length?fmt(Math.max(...v),dp):'']; })}; }

/* ---------- scatter: power vs climbing ---------- */
function scatterChart(viz){
  if(!R.length){ h('p','why',viz,'No rides in this range.'); return; }
  const W=560,H=260,L=40,Rt=16,T=22,B=36;
  const xm=niceMax(Math.max(...R.map(r=>r.climb))*1.05), ym=niceMax(Math.max(...R.map(r=>r.pw))*1.05);
  const x=lin(0,xm,L,W-Rt), y=lin(0,ym,H-B,T);
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'Rider power against climbing per kilometre'},viz);
  const g=el('g',{class:'grid'},svg);
  for(let i=0;i<=5;i++){ const v=ym*i/5; el('line',{x1:L,x2:W-Rt,y1:y(v),y2:y(v)},g); txt(svg,L-6,y(v)+4,fmt(v),'val','end'); }
  for(let i=0;i<=5;i++){ const v=xm*i/5; txt(svg,x(v),H-B+16,fmt(v),'val','middle'); }
  el('line',{x1:L,x2:W-Rt,y1:y(0),y2:y(0),class:'axis'},svg);
  txt(svg,W-Rt,H-4,'metres climbed per km',null,'end'); txt(svg,L,T-2,'rider power, W');
  const years=[...new Set(R.map(r=>r.d.slice(0,4)))].sort();
  const col=yr=>yr==='2025'?'var(--s1)':'var(--s2)';
  R.forEach(r=>{ const c=el('circle',{cx:x(r.climb),cy:y(r.pw),r:5,fill:col(r.d.slice(0,4)),stroke:'var(--surface)','stroke-width':2},svg); const hit=el('circle',{cx:x(r.climb),cy:y(r.pw),r:12,class:'hit'},svg);
    hit.addEventListener('pointerenter',ev=>{ c.setAttribute('r',7); showTip(dmy(r.d)+' · '+fmt(r.km,1)+' km',[['Rider power',fmt(r.pw)+' W',col(r.d.slice(0,4))],['Climb',fmt(r.climb,1)+' m/km'],['Your share',fmt(r.sh)+' %'],['Turbo',fmt(r.turbo)+' % of distance']],ev); });
    hit.addEventListener('pointermove',moveTip); hit.addEventListener('pointerleave',()=>{ c.setAttribute('r',5); hideTip(); }); });
  legend(viz, years.map(yr=>[yr,col(yr)]));
}

/* ---------- weekly rides ---------- */
function weeks(){ if(!R.length) return []; const start=monday(R[0].dt), end=monday(R[R.length-1].dt); const out=[]; for(let d=start; d<=end; d=addDays(d,7)){ const e=addDays(d,7); const rs=R.filter(r=>r.dt>=d&&r.dt<e); out.push({d,n:rs.length,km:rs.reduce((a,r)=>a+r.km,0)}); } return out; }
function weeklyChart(viz){
  const wk=weeks(); if(!wk.length){ h('p','why',viz,'No rides in this range.'); return; }
  const W=1080,H=200,L=30,Rt=10,T=12,B=28;
  const top=Math.max(4,Math.max(...wk.map(w=>w.n)));
  const x=lin(0,wk.length,L,W-Rt), y=lin(0,top,H-B,T); const bw=Math.max(2,(W-Rt-L)/wk.length-2);
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'Rides per week'},viz);
  const g=el('g',{class:'grid'},svg);
  for(let v=0;v<=top;v+=Math.ceil(top/4)){ el('line',{x1:L,x2:W-Rt,y1:y(v),y2:y(v)},g); txt(svg,L-6,y(v)+4,fmt(v),'val','end'); }
  el('line',{x1:L,x2:W-Rt,y1:y(0),y2:y(0),class:'axis'},svg);
  wk.forEach((w,i)=>{ const m=w.d.getUTCMonth(); const nd=addDays(w.d,-7); if(i===0||nd.getUTCMonth()!==m){ txt(svg,x(i)+1,H-B+16,MON[m]+(m===0||i===0?' '+String(w.d.getUTCFullYear()).slice(2):'')); }
    if(w.n){ el('rect',{x:x(i)+1,y:y(w.n),width:bw,height:y(0)-y(w.n),rx:3,class:'bar'},svg); }
    const hit=el('rect',{x:x(i),y:T,width:bw+2,height:H-B-T,class:'hit'},svg);
    hit.addEventListener('pointerenter',ev=>showTip('Week of '+dmy(iso(w.d)),[['Rides',String(w.n),'var(--s1)'],['Distance',fmt(w.km,1)+' km']],ev));
    hit.addEventListener('pointermove',moveTip); hit.addEventListener('pointerleave',hideTip); });
}
function weeklyTable(){ return {cols:['Week starting','Rides','km'],rows:weeks().map(w=>[dmy(iso(w.d)),w.n,fmt(w.km,1)])}; }

/* ---------- consistency stats ---------- */
function consistency(viz){
  const wk=weeks(); const active=wk.filter(w=>w.n>0);
  let gap=0, gapEnd=null; for(let i=1;i<R.length;i++){ const g=(R[i].dt-R[i-1].dt)/864e5; if(g>gap){gap=g;gapEnd=R[i];} }
  const since=R.length? Math.round((TODAY-R[R.length-1].dt)/864e5) : null;
  const perActive=median(active.map(w=>w.n));
  const kmActive=median(active.map(w=>w.km));
  const s=h('div','stats',viz);
  const items=[
    ['Weeks with a ride', wk.length? Math.round(100*active.length/wk.length):0, '%', active.length+' of '+wk.length+' weeks'],
    ['Typical active week', fmt(perActive), perActive===1?' ride':' rides', 'median '+fmt(kmActive)+' km'],
    ['Longest gap', fmt(gap), ' days', gapEnd? 'ended '+dmy(gapEnd.d):''],
    ['Since last ride', since==null?'':fmt(since), ' days', R.length? 'last ride '+dmy(R[R.length-1].d):''],
    ['Realistic target', fmt(Math.max(1,Math.round(perActive||1))), ' per week', 'what you already do in an active week'],
  ];
  items.forEach(([lab,val,unit,note])=>{ const d=h('div','stat',s); h('div','lab',d,lab); const n=h('div','num',d,String(val)); h('small',null,n,unit); h('div','note',d,note); });
}

/* ---------- heatmap weekday x hour ---------- */
function heatChart(viz){
  const hrs=[]; for(let i=6;i<=18;i++) hrs.push(i);
  const grid=DOW.map(()=>hrs.map(()=>0)); R.forEach(r=>{ const hi=hrs.indexOf(r.hr); if(hi>=0) grid[r.dow][hi]++; });
  const mx=Math.max(1,...grid.flat());
  const W=560,H=230,L=40,T=22,cw=(W-L-8)/hrs.length,ch=(H-T-6)/7;
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'Rides by weekday and start hour'},viz);
  hrs.forEach((hr,j)=>{ if(j%2===0) txt(svg,L+j*cw+cw/2,T-8,String(hr)+':00','val','middle'); });
  const ramp=['var(--seq1)','var(--seq2)','var(--seq3)','var(--seq4)','var(--seq5)','var(--seq6)','var(--seq7)'];
  DOW.forEach((dn,i)=>{ txt(svg,L-8,T+i*ch+ch/2+4,dn,'val','end'); hrs.forEach((hr,j)=>{ const n=grid[i][j]; const cell=el('rect',{x:L+j*cw+1,y:T+i*ch+1,width:cw-2,height:ch-2,rx:2,class:'cell',fill:n? ramp[Math.min(6,Math.ceil(n/mx*7)-1)] : 'var(--grid)'},svg);
    if(n){ const t=txt(svg,L+j*cw+cw/2,T+i*ch+ch/2+4,String(n),null,'middle'); t.setAttribute('fill', n/mx>0.5? 'var(--surface)':'var(--ink)'); t.style.fill = n/mx>0.5? 'var(--surface)':'var(--ink)'; t.style.pointerEvents='none'; }
    cell.addEventListener('pointerenter',ev=>showTip(dn+' '+hr+':00 to '+(hr+1)+':00',[['Rides',String(n),'var(--seq5)']],ev)); cell.addEventListener('pointermove',moveTip); cell.addEventListener('pointerleave',hideTip); }); });
  return {hrs,grid};
}
function heatTable(){ const hrs=[]; for(let i=6;i<=18;i++) hrs.push(i); const grid=DOW.map(()=>hrs.map(()=>0)); R.forEach(r=>{ const hi=hrs.indexOf(r.hr); if(hi>=0) grid[r.dow][hi]++; }); return {cols:['Day',...hrs.map(x=>x+':00')],rows:DOW.map((d,i)=>[d,...grid[i].map(v=>v||'')])}; }

/* ---------- assist mode share by month ---------- */
function modeChart(viz){
  if(!R.length){ h('p','why',viz,'No rides in this range.'); return; }
  const months=monthsBetween(R[0].ym,R[R.length-1].ym);
  const data=months.map(ym=>{ const rs=R.filter(r=>r.ym===ym); const m=[0,0,0,0,0]; rs.forEach(r=>r.m.forEach((v,i)=>m[i]+=v)); const t=m.reduce((a,b)=>a+b,0); return {ym,n:rs.length,pct:t? m.map(v=>100*v/t):null}; });
  const W=560,H=240,L=36,Rt=10,T=12,B=30;
  const x=lin(0,months.length,L,W-Rt), y=lin(0,100,H-B,T); const bw=(W-Rt-L)/months.length-3;
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'Assist mode share of distance by month'},viz);
  const g=el('g',{class:'grid'},svg);
  for(let v=0;v<=100;v+=25){ el('line',{x1:L,x2:W-Rt,y1:y(v),y2:y(v)},g); txt(svg,L-6,y(v)+4,v+'%','val','end'); }
  data.forEach((d,i)=>{ const m=+d.ym.slice(5,7); if(i===0||m===1||m===7) txt(svg,x(i)+1,H-B+16,ymLabel(d.ym)); if(!d.pct) return; let acc=0;
    d.pct.forEach((p,k)=>{ if(p<=0) return; const y0=y(acc+p), y1=y(acc); const seg=el('rect',{x:x(i)+1.5,y:y0+1,width:bw,height:Math.max(0,y1-y0-2),rx:2,fill:MODE_COL[k],class:'seg'},svg);
      seg.addEventListener('pointerenter',ev=>showTip(ymLabel(d.ym)+' · '+d.n+(d.n===1?' ride':' rides'),d.pct.map((q,j)=>[MODES[j],fmt(q)+' %',MODE_COL[j]]).reverse(),ev)); seg.addEventListener('pointermove',moveTip); seg.addEventListener('pointerleave',hideTip); acc+=p; }); });
  legend(viz, MODES.map((m,i)=>[m,MODE_COL[i]]));
}
function modeTable(){ const months=R.length? monthsBetween(R[0].ym,R[R.length-1].ym):[]; return {cols:['Month','Rides',...MODES.map(m=>m+' %')],rows:months.map(ym=>{ const rs=R.filter(r=>r.ym===ym); const m=[0,0,0,0,0]; rs.forEach(r=>r.m.forEach((v,i)=>m[i]+=v)); const t=m.reduce((a,b)=>a+b,0); return [ymLabel(ym),rs.length,...m.map(v=>t? fmt(100*v/t):'')]; })}; }

/* ---------- distance histogram ---------- */
function bins(){ const mx=Math.max(5,...R.map(r=>r.km)); const n=Math.ceil(mx/5); const b=[]; for(let i=0;i<n;i++) b.push({lo:i*5,hi:(i+1)*5,n:0,km:0}); R.forEach(r=>{ const i=Math.min(n-1,Math.floor(r.km/5)); b[i].n++; b[i].km+=r.km; }); return b; }
function histChart(viz){
  const b=bins(); if(!R.length){ h('p','why',viz,'No rides in this range.'); return; }
  const W=560,H=220,L=32,Rt=10,T=14,B=30;
  const top=niceMax(Math.max(...b.map(x=>x.n))*1.1);
  const x=lin(0,b.length,L,W-Rt), y=lin(0,top,H-B,T); const bw=(W-Rt-L)/b.length-3;
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'Ride length distribution'},viz);
  const g=el('g',{class:'grid'},svg);
  for(let i=0;i<=4;i++){ const v=top*i/4; el('line',{x1:L,x2:W-Rt,y1:y(v),y2:y(v)},g); txt(svg,L-6,y(v)+4,fmt(v),'val','end'); }
  el('line',{x1:L,x2:W-Rt,y1:y(0),y2:y(0),class:'axis'},svg);
  const peak=Math.max(...b.map(x=>x.n));
  b.forEach((bin,i)=>{ txt(svg,x(i)+bw/2+1.5,H-B+16,String(bin.lo),'val','middle'); if(bin.n){ el('rect',{x:x(i)+1.5,y:y(bin.n),width:bw,height:y(0)-y(bin.n),rx:3,class:'bar'},svg); if(bin.n===peak) txt(svg,x(i)+bw/2+1.5,y(bin.n)-5,String(bin.n),'end','middle'); }
    const hit=el('rect',{x:x(i),y:T,width:bw+3,height:H-B-T,class:'hit'},svg); hit.addEventListener('pointerenter',ev=>showTip(bin.lo+' to '+bin.hi+' km',[['Rides',String(bin.n),'var(--s1)'],['Share',fmt(100*bin.n/R.length)+' %']],ev)); hit.addEventListener('pointermove',moveTip); hit.addEventListener('pointerleave',hideTip); });
  txt(svg,W-Rt,H-4,'ride length, km',null,'end');
}
function histTable(){ return {cols:['Length','Rides','Share %'],rows:bins().map(b=>[b.lo+' to '+b.hi+' km',b.n,R.length?fmt(100*b.n/R.length):''])}; }

/* ---------- terrain profile ---------- */
const TERRAIN=[['Flat','under 5 m climbed per km'],['Rolling','5 to 10 m per km'],['Hilly','over 10 m per km']];
function terrainRows(){ return TERRAIN.map((t,i)=>{ const rs=R.filter(r=>r.terrain===i); return {name:t[0],desc:t[1],n:rs.length,km:rs.reduce((a,r)=>a+r.km,0),sh:mean(rs.map(r=>r.sh)),turbo:mean(rs.map(r=>r.turbo)),pw:mean(rs.map(r=>r.pw)),sp:mean(rs.map(r=>r.sp))}; }); }
function terrainChart(viz){
  const rows=terrainRows(); const wrap=h('div','bars',viz);
  rows.forEach(t=>{ const row=h('div','row',wrap); const nm=h('div','name',row,t.name); h('small',null,nm,t.desc+' · '+t.n+(t.n===1?' ride':' rides')+(t.n?' · '+fmt(t.km)+' km':'')); const tr=h('div','track',row);
    [['Your share',t.sh,''],['Turbo share',t.turbo,'t'],['Rider power',t.pw,'',true]].forEach(([lab,v,cls,isW])=>{ const b=h('div','b',tr); h('span',null,b,lab); const i=document.createElement('i'); if(cls) i.className=cls; const pct=isW? (v||0)/2 : (v||0); i.style.width=Math.max(0,Math.min(100,pct))+'%'; b.appendChild(i); h('b',null,b,v==null?'':fmt(v)+(isW?' W':' %')); }); });
}
function terrainTable(){ return {cols:['Terrain','Rides','km','Your share %','Turbo %','Rider power W','Avg speed'],rows:terrainRows().map(t=>[t.name,t.n,fmt(t.km),fmt(t.sh),fmt(t.turbo),fmt(t.pw),fmt(t.sp,1)])}; }

/* ---------- hardest rides ---------- */
function hardest(){ return [...R].sort((a,b)=>(b.up*b.pw)-(a.up*a.pw)).slice(0,8); }
function hardTable(){ return {cols:['Date','km','Climb m','Power W','Share %','Turbo %'],rows:hardest().map(r=>[dmy(r.d),fmt(r.km,1),fmt(r.up),fmt(r.pw),fmt(r.sh),fmt(r.turbo)])}; }
function hardChart(viz){ const t=hardTable(); const table=h('table',null,h('div','tbl',viz)); const tr=h('tr',null,h('thead',null,table)); t.cols.forEach(c=>h('th',null,tr,c)); const tb=h('tbody',null,table); t.rows.forEach(r=>{ const x=h('tr',null,tb); r.forEach(v=>h('td',null,x,String(v))); }); }

/* ---------- GPS: routes, map, gradient ---------- */
const GEO = __GEO__;
const RIDE_BY_ID = Object.fromEntries(RIDES.map(r=>[r.id,r]));
const CLUSTERS = GEO.clusters.map((c,i)=>Object.assign({},c,{i,name: c.start===c.dest ? c.start+' loop' : c.start+' to '+c.dest}));
RIDES.forEach(r=>{ r.cl=-1; r.far=GEO.far[r.id]; });
CLUSTERS.forEach(c=>c.ids.forEach(id=>{ if(RIDE_BY_ID[id]) RIDE_BY_ID[id].cl=c.i; }));
const CL_COLS=['var(--s1)','var(--s2)','var(--s3)','var(--s4)','var(--s5)'];
const clCol=i=>(i>=0&&i<5)? CL_COLS[i] : 'var(--axis)';
const routeName=r=>r.cl>=0? CLUSTERS[r.cl].name : (GEO.tracks[r.id]? 'One off ride' : 'No GPS');
let mapZoom='home';

function extent(pts,pad){ let x0=Infinity,x1=-Infinity,y0=Infinity,y1=-Infinity; pts.forEach(p=>{ if(p[0]<x0)x0=p[0]; if(p[0]>x1)x1=p[0]; if(p[1]<y0)y0=p[1]; if(p[1]>y1)y1=p[1]; }); return {x0:x0-pad,x1:x1+pad,y0:y0-pad,y1:y1+pad}; }
function drawRoutes(svg, rides, ext, W, H, opts){
  const dx=ext.x1-ext.x0, dy=ext.y1-ext.y0; const s=Math.min(W/dx,H/dy); const ox=(W-dx*s)/2, oy=(H-dy*s)/2;
  const X=x=>ox+(x-ext.x0)*s, Y=y=>H-oy-(y-ext.y0)*s;
  if(opts.landmarks){ GEO.lm.forEach(([n,x,y])=>{ if(x<ext.x0||x>ext.x1||y<ext.y0||y>ext.y1) return; el('circle',{cx:X(x),cy:Y(y),r:2.5,fill:'var(--muted)'},svg); const t=txt(svg,X(x)+5,Y(y)+4,n); t.style.fontSize='11px'; }); }
  rides.forEach(r=>{ const t=GEO.tracks[r.id]; if(!t) return; const d=t.map((p,i)=>(i?'L':'M')+X(p[0]).toFixed(1)+' '+Y(p[1]).toFixed(1)).join(' ');
    const path=el('path',{d,fill:'none',stroke:clCol(r.cl),'stroke-width':opts.width||1.6,'stroke-opacity':opts.opacity||.7,'stroke-linejoin':'round','stroke-linecap':'round'},svg);
    if(opts.hover){ const hit=el('path',{d,fill:'none',stroke:'transparent','stroke-width':10,class:'hit'},svg);
      hit.addEventListener('pointerenter',ev=>{ path.setAttribute('stroke-width',3.2); path.setAttribute('stroke-opacity',1); path.parentNode.appendChild(path); path.parentNode.appendChild(hit); showTip(dmy(r.d)+' · '+routeName(r),[['Distance',fmt(r.km,1)+' km',clCol(r.cl)],['Climb',fmt(r.up)+' m'],['Furthest from start',fmt(r.far,1)+' km'],['Rider power',fmt(r.pw)+' W'],['Your share',fmt(r.sh)+' %'],['Turbo',fmt(r.turbo)+' %']],ev); });
      hit.addEventListener('pointermove',moveTip); hit.addEventListener('pointerleave',()=>{ path.setAttribute('stroke-width',opts.width||1.6); path.setAttribute('stroke-opacity',opts.opacity||.7); hideTip(); }); } });
  if(opts.scale){ const km=dx>60?20:dx>25?10:dx>10?5:1; const px=km*s; const x=12,y=H-12; el('line',{x1:x,x2:x+px,y1:y,y2:y,stroke:'var(--ink-2)','stroke-width':2},svg); txt(svg,x,y-6,km+' km','val'); }
}
function mapChart(viz){
  const tracked=R.filter(r=>GEO.tracks[r.id]);
  const ctl=h('div','zoom',viz);
  [['home','Around home'],['all','Every ride']].forEach(([k,lab])=>{ const b=h('button','chip',ctl,lab); b.id='zoom-'+k; b.setAttribute('aria-pressed',String(mapZoom===k)); b.addEventListener('click',()=>{ mapZoom=k; renderAll(); }); });
  if(!tracked.length){ h('p','why',viz,'No GPS tracks in this range.'); return; }
  let pts;
  if(mapZoom==='home'){ const main=tracked.filter(r=>r.cl>=0&&r.cl<3); pts=(main.length?main:tracked).flatMap(r=>GEO.tracks[r.id]); } else pts=tracked.flatMap(r=>GEO.tracks[r.id]);
  const ext=extent(pts, mapZoom==='home'?1.2:4);
  const W=1080, H=Math.max(380,Math.min(640,Math.round(W*(ext.y1-ext.y0)/(ext.x1-ext.x0))));
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'Map of ride routes'},viz); svg.style.overflow='hidden';
  el('rect',{x:0,y:0,width:W,height:H,rx:8,fill:'var(--plane)'},svg);
  const shown=mapZoom==='home'? tracked : tracked;
  drawRoutes(svg, shown, ext, W, H, {landmarks:true,hover:true,scale:true});
  const items=CLUSTERS.filter(c=>c.i<5&&R.some(r=>r.cl===c.i)).map(c=>[c.name,clCol(c.i)]); items.push(['Other rides','var(--axis)']); legend(viz,items,'line');
  const note=h('p','why',viz, mapZoom==='home' ? 'Zoomed to the three most ridden routes. Rides further afield are on the Every ride view.' : 'Every ride with a GPS track. Place names are for orientation only.');
}
function mapTable(){ return {cols:['Date','Route','km','Climb m','Furthest km'],rows:R.filter(r=>GEO.tracks[r.id]).map(r=>[dmy(r.d),routeName(r),fmt(r.km,1),fmt(r.up),fmt(r.far,1)])}; }

function routeRows(){ return CLUSTERS.map(c=>{ const rs=R.filter(r=>r.cl===c.i); if(rs.length<2) return null; const best=rs.reduce((a,b)=>b.pw>a.pw?b:a); return {c,rs,n:rs.length,km:median(rs.map(r=>r.km)),up:median(rs.map(r=>r.up)),sh:mean(rs.map(r=>r.sh)),turbo:mean(rs.map(r=>r.turbo)),pw:mean(rs.map(r=>r.pw)),best,last:rs[rs.length-1]}; }).filter(Boolean).sort((a,b)=>b.n-a.n); }
function routesChart(viz){
  const rows=routeRows(); if(!rows.length){ h('p','why',viz,'No repeated routes in this range.'); return; }
  const wrap=h('div','routes',viz);
  rows.slice(0,8).forEach(x=>{ const row=h('div','route',wrap);
    const mini=el('svg',{viewBox:'0 0 120 84',class:'mini','aria-hidden':'true'},row); mini.style.overflow='hidden'; el('rect',{x:0,y:0,width:120,height:84,rx:6,fill:'var(--plane)'},mini);
    drawRoutes(mini, x.rs, extent(x.rs.flatMap(r=>GEO.tracks[r.id]),0.4), 120, 84, {width:1.4,opacity:.8});
    const body=h('div',null,row); const nm=h('div','rname',body); const sw=document.createElement('i'); sw.style.background=clCol(x.c.i); nm.appendChild(sw); nm.appendChild(document.createTextNode(x.c.name));
    h('div','rmeta',body, x.n+' rides · typically '+fmt(x.km)+' km and '+fmt(x.up)+' m of climbing · last ridden '+dmy(x.last.d));
    const st=h('div','rstats',body);
    [['Your share',fmt(x.sh)+' %'],['Turbo',fmt(x.turbo)+' %'],['Rider power',fmt(x.pw)+' W'],['Best',fmt(x.best.pw)+' W on '+dmy(x.best.d)]].forEach(([l,v])=>{ const d=h('div',null,st); h('span',null,d,l); h('b',null,d,v); }); });
}
function routesTable(){ return {cols:['Route','Rides','Typical km','Typical climb m','Your share %','Turbo %','Rider power W','Best W','Last ridden'],rows:routeRows().map(x=>[x.c.name,x.n,fmt(x.km),fmt(x.up),fmt(x.sh),fmt(x.turbo),fmt(x.pw),fmt(x.best.pw),dmy(x.last.d)])}; }

function gradChart(viz,key,unit,dp){
  const b=GEO.bins; const W=560,H=210,L=34,Rt=10,T=16,B=32;
  const vals=b.map(x=>key==='pw'?x[2]:x[3]); const top=niceMax(Math.max(...vals)*1.15);
  const x=lin(0,b.length,L,W-Rt), y=lin(0,top,H-B,T); const bw=(W-Rt-L)/b.length-3;
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img','aria-label':'By gradient'},viz);
  const g=el('g',{class:'grid'},svg); for(let i=0;i<=4;i++){ const v=top*i/4; el('line',{x1:L,x2:W-Rt,y1:y(v),y2:y(v)},g); txt(svg,L-6,y(v)+4,fmt(v),'val','end'); }
  el('line',{x1:L,x2:W-Rt,y1:y(0),y2:y(0),class:'axis'},svg);
  const peak=Math.max(...vals);
  b.forEach((bin,i)=>{ const v=vals[i]; const lab=(bin[0]>0?'+':'')+bin[0]+'%'; txt(svg,x(i)+bw/2+1.5,H-B+16,lab,'val','middle');
    el('rect',{x:x(i)+1.5,y:y(v),width:bw,height:y(0)-y(v),rx:3,class:'bar',fill:bin[0]===0?'var(--s1)':'var(--s1)'},svg);
    if(v===peak||bin[0]===0) txt(svg,x(i)+bw/2+1.5,y(v)-5,fmt(v,dp)+(bin[0]===0?' '+unit:''),'end','middle');
    const hit=el('rect',{x:x(i),y:T,width:bw+3,height:H-B-T,class:'hit'},svg); hit.addEventListener('pointerenter',ev=>showTip('Gradient '+lab+' to '+(bin[0]+2>0?'+':'')+(bin[0]+2)+'%',[[key==='pw'?'Rider power':'Speed',fmt(v,dp)+' '+unit,'var(--s1)'],['Track points',fmt(bin[1])]],ev)); hit.addEventListener('pointermove',moveTip); hit.addEventListener('pointerleave',hideTip); });
  txt(svg,W-Rt,H-4,'gradient, downhill to uphill',null,'end');
}
function gradTable(){ return {cols:['Gradient band','Track points','Rider power W','Speed km/h'],rows:GEO.bins.map(b=>[(b[0]>0?'+':'')+b[0]+' to '+(b[0]+2>0?'+':'')+(b[0]+2)+' %',fmt(b[1]),fmt(b[2]),fmt(b[3],1)])}; }

/* ---------- render ---------- */
function renderAll(){
  renderKpis();
  const wg=document.getElementById('where-grid'); wg.replaceChildren();
  card(wg,{id:'map',title:'Ride map',why:'Each line is one ride. Colour shows the route group.',render:mapChart,table:mapTable});
  card(wg,{id:'rt',title:'Your regular routes',why:'Routes ridden more than once, most ridden first.',render:routesChart,table:routesTable});
  const fg=document.getElementById('fit-grid'); fg.replaceChildren();
  card(fg,{id:'pw',size:'half',title:'Rider power by month',why:'Watts from your legs. Higher means you are working harder, whatever the motor does.',render:v=>monthlyChart(v,'pw','W',null,0),table:()=>monthlyTable('pw',0)});
  card(fg,{id:'sh',size:'half',title:'Your share of the energy',why:'Percent of total work done by you rather than the motor.',render:v=>monthlyChart(v,'sh','%',100,0),table:()=>monthlyTable('sh',0)});
  card(fg,{id:'sp',size:'half',title:'Average speed by month',why:'Moving speed, stops excluded.',render:v=>monthlyChart(v,'sp','km/h',null,1),table:()=>monthlyTable('sp',1)});
  card(fg,{id:'sc',size:'half',title:'Power against climbing, 2025 vs 2026',why:'Like for like comparison. Same climbing, lower power means more motor.',render:scatterChart,table:()=>({cols:['Date','Year','m per km','Rider power W','Your share %','Turbo %'],rows:[...R].map(r=>[dmy(r.d),r.d.slice(0,4),fmt(r.climb,1),fmt(r.pw),fmt(r.sh),fmt(r.turbo)])})});
  const hg=document.getElementById('habit-grid'); hg.replaceChildren();
  card(hg,{id:'wk',title:'Rides per week',why:'Every week from the first ride to the last. Empty columns are weeks without a ride.',render:weeklyChart,table:weeklyTable});
  card(hg,{id:'cs',size:'half',title:'Consistency',why:'Measured on the weeks in the selected range.',render:consistency,table:()=>({cols:['Measure','Value'],rows:(()=>{ const wk=weeks(); const a=wk.filter(w=>w.n>0); return [['Weeks in range',wk.length],['Weeks with a ride',a.length],['Median rides in an active week',fmt(median(a.map(w=>w.n)))],['Median km in an active week',fmt(median(a.map(w=>w.km)))]]; })()})});
  card(hg,{id:'hm',size:'half',title:'When you ride',why:'Rides by weekday and start hour.',render:heatChart,table:heatTable});
  const eg=document.getElementById('effort-grid'); eg.replaceChildren();
  card(eg,{id:'tr',size:'half',title:'Effort by terrain',why:'Where Turbo takes over and how much of the work stays with you.',render:terrainChart,table:terrainTable});
  card(eg,{id:'md',size:'half',title:'Assist mode by month',why:'Share of distance ridden in each mode.',render:modeChart,table:modeTable});
  card(eg,{id:'gp',size:'half',title:'Rider power by gradient',why:'Average watts from you at each road gradient, across every GPS point.',render:v=>gradChart(v,'pw','W',0),table:gradTable});
  card(eg,{id:'gs',size:'half',title:'Speed by gradient',why:'Average speed at each gradient. Uphill barely slows you, which is the motor at work.',render:v=>gradChart(v,'sp','km/h',1),table:gradTable});
  card(eg,{id:'hs',size:'half',title:'Ride length',why:'How far a typical outing goes, in 5 km bands.',render:histChart,table:histTable});
  card(eg,{id:'hd',size:'half',title:'Hardest rides',why:'Ranked by climbing multiplied by your own power output.',render:hardChart,table:hardTable});
}
if(new URLSearchParams(location.search).get('embed')==='1') document.body.classList.add('embed');
let initial='all'; try{ initial=localStorage.getItem('ridebook-range')||'all'; }catch(e){}
if(!document.querySelector('.chip[data-range="'+initial+'"]')) initial='all';
applyRange(initial);
</script>
'@ | Set-Content -Path (Join-Path $Work 'ridebook_template.html') -Encoding UTF8

@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nic's Ride Map</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow+Semi+Condensed:wght@500;600;700&family=Source+Sans+3:wght@400;600&display=swap">
<style>
:root{
  --plane:#f4f5f2; --surface:#fcfcfb; --ink:#101412; --ink-2:#545b57; --muted:#858b87;
  --grid:#e2e4df; --ring:rgba(16,20,18,.10); --hover:rgba(16,20,18,.05);
  --route:#2a78d6; --sel:#eb6834; --tip-bg:#101412; --tip-ink:#fcfcfb;
  --m1:#2a78d6; --m2:#eb6834; --m3:#1baf7a; --m4:#eda100; --m5:#e87ba4;
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--plane);color:var(--ink);font:15px/1.45 "Source Sans 3",system-ui,-apple-system,"Segoe UI",sans-serif;display:flex;flex-direction:column}
h1,h2,.num{font-family:"Barlow Semi Condensed","Source Sans 3",system-ui,sans-serif}
.top{display:flex;align-items:center;gap:16px;padding:10px 16px;border-bottom:1px solid var(--ring);background:var(--surface);flex-wrap:wrap}
.top h1{font-size:1.5rem;margin:0;font-weight:700;letter-spacing:-.01em}
.top .sub{color:var(--ink-2);font-size:.9rem}
.top .spacer{flex:1}
.chip{border:1px solid var(--ring);background:var(--surface);color:var(--ink);font:inherit;font-size:.85rem;padding:5px 11px;border-radius:999px;cursor:pointer}
.chip:hover{background:var(--hover)}
.chip[aria-pressed="true"]{background:var(--ink);color:var(--surface);border-color:var(--ink)}
.chip:focus-visible,.ride:focus-visible{outline:2px solid var(--route);outline-offset:2px}
main{flex:1;display:grid;grid-template-columns:1fr 360px;min-height:0}
#map{min-height:0;background:#dfe6dc}
.leaflet-container{font:inherit}
.leaflet-control-attribution{font-size:10px}
.ctlbox{display:flex;flex-direction:column;gap:4px}
.ib{border:1px solid var(--ring);background:var(--surface);color:var(--ink);border-radius:8px;font:inherit;font-size:.82rem;cursor:pointer;padding:6px 10px;box-shadow:0 1px 4px rgba(0,0,0,.15)}
.ib:hover{background:var(--hover)}
.side{border-left:1px solid var(--ring);background:var(--surface);display:flex;flex-direction:column;min-height:0}
.side .head{padding:12px 14px 8px;border-bottom:1px solid var(--ring)}
.side .head h2{margin:0;font-size:1.15rem;font-weight:600}
.side .head .cnt{font-size:.82rem;color:var(--muted)}
.list{overflow-y:auto;flex:1;min-height:0}
.ride{display:grid;grid-template-columns:1fr auto;gap:2px 10px;padding:9px 14px;border-bottom:1px solid var(--grid);cursor:pointer;background:transparent;border-left:3px solid transparent;border-top:0;border-right:0;width:100%;text-align:left;font:inherit;color:inherit}
.ride:hover{background:var(--hover)}
.ride[aria-selected="true"]{border-left-color:var(--sel);background:var(--hover)}
.ride .d{font-weight:600}
.ride .n{color:var(--ink-2);font-size:.85rem;grid-column:1/-1}
.ride .k{color:var(--ink);font-variant-numeric:tabular-nums;font-weight:600;text-align:right}
.ride.nogps .d::after{content:" · no GPS";font-weight:400;color:var(--muted);font-size:.8rem}
.detail{overflow-y:auto;flex:1;min-height:0;padding:12px 14px 20px}
.detail .back{border:0;background:transparent;color:var(--route);font:inherit;font-size:.9rem;cursor:pointer;padding:0;margin-bottom:6px}
.detail h2{margin:0;font-size:1.3rem;font-weight:600;line-height:1.15}
.detail .when{color:var(--ink-2);font-size:.9rem;margin:2px 0 10px}
.kv{display:grid;grid-template-columns:1fr 1fr;gap:8px 14px;margin-bottom:12px}
.kv div{padding:8px 10px;background:var(--plane);border-radius:8px}
.kv .lab{font-size:.72rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}
.kv .num{font-size:1.35rem;font-weight:600;line-height:1.1}
.kv .num small{font-size:.8rem;font-weight:500;color:var(--ink-2);margin-left:2px}
.sec{font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:14px 0 6px}
.modes{display:flex;height:12px;border-radius:4px;overflow:hidden;gap:2px;background:var(--plane)}
.modes i{display:block;height:100%}
.mlegend{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:.8rem;color:var(--ink-2);margin-top:6px}
.mlegend span{display:inline-flex;align-items:center;gap:5px}
.mlegend b{font-weight:600;color:var(--ink)}
.mlegend i{width:10px;height:10px;border-radius:2px;display:inline-block}
.prof svg{display:block;width:100%;height:auto;overflow:visible}
.prof svg text{font-family:"Source Sans 3",system-ui,sans-serif;fill:var(--muted);font-size:11px}
.tbl{width:100%;border-collapse:collapse;font-size:.88rem;font-variant-numeric:tabular-nums}
.tbl td{padding:4px 0;border-bottom:1px solid var(--grid)}
.tbl td:last-child{text-align:right;font-weight:600}
.tip{position:fixed;z-index:1000;pointer-events:none;background:var(--tip-bg);color:var(--tip-ink);padding:6px 9px;border-radius:6px;font-size:.82rem;line-height:1.3;box-shadow:0 4px 14px rgba(0,0,0,.18)}
.tip b{font-weight:600}
.leaflet-popup-content{font-size:.85rem;line-height:1.35;margin:8px 12px}
.leaflet-popup-content b{font-weight:600}
.mode{display:flex;gap:6px;margin-top:8px}
.explore{overflow-y:auto;flex:1;min-height:0;padding:12px 14px 20px}
.explore .why{font-size:.85rem;color:var(--ink-2);margin:4px 0 8px}
.explore .txt{margin:0;font-size:.92rem}
.explore h2{margin:0;font-size:1.3rem;font-weight:600;line-height:1.15}
.explore .when{color:var(--ink-2);font-size:.92rem;margin:4px 0 10px}
.explore .back{border:0;background:transparent;color:var(--route);font:inherit;font-size:.9rem;cursor:pointer;padding:0;margin-bottom:6px}
.ck{display:flex;gap:8px;align-items:flex-start;font-size:.88rem;margin:4px 0 10px;cursor:pointer}
.ck input{margin-top:3px}
.trails{display:grid;gap:6px;margin-bottom:8px}
.trow{display:grid;grid-template-columns:1fr 90px 40px;gap:8px;align-items:center;font-size:.86rem}
.trow small{color:var(--muted)}
.tbar{height:8px;background:var(--plane);border-radius:4px;overflow:hidden}
.tbar i{display:block;height:100%;border-radius:4px}
.tpct{text-align:right;font-variant-numeric:tabular-nums;font-weight:600}
.sug{display:grid;grid-template-columns:1fr auto;gap:2px 10px;padding:9px 10px;margin:0 -10px;border:0;border-bottom:1px solid var(--grid);cursor:pointer;background:transparent;width:calc(100% + 20px);text-align:left;font:inherit;color:inherit}
.sug:hover{background:var(--hover)}
.sug .d{font-weight:600}
.sug .n{color:var(--ink-2);font-size:.85rem;grid-column:1/-1}
.sug .k{color:var(--ink);font-variant-numeric:tabular-nums;font-weight:600;text-align:right;white-space:nowrap}
.opts{display:flex;gap:6px;margin:6px 0 12px}
.opts .chip[aria-pressed="true"]{background:var(--c);border-color:var(--c);color:#fff}
.wps{margin:0;padding-left:20px;font-size:.9rem}
.wps li{margin:2px 0}
.acts{display:flex;flex-direction:column;gap:8px;margin:14px 0 8px}
.btn{display:block;text-align:center;border:1px solid var(--ring);background:var(--ink);color:var(--surface);font:inherit;font-size:.92rem;padding:9px 12px;border-radius:8px;cursor:pointer;text-decoration:none}
.btn:hover{opacity:.9}
body.embed .top h1{font-size:1.1rem}
body.embed .top .sub{display:none}
@media (max-width:820px){
  main{grid-template-columns:1fr;grid-template-rows:55vh 1fr}
  .side{border-left:0;border-top:1px solid var(--ring)}
}
</style>
</head>
<body>
<header class="top">
  <div><h1>Nic's Ride Map</h1><div class="sub" id="sub"></div></div>
  <div class="spacer"></div>
  <div role="group" aria-label="Year">
    <button class="chip" data-year="all" aria-pressed="true" id="y-all">All</button>
    <button class="chip" data-year="2025" aria-pressed="false" id="y-2025">2025</button>
    <button class="chip" data-year="2026" aria-pressed="false" id="y-2026">2026</button>
  </div>
</header>
<main>
  <div id="map"></div>
  <aside class="side">
    <div class="head"><h2 id="sidetitle">Rides</h2><div class="cnt" id="cnt"></div>
      <div class="mode" role="group" aria-label="Panel"><button class="chip" data-mode="rides" aria-pressed="true" id="m-rides">Rides</button><button class="chip" data-mode="explore" aria-pressed="false" id="m-explore">Explore</button></div></div>
    <div class="list" id="list"></div>
    <div class="detail" id="detail" hidden></div>
    <div class="explore" id="explore" hidden></div>
  </aside>
</main>
<div class="tip" id="tip" hidden></div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<script>
const DATA = __DATA__;
const NS='http://www.w3.org/2000/svg';
const MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const MODES=['Off','Eco','Tour+','Auto','Turbo'], MCOL=['#2a78d6','#eb6834','#1baf7a','#eda100','#e87ba4'];
const ROUTE='#2a78d6', SEL='#eb6834', DIM='#9aa0a6';
const rides=DATA.rides.slice().sort((a,b)=>a.d<b.d?1:-1);
rides.forEach(r=>{ r.hasGps=r.pts.length>1; });
const byId=Object.fromEntries(rides.map(r=>[r.id,r]));

function el(tag,attrs,parent){ const e=document.createElementNS(NS,tag); for(const k in attrs) e.setAttribute(k,attrs[k]); if(parent) parent.appendChild(e); return e; }
function h(tag,cls,parent,text){ const e=document.createElement(tag); if(cls) e.className=cls; if(text!=null) e.textContent=text; if(parent) parent.appendChild(e); return e; }
function fmt(v,dp){ return v==null?'':Number(v).toLocaleString('en-AU',{minimumFractionDigits:dp||0,maximumFractionDigits:dp||0}); }
function dmy(d){ const [y,m,dd]=d.split('-'); return (+dd)+' '+MON[+m-1]+' '+y; }
function dow(d){ return ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][new Date(d+'T00:00:00Z').getUTCDay()]; }
function dur(s){ const hh=Math.floor(s/3600), mm=Math.round((s%3600)/60); return hh? hh+' h '+mm+' min' : mm+' min'; }
function median(a){ const s=a.slice().sort((x,y)=>x-y); const m=s.length>>1; return s.length? (s.length%2? s[m] : (s[m-1]+s[m])/2) : 0; }

/* ---------- map ---------- */
const map=L.map('map',{zoomControl:true});
const streets=L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'}).addTo(map);
const topo=L.tileLayer('https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',{maxZoom:17,attribution:'&copy; OpenStreetMap contributors, SRTM | &copy; <a href="https://opentopomap.org">OpenTopoMap</a>'});
L.control.layers({'Streets':streets,'Terrain':topo},null,{position:'topright'}).addTo(map);
const ViewCtl=L.Control.extend({onAdd(){ const d=L.DomUtil.create('div','ctlbox'); L.DomEvent.disableClickPropagation(d); const b1=h('button','ib',d,'Home'); b1.title='Zoom to your regular routes'; b1.addEventListener('click',zoomHome); const b2=h('button','ib',d,'Every ride'); b2.addEventListener('click',zoomAll); return d; }});
new ViewCtl({position:'topleft'}).addTo(map);
L.control.scale({imperial:false}).addTo(map);

let year='all', selected=null; const lines={}; let selLayer=null, startMk=null, endMk=null;
function visible(){ return rides.filter(r=>r.hasGps && (year==='all'||r.d.slice(0,4)===year)); }
function latlngs(r){ return r.pts.map(p=>[p[0],p[1]]); }
function drawMap(){
  Object.values(lines).forEach(l=>map.removeLayer(l)); for(const k in lines) delete lines[k];
  visible().forEach(r=>{ const l=L.polyline(latlngs(r),{color:ROUTE,weight:2.5,opacity:.6}).addTo(map); lines[r.id]=l;
    l.bindTooltip('<b>'+dow(r.d)+' '+dmy(r.d)+'</b><br>'+fmt(r.km,1)+' km · '+fmt(r.up)+' m climb · '+fmt(r.pw)+' W',{sticky:true});
    l.on('mouseover',()=>{ if(selected!==r.id) l.setStyle({weight:4,opacity:1}); });
    l.on('mouseout',()=>{ if(selected!==r.id) l.setStyle({weight:2.5,opacity:selected?.35:.6}); });
    l.on('click',ev=>{ L.DomEvent.stopPropagation(ev); select(r.id,false); }); });
  restyle();
}
function restyle(){ Object.entries(lines).forEach(([id,l])=>{ const on=id===selected; l.setStyle({color:on?SEL:(selected?DIM:ROUTE),weight:on?4.5:2.5,opacity:on?1:(selected?.45:.6)}); if(on) l.bringToFront(); }); }
function drawSelection(){
  [selLayer,startMk,endMk].forEach(x=>{ if(x) map.removeLayer(x); }); selLayer=startMk=endMk=null; restyle();
  if(!selected) return; const r=byId[selected]; if(!r.hasGps) return;
  if(!lines[r.id]){ selLayer=L.polyline(latlngs(r),{color:SEL,weight:4.5,opacity:1}).addTo(map); }
  const s=r.pts[0], e=r.pts[r.pts.length-1];
  startMk=L.circleMarker([s[0],s[1]],{radius:6,color:SEL,weight:3,fillColor:'#fff',fillOpacity:1}).addTo(map).bindTooltip('Track starts here (privacy zone)');
  endMk=L.circleMarker([e[0],e[1]],{radius:6,color:'#fff',weight:2,fillColor:SEL,fillOpacity:1}).addTo(map).bindTooltip('Track ends here (privacy zone)');
}
function zoomAll(){ const v=visible(); if(!v.length) return; map.fitBounds(L.latLngBounds(v.flatMap(latlngs)),{padding:[20,20]}); }
function zoomHome(){ const v=visible(); if(!v.length) return; const starts=v.map(r=>r.pts[0]); const clat=median(starts.map(p=>p[0])), clon=median(starts.map(p=>p[1])); const near=v.filter(r=>Math.hypot((r.pts[0][0]-clat)*110.57,(r.pts[0][1]-clon)*88)<6); map.fitBounds(L.latLngBounds((near.length?near:v).flatMap(latlngs)),{padding:[20,20]}); }
map.on('click',()=>select(null));

/* ---------- list & detail ---------- */
const list=document.getElementById('list'), detail=document.getElementById('detail'), tip=document.getElementById('tip');
function moveTip(ev){ const w=tip.offsetWidth,hh=tip.offsetHeight; let x=ev.clientX+14,y=ev.clientY+14; if(x+w>innerWidth-8)x=ev.clientX-w-14; if(y+hh>innerHeight-8)y=ev.clientY-hh-14; tip.style.left=x+'px'; tip.style.top=y+'px'; }
function hideTip(){ tip.hidden=true; }
function drawList(){
  list.replaceChildren(); const rs=rides.filter(r=>year==='all'||r.d.slice(0,4)===year);
  document.getElementById('cnt').textContent=rs.length+' rides · '+fmt(rs.reduce((a,r)=>a+r.km,0))+' km';
  rs.forEach(r=>{ const b=h('button','ride'+(r.hasGps?'':' nogps'),list); b.id='ride-'+r.id.slice(0,8); b.setAttribute('aria-selected',String(selected===r.id)); h('span','d',b,dow(r.d)+' '+dmy(r.d)); h('span','k',b,fmt(r.km,1)+' km'); h('span','n',b,r.t+' · '+dur(r.dur)+' · '+fmt(r.up)+' m climb · '+fmt(r.pw)+' W');
    b.addEventListener('click',()=>select(r.id,true)); });
  document.getElementById('sub').textContent=rides.filter(r=>r.hasGps).length+' of '+rides.length+' rides have a GPS track · '+dmy(rides[rides.length-1].d)+' to '+dmy(rides[0].d)+(DATA.privacyM?' · first and last '+DATA.privacyM+' m of every ride hidden':'');
}
function select(id,fit){
  if(id&&exploreMode){ exploreMode=false; explore.hidden=true; clearSuggestion(); curSug=null; document.querySelectorAll('.chip[data-mode]').forEach(c=>c.setAttribute('aria-pressed',String(c.dataset.mode==='rides'))); }
  selected=id; drawSelection();
  list.querySelectorAll('.ride').forEach(b=>b.setAttribute('aria-selected',String(b.id==='ride-'+(id||'').slice(0,8))));
  if(!id){ if(exploreMode) return; detail.hidden=true; list.hidden=false; document.getElementById('sidetitle').textContent='Rides'; drawList(); return; }
  const r=byId[id]; renderDetail(r); detail.hidden=false; list.hidden=true; document.getElementById('sidetitle').textContent='Ride'; document.getElementById('cnt').textContent=r.hasGps?'Orange line on the map':'This ride has no GPS track';
  if(fit&&r.hasGps) map.fitBounds(L.latLngBounds(latlngs(r)),{padding:[30,30]});
  try{ localStorage.setItem('ridemap-sel',id); }catch(e){}
}
function renderDetail(r){
  detail.replaceChildren();
  const back=h('button','back',detail,'← All rides'); back.id='back'; back.addEventListener('click',()=>select(null));
  h('h2',null,detail,dow(r.d)+' '+dmy(r.d));
  h('div','when',detail,'Started '+r.t+' · '+dur(r.dur)+' moving'+(r.hasGps?'':' · no GPS track for this ride'));
  const kv=h('div','kv',detail);
  [['Distance',fmt(r.km,1),'km'],['Climbing',fmt(r.up),'m'],['Avg speed',fmt(r.sp,1),'km/h'],['Max speed',fmt(r.msp,1),'km/h'],['Rider power',fmt(r.pw),'W'],['Max power',fmt(r.mpw),'W'],['Your share',fmt(r.sh),'%'],['Calories',fmt(r.cal),'kcal'],['Cadence',fmt(r.cad),'rpm'],['CO2 saved',fmt(r.co2/1000,1),'kg']].forEach(([l,v,u])=>{ const d=h('div',null,kv); h('div','lab',d,l); const n=h('div','num',d,v); h('small',null,n,u); });
  h('div','sec',detail,'Assist mode, share of distance');
  const tot=r.m.reduce((a,b)=>a+b,0)||1; const bar=h('div','modes',detail); const lg=h('div','mlegend',detail);
  r.m.forEach((v,i)=>{ if(v<=0) return; const i2=document.createElement('i'); i2.style.width=(100*v/tot)+'%'; i2.style.background=MCOL[i]; bar.appendChild(i2); const s=h('span',null,lg); const sw=document.createElement('i'); sw.style.background=MCOL[i]; s.appendChild(sw); s.appendChild(document.createTextNode(MODES[i]+' ')); h('b',null,s,fmt(100*v/tot)+'%'); });
  if(r.hasGps){ const pts=r.pts;
    if(pts.some(p=>p[3]!=null)){ h('div','sec',detail,'Elevation along the ride'); profile(detail,r,3,'m',true); }
    h('div','sec',detail,'Rider power along the ride'); profile(detail,r,5,'W',false);
    h('div','sec',detail,'Speed along the ride'); profile(detail,r,4,'km/h',false); }
  h('div','sec',detail,'More');
  const t=h('table','tbl',detail); [['Elevation loss',fmt(r.dn)+' m'],['Brake events',r.brk==null?'not recorded':fmt(r.brk)],['ABS interventions',r.abs==null?'not recorded':fmt(r.abs)],['Bosch title',r.title]].forEach(([k,v])=>{ const tr=h('tr',null,t); h('td',null,tr,k); h('td',null,tr,v); });
}
let posMk=null;
function profile(parent,r,idx,unit,area){
  const pts=r.pts; const box=h('div','prof',parent); const W=330,H=90,L=30,R=6,T=8,B=18;
  const xs=pts.map(p=>p[2]); const vals=pts.map(p=>p[idx]); const vv=vals.filter(v=>v!=null); if(!vv.length) return;
  const x0=0,x1=Math.max(...xs)||1; let y0=area?Math.min(...vv):0, y1=Math.max(...vv); if(y1===y0) y1=y0+1; if(area){ const pad=(y1-y0)*0.15; y0=Math.floor(y0-pad); y1=Math.ceil(y1+pad); }
  const sx=v=>L+(v-x0)/(x1-x0)*(W-L-R), sy=v=>T+(1-(v-y0)/(y1-y0))*(H-T-B);
  const s=el('svg',{viewBox:`0 0 ${W} ${H}`},box);
  [y0,y1].forEach(v=>{ el('line',{x1:L,x2:W-R,y1:sy(v),y2:sy(v),stroke:'#e2e4df'},s); const t=el('text',{x:L-4,y:sy(v)+4,'text-anchor':'end'},s); t.textContent=fmt(v); });
  let d='', pen=false; pts.forEach(p=>{ if(p[idx]==null){pen=false;return;} d+=(pen?'L':'M')+sx(p[2]).toFixed(1)+' '+sy(p[idx]).toFixed(1)+' '; pen=true; });
  if(area){ const first=pts.find(p=>p[idx]!=null), last=[...pts].reverse().find(p=>p[idx]!=null); el('path',{d:d+'L'+sx(last[2]).toFixed(1)+' '+sy(y0)+' L'+sx(first[2]).toFixed(1)+' '+sy(y0)+' Z',fill:ROUTE,'fill-opacity':.15},s); }
  el('path',{d,fill:'none',stroke:ROUTE,'stroke-width':1.8,'stroke-linejoin':'round'},s);
  const tx=el('text',{x:W-R,y:H-4,'text-anchor':'end'},s); tx.textContent=fmt(x1,1)+' km'; const tu=el('text',{x:L,y:H-4},s); tu.textContent=unit;
  const xh=el('line',{y1:T,y2:H-B,stroke:'#545b57',visibility:'hidden'},s); const dot=el('circle',{r:3.5,fill:SEL,visibility:'hidden'},s);
  const hit=el('rect',{x:L,y:T,width:W-L-R,height:H-T-B,fill:'transparent'},s); const pt=s.createSVGPoint();
  hit.addEventListener('pointermove',ev=>{ pt.x=ev.clientX; pt.y=ev.clientY; const p=pt.matrixTransform(s.getScreenCTM().inverse()); const km=x0+(p.x-L)/(W-L-R)*(x1-x0); let best=null; pts.forEach(q=>{ if(q[idx]!=null&&(best===null||Math.abs(q[2]-km)<Math.abs(best[2]-km))) best=q; }); if(!best) return; xh.setAttribute('x1',sx(best[2])); xh.setAttribute('x2',sx(best[2])); xh.setAttribute('visibility','visible'); dot.setAttribute('cx',sx(best[2])); dot.setAttribute('cy',sy(best[idx])); dot.setAttribute('visibility','visible'); tip.replaceChildren(); h('b',null,tip,fmt(best[idx],idx===4?1:0)+' '+unit); tip.appendChild(document.createTextNode(' at '+fmt(best[2],1)+' km')); tip.hidden=false; moveTip(ev);
    if(!posMk) posMk=L.circleMarker([best[0],best[1]],{radius:7,color:'#fff',weight:2,fillColor:SEL,fillOpacity:1}).addTo(map); else posMk.setLatLng([best[0],best[1]]); });
  hit.addEventListener('pointerleave',()=>{ xh.setAttribute('visibility','hidden'); dot.setAttribute('visibility','hidden'); hideTip(); if(posMk){ map.removeLayer(posMk); posMk=null; } });
}

/* ---------- Explore: coverage and suggested rides ---------- */
const TRAILS=[
 {n:'Gardiners Creek Trail',w:[[-37.8285,145.0060],[-37.8395,145.0330],[-37.8480,145.0460],[-37.8560,145.0575],[-37.8630,145.0800],[-37.8500,145.1130]]},
 {n:'Main Yarra Trail',w:[[-37.8200,144.9680],[-37.8280,145.0050],[-37.8030,145.0030],[-37.7960,145.0100],[-37.7820,145.0180],[-37.7820,145.0300],[-37.7680,145.0400],[-37.7560,145.0800],[-37.7700,145.0750],[-37.7500,145.1300]]},
 {n:'Anniversary Trail',w:[[-37.7820,145.0180],[-37.7960,145.0500],[-37.8120,145.0620],[-37.8330,145.0700],[-37.8380,145.0730],[-37.8620,145.0760],[-37.8850,145.0700]]},
 {n:'Bay Trail',w:[[-37.8410,144.9350],[-37.8680,144.9740],[-37.8830,144.9800],[-37.9070,144.9880],[-37.9370,145.0000],[-37.9520,145.0030],[-37.9730,145.0140],[-37.9840,145.0300],[-38.0000,145.0600],[-38.0060,145.0870],[-38.0750,145.1230],[-38.1440,145.1220]]},
 {n:'Capital City Trail',w:[[-37.8170,144.9450],[-37.7900,144.9500],[-37.7830,144.9700],[-37.7800,144.9900],[-37.7960,145.0070],[-37.8030,145.0030],[-37.8280,145.0040],[-37.8230,144.9600],[-37.8170,144.9450]]},
 {n:'Merri Creek Trail',w:[[-37.7960,145.0070],[-37.7880,144.9990],[-37.7680,144.9850],[-37.7450,144.9700],[-37.7150,144.9600]]},
 {n:'Darebin Creek Trail',w:[[-37.7820,145.0300],[-37.7660,145.0380],[-37.7400,145.0450],[-37.7100,145.0500]]},
 {n:'Koonung Creek Trail',w:[[-37.7700,145.0750],[-37.7900,145.1150],[-37.8020,145.1250],[-37.8050,145.1500],[-37.8080,145.1700]]},
 {n:'Scotchmans Creek Trail',w:[[-37.8740,145.0790],[-37.8860,145.0960],[-37.8780,145.1260],[-37.8800,145.1650],[-37.8870,145.1960]]},
 {n:'Dandenong Creek Trail',w:[[-37.8250,145.2300],[-37.8600,145.1900],[-37.8880,145.1980],[-37.9300,145.2200],[-37.9850,145.2150],[-38.0750,145.1230]]},
 {n:'Djerring Trail',w:[[-37.8780,145.0430],[-37.8870,145.0580],[-37.8930,145.0800],[-37.9000,145.0900],[-37.9250,145.1200],[-37.9500,145.1520],[-37.9880,145.2150]]},
 {n:'Box Hill to Ringwood Rail Trail',w:[[-37.8190,145.1220],[-37.8190,145.1500],[-37.8200,145.1760],[-37.8180,145.1930],[-37.8150,145.2290]]},
 {n:'Lilydale to Warburton Rail Trail',w:[[-37.7570,145.3540],[-37.7900,145.3830],[-37.7800,145.4260],[-37.7750,145.4640],[-37.7770,145.5350],[-37.7800,145.5730],[-37.7810,145.6140],[-37.7530,145.6900]]},
];
/* Waypoints are corridor markers, not turn by turn. 'H' is replaced by your usual start point. */
const SUGGEST=[
 {id:'bay',name:'Bay Trail south to Mordialloc',target:'Bay Trail',
  blurb:'You have ridden the bay as far as Brighton a handful of times. Everything south of there is new: the beach boxes, Sandringham, the Black Rock cliffs and the long flat run to Mordialloc.',
  scenic:{km:null,flat:true,follows:'Back streets to Elwood, then the Bay Trail the whole way south. Home via quiet Bentleigh and Caulfield streets.',surface:'Sealed shared path along the foreshore, a few short on road sections around Sandringham.',
   w:['H',[-37.8620,145.0300,'Malvern back streets'],[-37.8730,145.0250,'Caulfield Park'],[-37.8850,145.0040,'Elsternwick'],[-37.8830,144.9800,'Elwood beach, join the Bay Trail'],[-37.9180,144.9860,'Brighton beach boxes'],[-37.9520,145.0030,'Sandringham'],[-37.9730,145.0140,'Black Rock, Half Moon Bay'],[-37.9840,145.0300,'Beaumaris'],[-38.0000,145.0600,'Mentone'],[-38.0060,145.0870,'Mordialloc pier, turn for home'],[-37.9670,145.0540,'Cheltenham back streets'],[-37.9425,145.0580,'Moorabbin'],[-37.9180,145.0350,'Bentleigh'],[-37.8950,145.0300,'Caulfield South'],[-37.8770,145.0500,'Malvern East'],'H']},
  direct:{km:null,flat:true,follows:'Back streets to Elwood, Bay Trail to Black Rock, and back the same way.',surface:'Sealed shared path and quiet streets.',
   w:['H',[-37.8620,145.0300,'Malvern back streets'],[-37.8730,145.0250,'Caulfield Park'],[-37.8850,145.0040,'Elsternwick'],[-37.8830,144.9800,'Elwood beach, join the Bay Trail'],[-37.9180,144.9860,'Brighton'],[-37.9520,145.0030,'Sandringham'],[-37.9730,145.0140,'Black Rock, turn around'],[-37.9520,145.0030,'Sandringham'],[-37.8830,144.9800,'Elwood'],[-37.8850,145.0040,'Elsternwick'],[-37.8730,145.0250,'Caulfield Park'],'H']}},
 {id:'dandy',name:'Dandenong Creek Trail loop',target:'Dandenong Creek Trail',
  blurb:'Your least ridden big trail. Out along Scotchmans Creek to Jells Park, then down Dandenong Creek through wetlands and parkland, and home on the Djerring Trail beside the railway.',
  scenic:{km:null,flat:true,follows:'Gardiners Creek Trail, Scotchmans Creek Trail, Dandenong Creek Trail south to Dandenong, Djerring Trail west, Anniversary Trail home.',surface:'Sealed shared paths almost the whole way. A long day, take food.',
   w:['H',[-37.8740,145.0790,'Holmesglen, leave Gardiners Creek'],[-37.8860,145.0960,'Chadstone, Scotchmans Creek Trail'],[-37.8780,145.1260,'Mount Waverley'],[-37.8800,145.1650,'Glen Waverley'],[-37.8870,145.1960,'Jells Park lake'],[-37.9300,145.2200,'Rowville, Dandenong Creek Trail'],[-37.9880,145.2150,'Dandenong, join the Djerring Trail'],[-37.9500,145.1520,'Springvale'],[-37.9250,145.1200,'Clayton'],[-37.9000,145.0900,'Oakleigh'],[-37.8930,145.0800,'Hughesdale, Anniversary Trail'],'H']},
  direct:{km:null,flat:true,follows:'Gardiners Creek Trail and Scotchmans Creek Trail to Jells Park, back the same way.',surface:'Sealed shared paths.',
   w:['H',[-37.8740,145.0790,'Holmesglen'],[-37.8860,145.0960,'Chadstone, Scotchmans Creek Trail'],[-37.8780,145.1260,'Mount Waverley'],[-37.8800,145.1650,'Glen Waverley'],[-37.8870,145.1960,'Jells Park lake, turn around'],[-37.8800,145.1650,'Glen Waverley'],[-37.8780,145.1260,'Mount Waverley'],[-37.8860,145.0960,'Chadstone'],[-37.8740,145.0790,'Holmesglen'],'H']}},
 {id:'koonung',name:'Koonung Creek and the rail trail to Ringwood',target:'Koonung Creek Trail',
  blurb:'Two trails you have barely touched, joined into a loop. North on the Anniversary Trail, along the Yarra to Bulleen, east beside Koonung Creek, then home on the Box Hill to Ringwood rail trail.',
  scenic:{km:null,flat:false,follows:'Anniversary Trail, Main Yarra Trail, Koonung Creek Trail to Springvale Road, Box Hill to Ringwood Rail Trail, Surrey Hills back streets.',surface:'Sealed paths, some short hills beside the freeway at Doncaster.',
   w:['H',[-37.8330,145.0700,'Camberwell, Anniversary Trail'],[-37.8120,145.0620,'Deepdene'],[-37.7960,145.0500,'Kew East'],[-37.7700,145.0750,'Bulleen, Banksia Park'],[-37.7900,145.1150,'Doncaster, Koonung Creek Trail'],[-37.8020,145.1250,'Box Hill North'],[-37.8050,145.1500,'Blackburn North'],[-37.8080,145.1700,'Springvale Road'],[-37.8200,145.1760,'Nunawading, rail trail'],[-37.8150,145.2290,'Ringwood, turn for home'],[-37.8190,145.1500,'Blackburn'],[-37.8190,145.1220,'Box Hill'],[-37.8250,145.1000,'Surrey Hills back streets'],[-37.8330,145.0700,'Camberwell'],'H']},
  direct:{km:null,flat:false,follows:'Anniversary Trail to Camberwell, quiet streets through Canterbury and Mont Albert to Box Hill, rail trail to Ringwood and back.',surface:'Sealed paths and back streets.',
   w:['H',[-37.8330,145.0700,'Camberwell'],[-37.8240,145.0850,'Canterbury'],[-37.8200,145.1050,'Mont Albert back streets'],[-37.8190,145.1220,'Box Hill, rail trail'],[-37.8200,145.1760,'Nunawading'],[-37.8150,145.2290,'Ringwood, turn around'],[-37.8200,145.1760,'Nunawading'],[-37.8190,145.1220,'Box Hill'],[-37.8200,145.1050,'Mont Albert'],[-37.8330,145.0700,'Camberwell'],'H']}},
 {id:'yarraeast',name:'Main Yarra Trail east to Westerfolds and Eltham',target:'Main Yarra Trail',
  blurb:'You ride the Yarra to Heidelberg often but stop there. The trail keeps going through Banyule Flats and Westerfolds Park to Eltham, the wildest stretch of river in the suburbs.',
  scenic:{km:null,flat:false,follows:'Gardiners Creek Trail, Main Yarra Trail all the way to Eltham Lower Park, back to Fairfield, Anniversary Trail home.',surface:'Sealed path with a few gravel sections and short climbs past Templestowe.',
   w:['H',[-37.8285,145.0060,'Yarra at Burnley'],[-37.7960,145.0100,'Yarra Bend'],[-37.7820,145.0180,'Fairfield'],[-37.7680,145.0400,'Ivanhoe'],[-37.7560,145.0800,'Heidelberg'],[-37.7500,145.0950,'Banyule Flats'],[-37.7500,145.1300,'Westerfolds Park'],[-37.7300,145.1400,'Eltham Lower Park, turn around'],[-37.7500,145.1300,'Westerfolds Park'],[-37.7560,145.0800,'Heidelberg'],[-37.7820,145.0180,'Fairfield, Anniversary Trail'],[-37.7960,145.0500,'Kew East'],[-37.8330,145.0700,'Camberwell'],'H']},
  direct:{km:null,flat:false,follows:'Anniversary Trail north, join the Yarra at the Burke Road bridge, east to Westerfolds Park and back.',surface:'Sealed path.',
   w:['H',[-37.8330,145.0700,'Camberwell'],[-37.7960,145.0500,'Kew East'],[-37.7850,145.0550,'Burke Road bridge, Main Yarra Trail'],[-37.7560,145.0800,'Heidelberg'],[-37.7500,145.1300,'Westerfolds Park, turn around'],[-37.7560,145.0800,'Heidelberg'],[-37.7850,145.0550,'Burke Road bridge'],[-37.7960,145.0500,'Kew East'],[-37.8330,145.0700,'Camberwell'],'H']}},
 {id:'city',name:'Capital City Trail, the western half',target:'Capital City Trail',
  blurb:'You know the river into town. The other side of the loop, Docklands, Royal Park and Princes Park, is the part you have not done.',
  scenic:{km:null,flat:true,follows:'Gardiners Creek and Main Yarra trails to Southbank, Capital City Trail through Docklands, Royal Park, Princes Park and Merri Creek to Dights Falls, Main Yarra Trail home.',surface:'Sealed shared paths, busy near Southbank on weekends.',
   w:['H',[-37.8285,145.0060,'Yarra at Burnley'],[-37.8210,144.9640,'Southbank promenade'],[-37.8170,144.9450,'Docklands'],[-37.7900,144.9500,'Royal Park'],[-37.7830,144.9680,'Princes Park'],[-37.7800,144.9900,'Rushall, Merri Creek'],[-37.7960,145.0070,'Dights Falls'],[-37.8030,145.0030,'Abbotsford'],[-37.8285,145.0060,'Burnley'],'H']},
  direct:{km:null,flat:true,follows:'Gardiners Creek and Main Yarra trails to Southbank and Docklands, back the same way.',surface:'Sealed shared paths.',
   w:['H',[-37.8285,145.0060,'Yarra at Burnley'],[-37.8210,144.9640,'Southbank'],[-37.8170,144.9450,'Docklands, turn around'],[-37.8210,144.9640,'Southbank'],[-37.8285,145.0060,'Burnley'],'H']}},
 {id:'warby',name:'Lilydale to Warburton Rail Trail, from the Lilydale end',target:'Lilydale to Warburton Rail Trail',
  blurb:'You have done the Warburton end. Take the bike on the train to Lilydale and ride the western half through Mount Evelyn, Wandin and Seville, which you have never seen.',
  scenic:{km:null,flat:false,follows:'The rail trail from Lilydale station all the way to Warburton and back. Gentle climb to Mount Evelyn, then mostly downhill to the Yarra.',surface:'Compacted gravel, fine on the eBike. No cars at all.',
   w:[[-37.7570,145.3540,'Lilydale station, bikes on the train'],[-37.7900,145.3830,'Mount Evelyn'],[-37.7800,145.4260,'Wandin'],[-37.7750,145.4640,'Seville'],[-37.7770,145.5350,'Woori Yallock'],[-37.7800,145.5730,'Launching Place'],[-37.7810,145.6140,'Yarra Junction'],[-37.7530,145.6900,'Warburton, turn around'],[-37.7810,145.6140,'Yarra Junction'],[-37.7770,145.5350,'Woori Yallock'],[-37.7750,145.4640,'Seville'],[-37.7900,145.3830,'Mount Evelyn'],[-37.7570,145.3540,'Lilydale station']]},
  direct:{km:null,flat:false,follows:'Lilydale to Woori Yallock and back, the half you have not ridden.',surface:'Compacted gravel rail trail.',
   w:[[-37.7570,145.3540,'Lilydale station, bikes on the train'],[-37.7900,145.3830,'Mount Evelyn'],[-37.7800,145.4260,'Wandin'],[-37.7750,145.4640,'Seville'],[-37.7770,145.5350,'Woori Yallock, turn around'],[-37.7750,145.4640,'Seville'],[-37.7900,145.3830,'Mount Evelyn'],[-37.7570,145.3540,'Lilydale station']]}},
];
const SCEN='#1baf7a', DIR='#7c5cd6';
const kmBetween=(a,b)=>Math.hypot((a[0]-b[0])*110.57,(a[1]-b[1])*88);
function homePoint(){ if(DATA.home) return [DATA.home[0],DATA.home[1],DATA.home[2]+', near your usual start']; const s=rides.filter(r=>r.hasGps).map(r=>r.pts[0]); return [median(s.map(p=>p[0])),median(s.map(p=>p[1])),'Home, your usual start']; }
function resolveW(w){ const hm=homePoint(); return w.map(p=>p==='H'? hm : p); }
function optKm(w){ const pts=resolveW(w); let d=0; for(let i=1;i<pts.length;i++) d+=kmBetween(pts[i-1],pts[i]); return Math.round(d*1.12); }
function optTime(km,scenic){ const speed=scenic?19:21; const mins=Math.round(km/speed*60*1.15); const hh=Math.floor(mins/60), mm=mins%60; return (hh?hh+' h ':'')+mm+' min'; }

/* coverage of trail corridors and 1 km cells, from your own tracks */
function buildIndex(){ const g=new Map(); rides.forEach(r=>{ if(!r.hasGps) return; r.pts.forEach(p=>{ const k=Math.floor(p[0]/0.005)+','+Math.floor(p[1]/0.005); if(!g.has(k)) g.set(k,[]); g.get(k).push(p); }); }); return g; }
function coveredBy(g,q,th){ const gi=Math.floor(q[0]/0.005), gj=Math.floor(q[1]/0.005); for(let i=gi-1;i<=gi+1;i++) for(let j=gj-1;j<=gj+1;j++){ const c=g.get(i+','+j); if(c) for(const p of c) if(kmBetween(p,q)<th) return true; } return false; }
function trailCoverage(){ const g=buildIndex(); return TRAILS.map(t=>{ const s=[]; let L=0; for(let i=1;i<t.w.length;i++){ const a=t.w[i-1], b=t.w[i]; const d=kmBetween(a,b); L+=d; const n=Math.max(1,Math.round(d/0.3)); for(let k=0;k<n;k++) s.push([a[0]+(b[0]-a[0])*k/n,a[1]+(b[1]-a[1])*k/n]); } const c=s.filter(q=>coveredBy(g,q,0.35)).length; return {n:t.n,km:Math.round(L),pct:Math.round(100*c/s.length)}; }).sort((a,b)=>a.pct-b.pct); }

let cellLayer=null, trailLayer=null, sugLayer=null, sugMarkers=[], exploreMode=false, curSug=null, curOpt='scenic';
function toggleCells(on){
  if(cellLayer){ map.removeLayer(cellLayer); cellLayer=null; }
  if(!on) return;
  const hm=homePoint(); const counts=new Map(); const cell=0.009, cellLon=0.0114;
  rides.forEach(r=>{ if(!r.hasGps) return; const seen=new Set(); r.pts.forEach(p=>{ seen.add(Math.floor(p[0]/cell)+','+Math.floor(p[1]/cellLon)); }); seen.forEach(k=>counts.set(k,(counts.get(k)||0)+1)); });
  const rects=[]; const R=12; const ci=Math.floor(hm[0]/cell), cj=Math.floor(hm[1]/cellLon); const ni=Math.ceil(R/(cell*110.57)), nj=Math.ceil(R/(cellLon*88));
  for(let i=ci-ni;i<=ci+ni;i++) for(let j=cj-nj;j<=cj+nj;j++){ const la=(i+0.5)*cell, lo=(j+0.5)*cellLon; if(kmBetween([la,lo],hm)>R) continue; const n=counts.get(i+','+j)||0; const b=[[i*cell,j*cellLon],[(i+1)*cell,(j+1)*cellLon]];
    if(n) rects.push(L.rectangle(b,{color:ROUTE,weight:0,fillColor:ROUTE,fillOpacity:Math.min(.55,.12+n*.06),interactive:false}));
    else rects.push(L.rectangle(b,{color:'#9a6b1f',weight:1,opacity:.35,fillColor:'#e0b15a',fillOpacity:.22,interactive:false})); }
  cellLayer=L.layerGroup(rects).addTo(map);
}
function showSuggestion(s,opt){
  curSug=s; curOpt=opt; clearSuggestion();
  const o=s[opt]; const pts=resolveW(o.w); const col=opt==='scenic'?SCEN:DIR;
  sugLayer=L.polyline(pts.map(p=>[p[0],p[1]]),{color:col,weight:5,opacity:.85,dashArray:'1 9',lineCap:'round'}).addTo(map);
  pts.forEach((p,i)=>{ const first=i===0, last=i===pts.length-1; const m=L.circleMarker([p[0],p[1]],{radius:first||last?7:5,color:'#fff',weight:2,fillColor:col,fillOpacity:1}).addTo(map).bindTooltip((i+1)+'. '+(p[2]||'')); sugMarkers.push(m); });
  map.fitBounds(L.latLngBounds(pts.map(p=>[p[0],p[1]])),{padding:[30,30]});
}
function clearSuggestion(){ if(sugLayer){ map.removeLayer(sugLayer); sugLayer=null; } sugMarkers.forEach(m=>map.removeLayer(m)); sugMarkers=[]; }
function gmapsUrl(w){ const pts=resolveW(w); const ll=p=>p[0].toFixed(5)+','+p[1].toFixed(5); const mid=pts.slice(1,-1); const step=Math.max(1,Math.ceil(mid.length/8)); const wp=mid.filter((p,i)=>i%step===0).slice(0,8); return 'https://www.google.com/maps/dir/?api=1&travelmode=bicycling&origin='+ll(pts[0])+'&destination='+ll(pts[pts.length-1])+(wp.length?'&waypoints='+encodeURIComponent(wp.map(ll).join('|')):''); }
function gpx(s,opt){ const pts=resolveW(s[opt].w); const esc=t=>String(t).replace(/&/g,'&amp;').replace(/</g,'&lt;'); let x='<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Nic\'s Ride Map" xmlns="http://www.topografix.com/GPX/1/1">\n<rte><name>'+esc(s.name+' ('+opt+')')+'</name>\n'; pts.forEach(p=>{ x+='<rtept lat="'+p[0].toFixed(5)+'" lon="'+p[1].toFixed(5)+'"><name>'+esc(p[2]||'')+'</name></rtept>\n'; }); x+='</rte>\n</gpx>\n'; const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob([x],{type:'application/gpx+xml'})); a.download=(s.id+'_'+opt+'.gpx'); document.body.appendChild(a); a.click(); a.remove(); }

const explore=document.getElementById('explore');
function drawExplore(){
  explore.replaceChildren();
  const cov=trailCoverage();
  h('div','sec',explore,'Where you have not ridden');
  const cb=h('label','ck',explore); const inp=document.createElement('input'); inp.type='checkbox'; inp.id='cells'; inp.checked=!!cellLayer; inp.addEventListener('change',()=>toggleCells(inp.checked)); cb.appendChild(inp); cb.appendChild(document.createTextNode(' Shade the map: blue where you have ridden, amber squares within 12 km of home that you have never crossed'));
  h('p','why',explore,'Trail corridors, least ridden first. The bar is how much of each trail your tracks pass within about 350 m of.');
  const tl=h('div','trails',explore);
  cov.forEach(t=>{ const row=h('div','trow',tl); const nm=h('div',null,row); h('b',null,nm,t.n); h('small',null,nm,' '+t.km+' km'); const bar=h('div','tbar',row); const fill=document.createElement('i'); fill.style.width=t.pct+'%'; fill.style.background=t.pct<40?'#c98500':ROUTE; bar.appendChild(fill); h('span','tpct',row,t.pct+'%'); });
  h('div','sec',explore,'Suggested rides');
  h('p','why',explore,'Each ride has a scenic option that follows trails as far as possible and a direct option that keeps to trails, bike lanes and back streets but gets there sooner. Times use your own average speed with a stop allowance.');
  SUGGEST.forEach(s=>{ const b=h('button','sug',explore); b.id='sug-'+s.id; h('span','d',b,s.name); h('span','k',b,optKm(s.scenic.w)+' / '+optKm(s.direct.w)+' km'); h('span','n',b,'Targets: '+s.target+' · scenic / direct'); b.addEventListener('click',()=>openSuggestion(s,'scenic')); });
  h('p','why',explore,'Dotted lines are corridors, not turn by turn directions. Use the Google Maps button for cycling directions along the corridor, or download the GPX and open it in Komoot or the Bosch Flow app, which will route between the points on bike paths.');
}
function openSuggestion(s,opt){
  showSuggestion(s,opt); exploreDetail(s,opt);
}
function exploreDetail(s,opt){
  explore.replaceChildren();
  const back=h('button','back',explore,'← All suggestions'); back.addEventListener('click',()=>{ clearSuggestion(); curSug=null; drawExplore(); });
  h('h2',null,explore,s.name); h('div','when',explore,s.blurb);
  const tabs=h('div','opts',explore);
  [['scenic','Scenic'],['direct','Direct']].forEach(([k,lab])=>{ const b=h('button','chip',tabs,lab); b.id='opt-'+k; b.setAttribute('aria-pressed',String(opt===k)); b.style.setProperty('--c',k==='scenic'?SCEN:DIR); b.addEventListener('click',()=>openSuggestion(s,k)); });
  const o=s[opt]; const km=optKm(o.w);
  const kv=h('div','kv',explore);
  [['Distance','about '+km,'km'],['Time',optTime(km,opt==='scenic'),''],['Terrain',o.flat?'Flat':'Some hills',''],['Traffic','Trails and back streets','']].forEach(([l,v,u])=>{ const d=h('div',null,kv); h('div','lab',d,l); const n=h('div','num',d,v); n.style.fontSize='1.05rem'; if(u) h('small',null,n,u); });
  h('div','sec',explore,'Follows'); h('p','txt',explore,o.follows);
  h('div','sec',explore,'Surface'); h('p','txt',explore,o.surface);
  h('div','sec',explore,'Waypoints');
  const ol=h('ol','wps',explore); resolveW(o.w).forEach(p=>h('li',null,ol,p[2]||''));
  const acts=h('div','acts',explore);
  const g=h('a','btn',acts,'Cycling directions in Google Maps'); g.href=gmapsUrl(o.w); g.target='_blank'; g.rel='noopener';
  const d=h('button','btn',acts,'Download GPX'); d.addEventListener('click',()=>gpx(s,opt));
  h('p','why',explore,'Distance and time are estimates from the corridor length plus 12 percent for the real path. Check the Google Maps directions before you go.');
}
document.querySelectorAll('.chip[data-mode]').forEach(b=>b.addEventListener('click',()=>{ exploreMode=b.dataset.mode==='explore'; document.querySelectorAll('.chip[data-mode]').forEach(c=>c.setAttribute('aria-pressed',String(c===b)));
  if(exploreMode){ select(null); list.hidden=true; detail.hidden=true; explore.hidden=false; document.getElementById('sidetitle').textContent='Explore'; document.getElementById('cnt').textContent='Gaps in your riding and where to go next'; drawExplore(); }
  else { explore.hidden=true; clearSuggestion(); curSug=null; toggleCells(false); select(null); } }));

/* ---------- year filter ---------- */
document.querySelectorAll('.chip[data-year]').forEach(b=>b.addEventListener('click',()=>{ year=b.dataset.year; document.querySelectorAll('.chip[data-year]').forEach(c=>c.setAttribute('aria-pressed',String(c===b))); if(selected&&year!=='all'&&byId[selected].d.slice(0,4)!==year) selected=null; drawMap(); drawList(); drawSelection(); if(!selected) select(null); }));

if(new URLSearchParams(location.search).get('embed')==='1') document.body.classList.add('embed');
function setMode(mode){ const b=document.querySelector('.chip[data-mode="'+(mode==='explore'?'explore':'rides')+'"]'); if(b&&b.getAttribute('aria-pressed')!=='true') b.click(); }
addEventListener('message',ev=>{ if(ev.data&&ev.data.mode) setMode(ev.data.mode); });
drawMap(); drawList(); zoomHome();
if(location.hash==='#explore') setMode('explore');
let saved=null; try{ saved=localStorage.getItem('ridemap-sel'); }catch(e){}
if(saved&&byId[saved]) select(saved,true);
</script>
</body>
</html>
'@ | Set-Content -Path (Join-Path $Work 'ridemap_osm_template.html') -Encoding UTF8


# ---- optional install of the nightly task -----------------------------------
if ($Install) {
    $Self = Join-Path $Work 'bosch_refresh.ps1'
    Copy-Item -Path $PSCommandPath -Destination $Self -Force
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Self`""
    $trigger  = New-ScheduledTaskTrigger -Daily -At 6:00am
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName 'Bosch ride refresh' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Log "Installed the nightly task 'Bosch ride refresh' (6:00 am daily, or as soon as the PC is next awake). Running the first refresh now."
}

# ---- 0. pull the latest from GitHub first, so the nightly commit never collides ----
$gitPaths = @("$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")
$env:Path = ($gitPaths -join ';') + ';' + $env:Path
$IsClone = (Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $Folder '.git'))
Log 'Refresh started'
if ($IsClone) {
    Push-Location $Folder
    git pull -q --ff-only origin main 2>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { Log 'Could not pull from GitHub (continuing with local files).' }
    Pop-Location
}

# ---- 1. rides ----------------------------------------------------------------
$RidesCsv  = Join-Path $Folder 'bosch_rides.csv'
$TracksCsv = Join-Path $Folder 'bosch_tracks.csv'
$loginArg = if ($Install -or $Login) { @() } else { @('--no-login') }
& uvx --from bosch-flow-mcp python (Join-Path $Work 'bosch_export.py') $RidesCsv @loginArg 2>&1 | ForEach-Object { Log "  $_" }
if ($LASTEXITCODE -ne 0) { Log "Ride pull failed (exit $LASTEXITCODE). Stopping."; exit 1 }

# ---- 2. GPS tracks for any new rides ----------------------------------------
& uvx --from bosch-flow-mcp python (Join-Path $Work 'bosch_tracks.py') $RidesCsv $TracksCsv 2>&1 | ForEach-Object { Log "  $_" }

# ---- 3. rebuild the pages ----------------------------------------------------
& uvx --from bosch-flow-mcp python (Join-Path $Work 'bosch_build.py') $Folder $Work 2>&1 | ForEach-Object { Log "  $_" }

# ---- 4. push to GitHub when the folder is a git clone -----------------------
if ($IsClone) {
    Push-Location $Folder
    git add bosch_dashboard.html bosch_ride_map.html bosch_status.json 2>&1 | Out-Null
    if (git status --porcelain) {
        git commit -q -m "Bosch ride refresh $(Get-Date -Format 'yyyy-MM-dd')" 2>&1 | ForEach-Object { Log "  $_" }
        git push origin main 2>&1 | ForEach-Object { Log "  $_" }
        if ($LASTEXITCODE -eq 0) { Log 'Pushed to GitHub.' } else { Log 'Push to GitHub failed. Run bosch_github_setup.ps1 again to sign in.' }
    } else { Log 'Nothing new to push to GitHub.' }
    Pop-Location
} else { Log 'GitHub push skipped (folder is not a git clone). Run bosch_github_setup.ps1 once to enable it.' }

Log 'Refresh finished'
if ($Install -or $Login) { Start-Process (Join-Path $Folder 'bosch_dashboard.html') }

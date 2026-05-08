"""Generate a self-contained HTML status page for an in-progress render.

Reads supervisor state, current .bin header (samples_done), recent log lines,
and renders a single HTML file with auto-refresh. Open in Chrome via file:// or
serve via `python -m http.server` from the working directory.

The HTML is intentionally simple — all CSS inline, no external assets. Auto-
refresh via meta tag every 10 sec. Dark theme matches the buddhabrot aesthetic.
"""
import argparse
import html
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def read_bin_samples_done(bin_path: Path) -> int:
    if not bin_path.exists():
        return 0
    try:
        with open(bin_path, "rb") as f:
            f.seek(32)  # samples_done offset in HistHeader
            return struct.unpack("<Q", f.read(8))[0]
    except Exception:
        return 0


def tail_lines(path: Path, n: int) -> list[str]:
    if not path.exists():
        return []
    try:
        with open(path, "r", errors="replace") as f:
            return f.readlines()[-n:]
    except Exception:
        return []


def fmt_duration(secs: float) -> str:
    s = int(secs)
    h, r = divmod(s, 3600)
    m, s = divmod(r, 60)
    if h > 0:
        return f"{h}h {m}m {s}s"
    if m > 0:
        return f"{m}m {s}s"
    return f"{s}s"


STATE_COLORS = {
    "RUNNING":  "#4caf50",
    "BACKOFF":  "#ff9800",
    "RETRYING": "#ff9800",
    "DONE":     "#2196f3",
    "FATAL":    "#f44336",
    "STOPPED":  "#9e9e9e",
    "EXITING":  "#9e9e9e",
    "STARTING": "#7986cb",
}


def render_html(args) -> str:
    bin_path = Path(args.bin)
    log_path = Path(args.log)
    watchdog_log = Path(args.watchdog_log)

    samples_done = read_bin_samples_done(bin_path)
    target = int(args.target_samples)
    pct = (samples_done / target * 100.0) if target > 0 else 0.0
    pct = min(pct, 100.0)

    start_ts = float(args.start_ts)
    elapsed = time.time() - start_ts

    if samples_done > 0 and elapsed > 0:
        rate_per_sec = samples_done / elapsed
        remaining = max(target - samples_done, 0)
        eta_sec = remaining / rate_per_sec if rate_per_sec > 0 else 0
    else:
        rate_per_sec = 0
        eta_sec = 0

    log_tail = tail_lines(log_path, 30)
    watchdog_tail = tail_lines(watchdog_log, 10)

    bin_size = bin_path.stat().st_size if bin_path.exists() else 0
    bin_mtime = (
        datetime.fromtimestamp(bin_path.stat().st_mtime, tz=timezone.utc)
        if bin_path.exists()
        else None
    )

    state = args.state.upper()
    state_color = STATE_COLORS.get(state, "#9e9e9e")
    detail = html.escape(args.detail or "")
    render_name = html.escape(args.render_name)
    resolution = html.escape(args.resolution)

    log_html = "".join(html.escape(line) for line in log_tail) or "(no log lines yet)"
    watchdog_html = "".join(html.escape(line) for line in watchdog_tail) or "(no watchdog events)"

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="10">
<title>{render_name} — render status</title>
<style>
* {{ box-sizing: border-box; }}
body {{
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
  background: #0a0e1a; color: #e0e6f0;
  margin: 0; padding: 20px; max-width: 1200px; margin: 0 auto;
}}
h1 {{ color: #82a4f0; margin: 0 0 4px 0; font-size: 22px; }}
.subtitle {{ color: #6b7a99; font-size: 13px; margin-bottom: 20px; }}
.state {{
  display: inline-block; padding: 4px 12px; border-radius: 4px;
  font-weight: bold; font-size: 14px; background: {state_color}; color: #0a0e1a;
}}
.detail {{ display: inline-block; margin-left: 12px; color: #b8c5d6; font-size: 13px; }}
.grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 20px; }}
.card {{ background: #131826; border: 1px solid #1f2940; border-radius: 6px; padding: 16px; }}
.card h2 {{ margin: 0 0 12px 0; color: #82a4f0; font-size: 14px; text-transform: uppercase; letter-spacing: 0.5px; }}
.kv {{ display: grid; grid-template-columns: 140px 1fr; gap: 4px 12px; font-size: 13px; }}
.kv .k {{ color: #6b7a99; }}
.kv .v {{ color: #e0e6f0; font-variant-numeric: tabular-nums; }}
.progress {{
  height: 28px; background: #1f2940; border-radius: 4px; overflow: hidden;
  position: relative; margin: 8px 0;
}}
.progress-bar {{
  height: 100%; background: linear-gradient(90deg, #4caf50, #82a4f0);
  width: {pct:.2f}%; transition: width 0.5s;
}}
.progress-label {{
  position: absolute; top: 0; left: 0; right: 0; bottom: 0;
  display: flex; align-items: center; justify-content: center;
  color: #fff; font-weight: bold; text-shadow: 0 1px 2px rgba(0,0,0,0.6);
  font-size: 13px; font-variant-numeric: tabular-nums;
}}
pre {{
  background: #0a0e1a; border: 1px solid #1f2940; border-radius: 4px;
  padding: 10px; font-size: 11px; line-height: 1.4; color: #b8c5d6;
  overflow-x: auto; margin: 0; max-height: 400px; overflow-y: auto;
  white-space: pre-wrap; word-break: break-all;
}}
.footer {{ margin-top: 20px; color: #6b7a99; font-size: 11px; text-align: center; }}
.full {{ grid-column: 1 / -1; }}
</style>
</head>
<body>
<h1>{render_name}</h1>
<div class="subtitle">{resolution} • target {target:,} samples • auto-refresh every 10 sec</div>

<div>
<span class="state">{state}</span>
<span class="detail">{detail}</span>
</div>

<div class="progress">
  <div class="progress-bar"></div>
  <div class="progress-label">{pct:.2f}% — {samples_done:,} / {target:,} samples</div>
</div>

<div class="grid">
  <div class="card">
    <h2>Watchdog</h2>
    <div class="kv">
      <div class="k">attempt</div><div class="v">{args.attempt} of {args.max_attempts}</div>
      <div class="k">elapsed total</div><div class="v">{fmt_duration(elapsed)}</div>
      <div class="k">render rate</div><div class="v">{rate_per_sec / 1e6:.1f} M/s</div>
      <div class="k">eta to target</div><div class="v">{fmt_duration(eta_sec) if eta_sec > 0 else "—"}</div>
    </div>
  </div>

  <div class="card">
    <h2>Latest .bin</h2>
    <div class="kv">
      <div class="k">path</div><div class="v">{html.escape(str(bin_path))}</div>
      <div class="k">size</div><div class="v">{bin_size / (1024**3):.2f} GB</div>
      <div class="k">mtime</div><div class="v">{bin_mtime.strftime("%Y-%m-%d %H:%M:%S UTC") if bin_mtime else "—"}</div>
      <div class="k">samples_done</div><div class="v">{samples_done:,}</div>
    </div>
  </div>

  <div class="card full">
    <h2>buddhabrot stderr (last 30 lines)</h2>
    <pre>{log_html}</pre>
  </div>

  <div class="card full">
    <h2>Watchdog log (last 10 events)</h2>
    <pre>{watchdog_html}</pre>
  </div>
</div>

<div class="footer">Generated {now} · written by tools/write_status_html.py</div>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    ap.add_argument("--render-name", required=True)
    ap.add_argument("--resolution", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--detail", default="")
    ap.add_argument("--target-samples", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--watchdog-log", required=True)
    ap.add_argument("--start-ts", required=True)
    ap.add_argument("--attempt", required=True)
    ap.add_argument("--max-attempts", required=True)
    args = ap.parse_args()

    output = Path(args.output)
    tmp = output.with_suffix(output.suffix + ".tmp")
    tmp.write_text(render_html(args), encoding="utf-8")
    tmp.replace(output)


if __name__ == "__main__":
    main()

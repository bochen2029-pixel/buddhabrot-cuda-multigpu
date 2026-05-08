"""Read fields from a buddhabrot .bin file's HistHeader.

Header layout (must match main.cu's HistHeader struct, 128 bytes):
  offset 0:   magic           4 bytes  "BHRA"
  offset 4:   version         uint32
  offset 8:   width           uint32
  offset 12:  height          uint32
  offset 16:  reserved0       uint32
  offset 20:  reserved_pad0   uint32
  offset 24:  hist_count      uint64
  offset 32:  samples_done    uint64
  offset 40:  base_seed_used  uint64
  offset 48:  view_center_x   double
  offset 56:  view_center_y   double
  offset 64:  zoom            double
  offset 72:  rotation_deg    double
  offset 80:  sample_center_x double
  offset 88:  sample_center_y double
  offset 96:  sample_radius   double
  offset 104: iter_r          uint32
  offset 108: iter_g          uint32
  offset 112: iter_b          uint32
  offset 116: hist_scale      uint32
  offset 120: imap_used       uint32
  offset 124: imap_marker     4 bytes

Usage:
    python read_bin_header.py PATH                # dump all fields
    python read_bin_header.py PATH samples_done   # print one field
    python read_bin_header.py PATH json           # JSON dump
"""
import struct
import sys
import json
from pathlib import Path

LAYOUT = [
    ("magic",          0,   "4s"),
    ("version",        4,   "<I"),
    ("width",          8,   "<I"),
    ("height",         12,  "<I"),
    ("reserved0",      16,  "<I"),
    ("reserved_pad0",  20,  "<I"),
    ("hist_count",     24,  "<Q"),
    ("samples_done",   32,  "<Q"),
    ("base_seed_used", 40,  "<Q"),
    ("view_center_x",  48,  "<d"),
    ("view_center_y",  56,  "<d"),
    ("zoom",           64,  "<d"),
    ("rotation_deg",   72,  "<d"),
    ("sample_center_x", 80, "<d"),
    ("sample_center_y", 88, "<d"),
    ("sample_radius",  96,  "<d"),
    ("iter_r",         104, "<I"),
    ("iter_g",         108, "<I"),
    ("iter_b",         112, "<I"),
    ("hist_scale",     116, "<I"),
    ("imap_used",      120, "<I"),
    ("imap_marker",    124, "4s"),
]


def read_header(path: Path) -> dict:
    with open(path, "rb") as f:
        header = f.read(128)
    if len(header) < 128:
        raise ValueError(f"file too short: {len(header)} bytes (expected >= 128)")
    out = {}
    for name, offset, fmt in LAYOUT:
        size = struct.calcsize(fmt)
        value = struct.unpack(fmt, header[offset:offset + size])[0]
        if isinstance(value, bytes):
            value = value.rstrip(b"\x00").decode("ascii", errors="replace")
        out[name] = value
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"file not found: {path}", file=sys.stderr)
        sys.exit(1)
    try:
        hdr = read_header(path)
    except Exception as e:
        print(f"error reading header: {e}", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) >= 3:
        field = sys.argv[2]
        if field == "json":
            print(json.dumps(hdr, indent=2))
        elif field in hdr:
            print(hdr[field])
        else:
            print(f"unknown field '{field}'. Available: {', '.join(hdr.keys())}", file=sys.stderr)
            sys.exit(1)
    else:
        for name, _, _ in LAYOUT:
            print(f"{name:20s} = {hdr[name]}")


if __name__ == "__main__":
    main()

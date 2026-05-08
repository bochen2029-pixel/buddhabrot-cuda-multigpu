"""
Post-process color trim — equivalent to re-running the CUDA tonemap with per-channel
"trim" multipliers. Operates entirely in 16-bit space, preserving HDR-grade dynamic
range.

Math:
  rendered output = 1 - (1 - t)^gamma         where t = count / max(channel_max, normFloor)
  trimmed output  = 1 - (1 - t/trim)^gamma    (i.e. inflate channel max by `trim`)

So we round-trip via the inverse gamma to recover t, divide by trim, then re-apply gamma.
"""
import argparse
import numpy as np
import cv2


def main():
    p = argparse.ArgumentParser()
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--trim-r", type=float, default=1.0)
    p.add_argument("--trim-g", type=float, default=1.0)
    p.add_argument("--trim-b", type=float, default=1.0)
    p.add_argument("--gamma", type=float, default=4.0)
    p.add_argument("--show-stats", action="store_true")
    args = p.parse_args()

    # cv2 returns BGR uint16
    bgr = cv2.imread(args.input, cv2.IMREAD_UNCHANGED)
    if bgr is None:
        raise SystemExit(f"failed to read {args.input}")
    if bgr.dtype != np.uint16:
        raise SystemExit(f"expected uint16 input, got {bgr.dtype}")
    print(f"loaded {args.input}: {bgr.shape} {bgr.dtype}")

    # Swap BGR -> RGB
    rgb = bgr[..., ::-1].astype(np.float32) / 65535.0

    # De-gamma to recover original t = count / channel_max
    t = 1.0 - np.power(1.0 - rgb, 1.0 / args.gamma)

    # Apply trim (inflating channel max == dividing t)
    trims = np.array([args.trim_r, args.trim_g, args.trim_b], dtype=np.float32)
    t = t / trims[None, None, :]

    # Re-gamma
    out = 1.0 - np.power(1.0 - np.clip(t, 0.0, 1.0), args.gamma)

    # Quantize back to uint16, swap RGB -> BGR for cv2 write
    out_u16 = np.clip(np.round(out * 65535.0), 0, 65535).astype(np.uint16)
    bgr_out = out_u16[..., ::-1]

    cv2.imwrite(args.output, bgr_out)
    print(f"wrote {args.output}: {out_u16.shape} {out_u16.dtype}")

    if args.show_stats:
        for c, name in enumerate("RGB"):
            channel = out_u16[..., c]
            print(f"  {name}: min={channel.min()} max={channel.max()} "
                  f"mean={channel.mean():.0f} p50={int(np.percentile(channel, 50))} "
                  f"p99={int(np.percentile(channel, 99))}")


if __name__ == "__main__":
    main()

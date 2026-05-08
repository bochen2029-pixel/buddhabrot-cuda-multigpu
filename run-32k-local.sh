#!/bin/bash
# 32K local render shim. Delegates to run-local.sh with RESOLUTION=32K.
# Note: 32K won't fit in the 4070 Ti SUPER's 16 GB VRAM (needs ~15 GB hist + 5 GB
# output + working = >20 GB). Useful only on cards with ≥24 GB. For local use on
# 16 GB hardware, prefer ./run-local.sh (defaults to 16K).
#
# All env vars from run-local.sh are forwarded:
#   SAMPLES, MODE, IMAP, SAMPLES_PER_THREAD, LAUNCHES_PER_ROUND,
#   CP_INTERMEDIATE, WALLCLOCK_HARD_CAP, RESUME_MODE, OUT, FRESH

cd "$(dirname "$0")"
exec env RESOLUTION=32K ./run-local.sh "$@"

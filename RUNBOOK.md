# RUNBOOK — Cloud Buddhabrot render (1× / 8× H100/H200)

**Audience:** human operator (Bo), or any AI assistant the human is collaborating with. This document is self-contained — read top to bottom or jump to a phase.

**Last revision:** 2026-05-08. Original target was Hyperbolic.xyz 8× H200; pivoted to RunPod after first attempt. Provider recommendations and lessons learned section at the bottom of this document supersede earlier provider-specific instructions.

> **⚠️ Read first: [Lessons from first cloud attempt](#lessons-from-first-cloud-attempt) at the bottom.** It documents what went wrong and which provider tier to use. The phase-by-phase walkthrough below assumed Hyperbolic; for RunPod or Lambda use the bootstrap one-liner identically but follow the provider-specific notes in the lessons section.

---

## TLDR / BLUF (read this first, ~60 seconds)

**Goal:** Produce a 32K (32768×24576) Buddhabrot PNG + raw histogram .bin from 2 trillion importance-sampled trajectories on 8× Hopper-class GPUs in ~80 minutes wallclock, hard-capped at 90 minutes.

**Total cost:** $0 if free credit holds (1h46m × $29.83/hr = $52.66 credit, run consumes ~$45). Out-of-pocket ceiling: $50.

**One-line answer:** SSH into Hyperbolic instance, paste this, walk away:

```bash
curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash && \
cd ~/buddhabrot-cuda-multigpu && \
export HF_TOKEN=<YOUR_HF_TOKEN> && \
./run-cloud-hyperbolic.sh
```

The `?ts=$(date +%s)` defeats Fastly's 5-min per-edge cache on GitHub Raw (K0 lesson §2.7).

**End state:** Final `buddhabrot_cloud_32k_2T.png` (~3.4 GB) + `.bin` (~19.3 GB) + 3 intermediate checkpoint pairs uploaded to your HuggingFace bucket `bochen2079/buddhabrot`.

**The critical safety net:** every checkpoint .bin auto-syncs to HuggingFace as it's written. If the cloud instance vanishes mid-run, you don't lose the work.

---

## Pre-flight checklist (5 minutes)

Have these ready BEFORE provisioning the GPU instance (clock starts when GPUs are allocated, $29.83/hr is burning):

- [ ] **Hyperbolic.xyz account** with payment method on file (or free credit). Login: https://app.hyperbolic.ai/
- [ ] **HuggingFace account** with a write-scoped access token. Get it from: https://huggingface.co/settings/tokens
- [ ] **HuggingFace bucket created** at `<your-username>/buddhabrot` (or pick another name; record it).
  - Create at: https://huggingface.co/new-bucket  (or however HF surfaces bucket creation in their UI)
- [ ] **SSH key pair** ready. The pair you use must be added to your Hyperbolic profile BEFORE provisioning.
  - On Windows: use existing key from `%USERPROFILE%\.ssh\id_ed25519` or generate new with `ssh-keygen -t ed25519`
  - Public key (`.pub`) goes to Hyperbolic's SSH-keys settings
  - Private key stays on your laptop, used by MobaXterm
- [ ] **MobaXterm installed** on your Windows 11 machine. Download free version: https://mobaxterm.mobatek.net/download.html
  - Pick "Home Edition", then "Portable Edition" or "Installer Edition" — either works
- [ ] **GitHub repo accessible:** https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu (public, no auth needed for clone)
- [ ] **~30 GB free disk on laptop** for downloading the final .bin + .png from HF bucket
- [ ] **Stable internet** — render is ~80 min, you'll want to monitor it; SSH session can drop and rejoin without losing the render (it's running under nohup-style background via the watchdog)

If any line is unchecked, fix that BEFORE proceeding to Phase 1. The most common screw-up is "I'll set up the SSH key after I provision" — Hyperbolic doesn't let you bake an SSH key into a running instance retroactively without rebooting.

---

## Phase 1 — Local prep on your Windows 11 machine (~10 min)

### 1.1 Install MobaXterm

1. Browse to https://mobaxterm.mobatek.net/download-home-edition.html
2. Download "MobaXterm Home Edition v25.x" (whichever is current). The "Installer Edition" lands as `.msi`; "Portable Edition" as a `.zip`. Either works.
3. **Installer Edition:** double-click the `.msi`, accept defaults, finish. Launch from Start menu.
4. **Portable Edition:** unzip to e.g. `C:\Tools\MobaXterm\`, double-click `MobaXterm_Personal_25.x.exe`. No install needed.
5. First launch: it'll ask about updates and X server. Defaults are fine.

### 1.2 Save your SSH private key

You should have your ed25519 private key. If you generated it via `ssh-keygen -t ed25519` in PowerShell, it's at `%USERPROFILE%\.ssh\id_ed25519`. If you have the key as a text blob:

1. Open Notepad (or Notepad++)
2. Paste the entire text including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines
3. Save As: `C:\Users\<you>\.ssh\id_ed25519` (no extension)
4. **Important:** in Save As dialog, set "Save as type" to "All Files" so Notepad doesn't append `.txt`
5. **File permissions:** PowerShell as admin, run:
   ```powershell
   icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "$env:USERNAME:F"
   ```
   This restricts the key file to just you. SSH will refuse to use a key with overly permissive perms.

### 1.3 Verify the key works locally

In MobaXterm's "Local terminal" tab (top-right `Local`):
```bash
ssh-keygen -y -f ~/.ssh/id_ed25519
```

This should print the public-key string starting with `ssh-ed25519 AAAA...`. If it asks for a passphrase, enter it. If your key is unencrypted, no prompt.

If the command errors with "bad permissions" or "no such file," fix step 1.2 first.

### 1.4 Upload public key to Hyperbolic

1. Browse to https://app.hyperbolic.ai/account/settings (or your Hyperbolic settings page; UI may have shifted)
2. Find "SSH Keys" section
3. Paste your **public key** (the `.pub` content, single line starting with `ssh-ed25519 AAAA...`)
4. Save
5. If you don't have the `.pub`, regenerate with:
   ```bash
   ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub
   ```

---

## Phase 2 — Provision Hyperbolic GPU instance (~5 min)

### 2.1 Browse and select GPU

1. Go to https://app.hyperbolic.ai/compute (or whatever the "GPUs" / "Marketplace" page is called)
2. Filter by **8× H200 SXM5** preferred, or **8× H100 SXM5** as fallback
3. Sort by price (cheapest first) — they're typically all $3.73/GPU/hr but availability varies by region
4. Pick the cheapest available 8-GPU node with NVLink ("NVLink" or "SXM" listing typically implies NVLink fabric)
5. **Confirm:**
   - GPU count: 8 (not 4, not 16 — the script expects exactly 8 by default)
   - Storage: ≥100 GB (for the .bin files; 8 TB onboard is fine and the typical default)
   - Region doesn't matter for a one-shot batch render

### 2.2 Click "Rent" / "Deploy" / "Launch"

1. Configure deployment:
   - **Image:** "CUDA 12.x" or "Ubuntu 22.04 + CUDA" — whatever ML/AI image they offer with CUDA preinstalled. AVOID "blank Ubuntu" — you'll waste 10 min installing CUDA.
   - **Storage:** keep default (typically 100-500 GB scratch) unless you want extra
   - **SSH key:** select the one you uploaded in Phase 1.4
   - **Confirm pricing** displayed matches expectation ($29.83/hr for 8× H200)
2. Click "Deploy" / "Start"
3. Wait 1-3 min for instance to provision and become reachable

### 2.3 Capture instance details

After provisioning, the dashboard shows:
- **Public IP:** something like `73.232.158.121`
- **SSH port:** typically 22, sometimes a non-standard port like 30001
- **Username:** typically `ubuntu` or `root` — read the dashboard

**Write these down:**
```
HYPERBOLIC_IP=___.___.___.___
HYPERBOLIC_PORT=22  (or whatever)
HYPERBOLIC_USER=ubuntu  (or whatever)
```

---

## Phase 3 — SSH connect via MobaXterm (~3 min)

### 3.1 Create a new SSH session

1. In MobaXterm, click **Session** button (top-left, big icon)
2. In the popup, click **SSH** (top-left tab)
3. Fill in:
   - **Remote host:** the IP from 2.3
   - **Specify username:** check the box, enter `ubuntu` (or whatever Hyperbolic gave you)
   - **Port:** 22 (or whatever Hyperbolic gave you)
4. Click **Advanced SSH settings** tab (in the same popup)
5. Check **Use private key** and browse to `C:\Users\<you>\.ssh\id_ed25519`
6. Click **OK**

The session opens in a new tab. Accept the host key fingerprint (one-time prompt).

If your private key has a passphrase, enter it now.

### 3.2 Verify connection

You should see a shell prompt like:
```
ubuntu@hyperbolic-instance-XXX:~$
```

Run a few sanity checks:
```bash
nvidia-smi --query-gpu=name --format=csv,noheader | head -5
nvcc --version
df -h ~ | tail -1
free -h | head -2
```

Expected output:
- `nvidia-smi` lists 8× H200 SXM5 (or H100). If only 1-7 GPUs shown, you got the wrong instance — destroy and retry.
- `nvcc` shows CUDA 12.x release.
- `df -h ~` shows ≥100 GB available.
- `free -h` shows ≥200 GB RAM.

If `nvcc: command not found`:
```bash
export PATH=/usr/local/cuda/bin:$PATH
nvcc --version
```
If still not found, the image doesn't have CUDA preinstalled. Either install it (`sudo apt-get install -y cuda-toolkit-12-4`) or destroy and pick a CUDA-bundled image.

### 3.3 Verify SSH session is robust

If your laptop sleeps or wifi drops mid-render, the SSH session dies but the watchdog keeps the render going. Test this works:

```bash
nohup sleep 600 > /tmp/test.out 2>&1 &
echo "Background PID: $!"
disown
exit
```

Reconnect via MobaXterm, then:
```bash
pgrep -af sleep
```
You should see your sleep PID still running. If yes, nohup is working — your render will survive disconnects. If not, switch to `tmux` or `screen`.

For maximum safety, run the launch under `screen`:
```bash
screen -S buddha
# inside screen:
./run-cloud-hyperbolic.sh
# detach with Ctrl-A, D
# reattach later with: screen -r buddha
```

---

## Phase 4 — Bootstrap & build (~3 min)

### 4.1 Run the one-shot bootstrap

```bash
curl -sSL "https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh?ts=$(date +%s)" | bash
```

(Cache-bust query parameter forces Fastly origin fetch; see K0 lesson §2.7.)

This script:
1. Verifies CUDA toolkit (errors if missing)
2. Detects GPUs via `nvidia-smi`
3. Clones the repo to `~/buddhabrot-cuda-multigpu`
4. Installs `huggingface_hub` Python package via pip
5. Logs into HuggingFace if `HF_TOKEN` env is set or `~/.hf_token` file exists
6. Runs `./build.sh` to compile `buddhabrot` for sm_80/86/89/90 (Ampere/Ada/Hopper)
7. Runs `./build_imap.sh` to construct `imap.bin` (idempotent — skipped if 4 MB file already exists)

**Expected output:** ~7 sections of `[N/7]` progress, ending with:
```
Bootstrap complete.
To launch the production render:
  cd /home/ubuntu/buddhabrot-cuda-multigpu
  export HF_TOKEN=<your_token>            # optional, for background sync
  ./run-cloud-hyperbolic.sh
```

If bootstrap halts:
- **Missing CUDA:** see Phase 3.2 fallback
- **`git clone` fails:** check network connectivity (`curl https://github.com`)
- **Compile errors:** the C++ source changed and broke; report issue, fall back to local 16K render
- **IMap build fails:** rare; can be skipped (run-cloud script will rebuild on launch)

### 4.2 Set HF_TOKEN env

```bash
cd ~/buddhabrot-cuda-multigpu
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # YOUR token
```

Verify:
```bash
hf auth whoami    # OR: huggingface-cli whoami
```
Should print your HuggingFace username. If "Not logged in," set token via:
```bash
hf auth login --token "$HF_TOKEN"
```

### 4.3 Verify HF bucket access

```bash
hf upload --help 2>&1 | head -5      # check the CLI works
```

Then dry-run a tiny upload:
```bash
echo "buddhabrot test $(date -u)" > /tmp/test.txt
hf upload --repo-type bucket bochen2079/buddhabrot /tmp/test.txt test.txt
```

If it succeeds, your HF bucket is reachable and writable. Check https://huggingface.co/datasets/bochen2079/buddhabrot (or wherever the bucket UI lives) for the test file.

If it fails:
- 401 Unauthorized: regenerate the HF token with **write** scope
- 404 Not Found: bucket name wrong, or doesn't exist; create it via HF web UI
- Network error: instance has no outbound HTTPS — unusual; reconfigure firewall in Hyperbolic dashboard

---

## Phase 5 — Launch the render (~80 min)

### 5.1 Launch

In your Hyperbolic SSH session (ideally inside `screen` or `tmux`):

```bash
cd ~/buddhabrot-cuda-multigpu
./run-cloud-hyperbolic.sh
```

### 5.2 What you should see in the first 30 seconds

The script prints a sequence of pre-flight checks:

```
[gpu] detected 8 GPU(s):
     1  NVIDIA H200 SXM5 80GB        # or H100 SXM5
     2  NVIDIA H200 SXM5 80GB
     ...
[gpu] tier: H200
[gpu] per-GPU throughput estimate: 50 M/s
[gpu] aggregate (8x at 0.96 efficiency): 384 M/s
[gpu] projected compute time: 5208s
[gpu] projected total wallclock (with saves): 6208s
WARN: projected wallclock 6208s exceeds hard cap 5400s.
WARN: SIGUSR1 will trigger early-stop with partial samples.

[p2p] checking NVLink topology
[p2p] NVLink detected

[imap] using existing: 4.0M

[audit] resolution        : 32768x24576 (805306368 pixels)
[audit] target samples    : 2000000000000
[audit] traj/pixel        : 2484
[audit] reference density : 5120 (16K_blue.png uniform)
[audit] pct of reference  : 48%

[hf] sync enabled, bucket: bochen2079/buddhabrot

[launch] ...
[watchdog HH:MM:SS] launching: ./buddhabrot ...
[watchdog HH:MM:SS] render PID: 12345
```

If you see "SIGUSR1 will trigger early-stop," that's expected — the planning estimate is conservative. Actual throughput will likely be higher; SIGUSR1 trigger is the safety mechanism, not a problem.

### 5.3 Verify the render is making progress

After ~1 minute, check `tail` of the stderr log:

```bash
tail -f buddhabrot_cloud_32k_2T.stderr.log
```

You want to see lines like:
```
  round    1 / 466  (  0.2%)  samples 4294967296  elapsed     8.5s  ETA  ....s  rate 504.8 M/s
  round    2 / 466  ...
```

The **rate (M/s)** is your live throughput. Multiply by 3,800 sec compute budget = projected total samples:
- 350 M/s → 1.33 T (likely SIGUSR1 will fire before 2T)
- 500 M/s → 1.90 T (close to target)
- 700 M/s → 2.66 T (will hit 2T early; render finishes naturally well under 80 min)

Press Ctrl-C to stop tailing (does NOT stop the render — it's in another process).

### 5.4 Watch for first checkpoint (~20 min)

Around 20 min in, the first checkpoint fires:
```
  round  117 / 466  (25.1%)  ...
  checkpoint at round 117 ...
  -> buddhabrot_cloud_32k_2T.cp0117.png  (3.4 GB raw, samples_done=...)
  -> buddhabrot_cloud_32k_2T.cp0117.bin  (19.3 GB raw, samples_done=...)
  checkpoint took 245.3s
[watchdog ...]   HF sync buddhabrot_cloud_32k_2T.cp0117.bin -> hf://buckets/bochen2079/buddhabrot (background)
```

When the HF sync line prints, the .bin is being uploaded to HuggingFace in the background. Even if the cloud instance dies right now, that .bin survives.

**Verify HF bucket received the upload:**
1. On your laptop browser, navigate to https://huggingface.co/buckets/bochen2079/buddhabrot (or wherever HF surfaces bucket contents)
2. You should see `buddhabrot_cloud_32k_2T.cp0117.bin` listed with size ~19.3 GB

If you don't see it after 10 min, HF sync is failing. Check:
```bash
cat buddhabrot_cloud_32k_2T.cp0117.bin.hfsync.log
```

Common issues:
- "Authentication required": HF_TOKEN expired/wrong scope
- Network timeout: HF API throttling, retry should happen automatically
- Disk space: full local disk preventing read

### 5.5 Three more checkpoints + final

Checkpoints fire at rounds 117, 234, 351 (and final round 466). Each is ~250 sec of save overhead.

Total expected output:
- 4× cp.{png,bin} pairs (cp0117, cp0234, cp0351 — note: round number depends on actual n_rounds at runtime)
- 1× final .png + .bin (different basename, no .cpNNNN suffix)
- 1× stderr.log
- 1× watchdog.log
- 1× launch.log

### 5.6 Watch the watchdog timeline

Run `date -u` periodically. The watchdog timer references absolute wallclock from launch:

| Wallclock from launch | Event |
|---|---|
| T+0 | Render starts |
| T+1,200s (20 min) | Checkpoint 1 fires |
| T+2,400s (40 min) | Checkpoint 2 fires |
| T+3,600s (60 min) | Checkpoint 3 fires |
| T+4,800s (80 min) | TARGET — final save fires (if throughput holds) |
| **T+5,100s (85 min)** | **SIGUSR1 fires — render breaks at next round boundary, runs final save, exits 0** |
| T+5,400s (90 min) | Hard SIGTERM — render killed if still running |
| T+5,460s (90 min + 60s) | SIGKILL — last resort |

### 5.7 At completion

Look for these markers:
```
Final save...
Final save took 245.0s
[watchdog HH:MM:SS] render exited code=0 after 4762s
[watchdog HH:MM:SS] HF sync waiting up to 600s for background jobs to finish...
[watchdog HH:MM:SS] HF sync wait done
[watchdog HH:MM:SS] DONE (exit 0)
```

A `.DONE` flag file appears: `buddhabrot_cloud_32k_2T.DONE`

If you see `.FATAL` instead, the render crashed mid-flight — but you still have whatever checkpoints uploaded to HF.

---

## Phase 6 — Retrieve the results (~5-30 min)

### 6.1 Confirm everything synced

In your Hyperbolic SSH session:
```bash
ls -lh buddhabrot_cloud_32k_2T.{png,bin}
ls -lh buddhabrot_cloud_32k_2T.cp*.{png,bin} 2>/dev/null
ls -lh *.hfsync.log
```

Tail every `.hfsync.log` to confirm uploads succeeded:
```bash
for f in *.hfsync.log; do echo "=== $f"; tail -3 "$f"; done
```

Look for "Upload complete" or similar success indicator. If any failed, retry manually:
```bash
hf upload --repo-type bucket bochen2079/buddhabrot \
    buddhabrot_cloud_32k_2T.bin buddhabrot_cloud_32k_2T.bin
```

### 6.2 Download from HF bucket to your laptop

Open MobaXterm "Local terminal" (NOT the Hyperbolic SSH tab):

```bash
cd /c/buddhabrot-main/cuda-render-16k    # or wherever you want it
mkdir -p cloud-render
cd cloud-render

# Install hf CLI on Windows:
# Option A: PowerShell one-liner from HF docs
#   powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"
# Option B: pip
pip install -U huggingface_hub

# Login on Windows (separate from cloud session)
hf auth login --token <YOUR_HF_TOKEN>

# Download the final outputs
hf download --repo-type bucket bochen2079/buddhabrot \
    buddhabrot_cloud_32k_2T.bin --local-dir .
hf download --repo-type bucket bochen2079/buddhabrot \
    buddhabrot_cloud_32k_2T.png --local-dir .
```

The .bin is 19.3 GB. At 100 Mbps home internet that's ~25 min. At 1 Gbps, ~3 min. HF often serves with multi-stream so realistic is somewhere in between.

### 6.3 Verify the .bin

On your laptop:
```bash
cd /c/buddhabrot-main/cuda-render-16k
python tools/read_bin_header.py cloud-render/buddhabrot_cloud_32k_2T.bin samples_done
```

Expected output: a number close to 2000000000000 (or less if SIGUSR1 fired early). If it says "magic mismatch," the file is corrupt — retry the download.

---

## Phase 7 — Local retune & post-process (~30 min)

### 7.1 Retune trims against reference

The .bin is your raw histogram. The PNG that came with it used predicted trims (1.00/0.74/0.42). If they're slightly off, retune locally.

```bash
cd /c/buddhabrot-main/cuda-render-16k
python tools/retune_trims.py \
    --bin cloud-render/buddhabrot_cloud_32k_2T.bin \
    --reference-stats reference_calibration.json \
    --output cloud-render/buddhabrot_cloud_32k_2T_retoned.png
```

This iterates ~5-15 times (each iteration is ~3 min PNG encode at 32K on the 4070 Ti SUPER). Total ~15-45 min.

Output: `buddhabrot_cloud_32k_2T_retoned.png` — your final image with reference-matched percentiles.

### 7.2 Optional NLM denoise + CLAHE post-process

```bash
python postprocess.py \
    --input cloud-render/buddhabrot_cloud_32k_2T_retoned.png \
    --output cloud-render/buddhabrot_cloud_32k_2T_final.png
```

### 7.3 Archive the .bin

The .bin is the irreplaceable artifact. PNG can be regenerated from .bin in seconds. Keep the .bin somewhere durable:
- HuggingFace bucket (already there)
- Local SSD/NAS
- USB stick / external drive

Write SHA256:
```bash
sha256sum cloud-render/buddhabrot_cloud_32k_2T.bin > cloud-render/buddhabrot_cloud_32k_2T.bin.sha256
```

### 7.4 Destroy the Hyperbolic instance

Once everything is downloaded and verified, terminate the cloud instance to stop billing.

1. Go to Hyperbolic dashboard
2. Find your active instance
3. Click "Terminate" / "Destroy" / "Stop"
4. Confirm

**Verify billing stopped:** check your account balance/credit. If still consuming credit, the instance didn't fully terminate.

---

## Troubleshooting (organized by symptom)

### "I can't SSH into the instance"

1. **Wrong IP or port?** Check Hyperbolic dashboard
2. **Firewall blocking?** Some networks block outbound SSH on non-standard ports
3. **Public key not registered?** Verify in Hyperbolic SSH-keys settings; if you added it AFTER provisioning, you need to reboot the instance for cloud-init to pick it up
4. **Permissions on private key:**
   ```powershell
   icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "$env:USERNAME:F"
   ```
5. **Try with verbose:**
   ```bash
   ssh -vvv -i ~/.ssh/id_ed25519 ubuntu@<ip>
   ```
   Read the output for clues.

### "nvcc: command not found"

CUDA toolkit not installed. Either:
1. Pick a different image when provisioning (look for "CUDA" in image name)
2. Install manually: `sudo apt-get update && sudo apt-get install -y cuda-toolkit-12-4`
3. Source if installed but not in PATH: `export PATH=/usr/local/cuda/bin:$PATH`

### "Build fails with weird errors"

```bash
cd ~/buddhabrot-cuda-multigpu
./build.sh 2>&1 | tee build.log
# read build.log for the actual error
```

Common causes:
- **C++17 unsupported:** ancient gcc; `apt-get install -y g++-11` and retry
- **lodepng missing:** `git pull` to get latest, retry
- **Architecture mismatch:** modify `ARCH_FLAGS` in `build.sh` to drop unsupported targets

### "Render starts but rate is way below 350 M/s"

Likely causes (in priority order):
1. **Atomic contention at 32K:** expected, the kernel is HBM-atomic-bound. Below 200 M/s is concerning; below 100 M/s is broken.
2. **Wrong GPU type detected:** check first-line `[gpu]` output. If A100 detected, throughput estimate auto-drops to 18 M/s/GPU.
3. **NVLink not active:** check the `[p2p]` warning. Multi-GPU efficiency falls to 0.5-0.6 over PCIe, but render still works.
4. **Insufficient samples_per_thread:** 32 is the default; if your launches are very short and overhead dominates, try `SAMPLES_PER_THREAD=64 ./run-cloud-hyperbolic.sh`

If rate is truly broken (<50 M/s aggregate on 8× H200), abort and retry — you may have gotten a degraded instance.

### "Checkpoint never appeared"

Default cadence: every 117 rounds. With launches_per_round=16 and per-launch ~0.7 sec on H200, that's ~22 min between checkpoints. If you've been running 30+ min with no cp, something is stuck.

```bash
ps aux | grep buddhabrot
nvidia-smi
```

If GPUs idle and process running, kernel is hung. Kill and restart:
```bash
pkill -9 buddhabrot
./run-cloud-hyperbolic.sh
```

If GPUs busy (100% util), patient — 32K saves take 250+ sec each, may just be slow.

### "HF sync log shows 'unauthorized'"

Token expired or has wrong scope. Regenerate at https://huggingface.co/settings/tokens with **write** scope, then:
```bash
export HF_TOKEN=<new_token>
hf auth login --token "$HF_TOKEN"
```

The watchdog will retry sync on next checkpoint.

### "Watchdog killed render at 90 min before final save"

The SIGUSR1 path didn't take. Causes:
- **Kernel ignoring signal:** main.cu must be the post-2026-05-08 build with SIGUSR1 handler. Verify by `grep -A5 buddhabrot_sigusr1_handler src/main.cu` showing the handler.
- **Round too long:** if a single round takes >300s, SIGUSR1 fires before round boundary check. Reduce `LAUNCHES_PER_ROUND` (default 16) to 8 or 4.

Even if SIGTERM hit, the latest checkpoint .bin is in HF bucket. You can resume from it on a fresh instance.

### "Instance disappeared / preempted"

Hyperbolic's contract may include preemption (read your subscription terms). If the instance is gone:
1. The latest cp.bin is in HF bucket — no work lost
2. Provision a new instance (SSH key already set up)
3. Run bootstrap, then resume:
   ```bash
   cd ~/buddhabrot-cuda-multigpu
   hf download --repo-type bucket bochen2079/buddhabrot \
       buddhabrot_cloud_32k_2T.cp0XXX.bin --local-dir .
   mv buddhabrot_cloud_32k_2T.cp0XXX.bin buddhabrot_cloud_32k_2T.bin
   export HF_TOKEN=<token>
   ./run-cloud-hyperbolic.sh
   ```
   The watchdog auto-detects existing .bin and resumes (additive, bit-exact).

### "I want to abort the run early"

```bash
# Send SIGUSR1 manually to trigger graceful save
kill -USR1 $(cat buddhabrot_cloud_32k_2T.pid)

# Wait 30-60 sec for round to finish + save to write
# Verify done
test -f buddhabrot_cloud_32k_2T.DONE && echo "graceful exit OK"
```

If hung, escalate: `kill -TERM` then `kill -KILL`.

---

## Recovery scenarios

### "Claude is down — can I do this without AI?"

Yes. This document is self-contained. Follow Phase 1 → Phase 7 sequentially. No AI assistance required.

### "I want a different AI to help me"

Paste this entire document into your other AI and add:
> I'm on Windows 11, using MobaXterm, doing a Buddhabrot CUDA render on Hyperbolic.xyz. Help me follow this runbook. I'm currently at Phase X.

The other AI can read the document and orient. All commands are explicit; all expected outputs are documented.

### "The cloud instance got OOM-killed"

Unlikely at 32K (each device uses ~21 GB out of 80-141 GB), but possible if other workloads share the instance. If `dmesg | grep -i oom` shows OOM kills:
1. The render process exits with SIGKILL — `.FATAL` flag set
2. Latest cp.bin is in HF bucket
3. Provision a fresh dedicated instance, resume per the "Instance disappeared" recipe

### "I lost the SSH key"

If you can't SSH back in, you can't recover work in flight on the instance. **However:**
- Checkpoint .bins are in HF bucket — pre-final work is safe
- New instance + fresh key + bootstrap + resume gets you going again
- The cost: SSH key loss = whatever progress is between last sync'd checkpoint and now (typically <22 min of compute)

### "My laptop crashed during the render"

Doesn't matter. The render is on the cloud instance, watchdog'd. Just SSH back in:
```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<ip>
cd ~/buddhabrot-cuda-multigpu
ls -lh *.{stderr.log,DONE,FATAL,bin,png}
tail -50 buddhabrot_cloud_32k_2T.stderr.log
```

---

## Reference appendix

### A. All file paths on the cloud instance

```
~/buddhabrot-cuda-multigpu/                       # repo root after bootstrap
├── src/main.cu                                   # CUDA renderer source
├── src/lodepng.{h,cpp}                           # PNG library
├── build.sh                                      # Linux build script
├── build_imap.sh                                 # IMap builder (idempotent)
├── run-cloud-hyperbolic.sh                       # main launcher
├── _supervise-cloud.sh                           # watchdog
├── bootstrap-hyperbolic.sh                       # one-shot first launch
├── imap.bin                                      # 4 MB canonical IMap
├── tools/
│   ├── preflight_audit.py
│   ├── read_bin_header.py
│   ├── retune_trims.py
│   └── write_status_html.py
├── reference_calibration.json                    # reference percentiles
├── CLOUD.md                                      # full math runbook
├── RUNBOOK.md                                    # this document
└── README.md                                     # repo overview

# After render:
├── buddhabrot_cloud_32k_2T.png                   # final image (~3.4 GB)
├── buddhabrot_cloud_32k_2T.bin                   # final histogram (~19.3 GB)
├── buddhabrot_cloud_32k_2T.cp0117.{png,bin}     # checkpoint 1
├── buddhabrot_cloud_32k_2T.cp0234.{png,bin}     # checkpoint 2
├── buddhabrot_cloud_32k_2T.cp0351.{png,bin}     # checkpoint 3
├── buddhabrot_cloud_32k_2T.stderr.log
├── buddhabrot_cloud_32k_2T.watchdog.log
├── buddhabrot_cloud_32k_2T.launch.log
├── buddhabrot_cloud_32k_2T.DONE                  # success flag
└── buddhabrot_cloud_32k_2T.cp*.bin.hfsync.log   # HF sync logs
```

### B. All environment variables

| Variable | Default | Notes |
|---|---|---|
| `HF_TOKEN` | (unset) | If set, enables background HF sync. Get from huggingface.co/settings/tokens with **write** scope. |
| `HF_BUCKET` | bochen2079/buddhabrot | Override if your bucket has different name |
| `HF_SYNC_ENABLED` | 1 | Set to 0 to disable HF sync entirely |
| `WIDTH` | 32768 | Image width |
| `HEIGHT` | 24576 | Image height |
| `TARGET_SAMPLES` | 2000000000000 | 2 T |
| `N_DEVICES` | 8 | Number of GPUs to use |
| `LAUNCHES_PER_ROUND` | 16 | Rounds = total launches / this |
| `SAMPLES_PER_THREAD` | 32 | Linux only, no TDR concern |
| `CHECKPOINT_EVERY` | 117 | Rounds between checkpoints |
| `TRIM_R` | 1.00 | Predicted from cross-density scaling |
| `TRIM_G` | 0.74 | |
| `TRIM_B` | 0.42 | |
| `WALLCLOCK_HARD_CAP` | 5400 | 90 min in seconds |
| `SIGUSR1_LEAD` | 300 | 5 min before hard cap |
| `OUTPUT_BASE` | buddhabrot_cloud_32k_2T | Filename prefix |
| `IMAP_PATH` | imap.bin | IMap file location |
| `VIEW_CX` / `VIEW_CY` / `ZOOM` / `ROTATION_DEG` / `SAMPLE_RADIUS` | canonical | DO NOT change without rebuilding IMap |
| `ITER_R` / `ITER_G` / `ITER_B` | 2000 / 200 / 20 | DO NOT change |

### C. All ./buddhabrot binary flags (used by run-cloud-hyperbolic.sh)

```
--width 32768
--height 24576
--samples 2000000000000
--devices 8
--imap imap.bin
--iter-r 2000 --iter-g 200 --iter-b 20
--view-center-x -0.5935417456742
--view-center-y 0.04166264380232
--zoom 0.5
--rotation-deg 90
--sample-radius 2.5
--trim-r 1.00 --trim-g 0.74 --trim-b 0.42
--samples-per-thread 32
--launches-per-round 16
--checkpoint-every 117
--output buddhabrot_cloud_32k_2T.png
[--resume-from <bin>]                   # if .bin exists
```

For `--help` output, run `./buddhabrot --help` after build.

### D. Math derivation summary

**Wallclock budget (80 min target / 90 min hard cap):**
```
WALLCLOCK_TARGET     = 4,800 sec
WALLCLOCK_HARD_CAP   = 5,400 sec
SAVE_OVERHEAD        = 4 saves × 250 sec = 1,000 sec
COMPUTE_TIME_BUDGET  = 3,800 sec
TARGET_SAMPLES       = 3,800 × 350M ≈ 1.5T (planning, conservative)
                     = 3,800 × 550M ≈ 2.0T (optimistic, default)
```

**Per-pixel density (B13 mandatory check):**
```
pixel_count   = 32768 × 24576 = 805,306,368
density_2T    = 2.0T / 805M = 2,484 traj/pixel
density_ref   = 1024B / 200M = 5,120 traj/pixel    (16K_blue.png reference)
ratio         = 0.485 of reference
ε_body × ratio = 1.5 × 0.485 = 0.728  (effective body density vs ref)
ε_filament × ratio = 50 × 0.485 = 24×  (filaments crush ref)
```

**Trim prediction (cross-density invariance count_p50/R_max ∝ N^0.388):**
```
N_ratio (target / trial)              = 2.0T / 2.1B = 952
factor (count_p50/R_max scaling)      = 952^0.388 = 14.3
count_p50/R_max at 32K @ 2T (R/G)     = 0.00220 × 14.3 = 0.0315
count_p50/R_max at 32K @ 2T (B)       = 0.00207 × 14.3 = 0.0296
t_target_R (D_ref=29)                  = 1 - (1-29/255)^0.25 = 0.0294
t_target_G (D_ref=41)                  = 1 - (1-41/255)^0.25 = 0.0427
t_target_B (D_ref=65)                  = 1 - (1-65/255)^0.25 = 0.0707
trim_R                                = 0.0315 / 0.0294 = 1.07 → clamp 1.00
trim_G                                = 0.0315 / 0.0427 = 0.738
trim_B                                = 0.0296 / 0.0707 = 0.419
```

### E. Cost calculations

```
hourly_rate    = $3.73 / GPU-hr × 8 = $29.83 / hr
free_credit    = 1h 46m × $29.83    = $52.66
target_run     = 80 min × $29.83    = $39.78
hard_cap       = 90 min × $29.83    = $44.75
overhead       = 10 min × $29.83    = $4.97
worst_case     = 100 min × $29.83   = $49.72
```

If you go beyond free credit, ceiling is $50. Above that, **abort and re-plan** — something went wrong.

### F. Glossary

- **IS** — Importance Sampling (Bitterli's scheme using a precomputed importance map)
- **IMap** — the importance map (1024×1024 uint32 + header, ~4 MB), constructed in advance from a uniform pre-pass that accumulates orbit-length per cell
- **Vose alias method** — O(1) GPU sampling from a discrete distribution (the IMap)
- **HIST_SCALE** — integer-precision factor (1000) for histogram weights; uniform mode uses HIST_SCALE; IS mode uses round(HIST_SCALE / p(c))
- **Trim** — per-channel multiplier applied to the per-channel max during tonemap; smaller trim = brighter image
- **R_max** — the maximum count across all pixels in a channel (the brightest pixel's count); divisor in the tonemap normalization
- **Checkpoint / cp** — periodic save during render; produces `.cpNNNN.png` + `.cpNNNN.bin`
- **TDR** — Windows Timeout Detection and Recovery (2-sec kernel-launch limit). Linux has no equivalent; cloud render uses larger samples_per_thread
- **NVLink** — NVIDIA's high-bandwidth GPU-to-GPU interconnect (900 GB/s on H200/H100). Required for fast multi-GPU merge; PCIe-only fallback adds ~4 sec per checkpoint
- **HBM** — High-Bandwidth Memory (the GPU's main memory; H200 has 4.8 TB/s)
- **§B7 / §B11 / §B13** — references to CLAUDE.md sections (project contract; see repo)
- **SIGUSR1** — POSIX signal used as graceful-terminate trigger from the watchdog

### G. URLs you'll need

| Purpose | URL |
|---|---|
| Hyperbolic dashboard | https://app.hyperbolic.ai/ |
| Hyperbolic GPU marketplace | https://app.hyperbolic.ai/compute |
| Hyperbolic SSH keys settings | https://app.hyperbolic.ai/account/settings |
| HuggingFace tokens | https://huggingface.co/settings/tokens |
| HuggingFace your bucket | https://huggingface.co/buckets/bochen2079/buddhabrot |
| MobaXterm download | https://mobaxterm.mobatek.net/download-home-edition.html |
| Repo (this codebase) | https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu |
| Repo bootstrap script (curl direct) | https://raw.githubusercontent.com/bochen2029-pixel/buddhabrot-cuda-multigpu/master/bootstrap-hyperbolic.sh |
| HF Hub Python docs | https://huggingface.co/docs/huggingface_hub/index |
| HF CLI docs | https://huggingface.co/docs/huggingface_hub/guides/cli |

### H. Commands you'll run a lot (cheat sheet)

```bash
# On Windows local terminal:
ssh -i ~/.ssh/id_ed25519 ubuntu@<ip>          # SSH into instance

# On Hyperbolic instance:
nvidia-smi                                     # check GPU state
nvidia-smi topo -m                             # check NVLink topology
df -h ~                                        # check disk space
free -h                                        # check RAM
tail -f buddhabrot_cloud_32k_2T.stderr.log    # tail render log
ls -lh buddhabrot_cloud_32k_2T*               # list outputs
ps aux | grep buddhabrot                       # check render process
pgrep -af buddhabrot                          # PID + cmdline of render
kill -USR1 $(cat buddhabrot_cloud_32k_2T.pid) # trigger graceful save
hf upload --repo-type bucket bochen2079/buddhabrot <file> <name>  # manual sync
hf download --repo-type bucket bochen2079/buddhabrot <name> --local-dir .  # pull from HF

# Recovery / resume:
mv buddhabrot_cloud_32k_2T.cp0XXX.bin buddhabrot_cloud_32k_2T.bin
./run-cloud-hyperbolic.sh    # auto-detects .bin and resumes
```

---

## Final words

**The render is the goal. The .bin is the artifact. The PNG is derivative.**

If anything goes wrong but you have the .bin, you can:
- Re-tonemap with different trims in 3 min
- Convert to EXR for graphics-pipeline use
- Resume from this point on a fresh instance
- Archive forever and regenerate any size PNG later

If you have the PNG but lost the .bin, you have a frozen image you cannot improve.

**Therefore: when in doubt, save the .bin first. The HF bucket sync is doing this for you automatically. Trust it, but verify by checking the bucket UI mid-render.**

---

## Lessons from first cloud attempt

**Date of attempt:** 2026-05-08. Pod: RunPod Community Cloud 1× H100 80GB HBM3 at $2.99/hr. Outcome: render functioned but throughput was 12.1 M/s vs expected 40-60 M/s (3-5× slower). Diagnosed as shared-tenancy HBM bandwidth contention. **Switch providers next time.**

### Provider selection — the big lesson

| Provider tier | Verdict | Reason |
|---|---|---|
| **RunPod Secure Cloud** | ✅ recommended | Dedicated tenancy, full bandwidth, ~$2.49-3.99/hr |
| **Lambda Labs** | ✅ recommended | Dedicated, simple SSH UX, $2.49/hr H100 PCIe |
| **Vast.ai** (datacenter listings) | ✅ acceptable | Cheaper, dedicated nodes available, marketplace UX |
| RunPod Community Cloud | ❌ avoid | Shared HBM bandwidth, throttled at 12 M/s on H100 |
| Hyperbolic.xyz | ❌ avoid | Single-key SSH UX makes provisioning painful |

### How to detect a throttled/shared GPU

The smoking gun: **power draw vs cap with 100% util**. Run on the pod immediately after launching the render:
```bash
nvidia-smi --query-gpu=power.draw,power.limit,utilization.gpu --format=csv,noheader
```

Expected for H100 doing real work: 600-700W of 700W cap (90-100% of power).
If you see <30% of power cap with 100% util → the SMs are stalled on HBM atomics → shared-tenant bandwidth contention. **No kernel parameter fixes this. Switch pods.**

Observed in the failed attempt: `100%, 6303 MiB, 146.43 W, 30°C` → 21% of cap → confirmed throttled.

### HF bucket sync — the working syntax

The `hf upload --repo-type bucket` command in the original watchdog **does not work** (HF CLI restricts repo-type to `model`/`dataset`/`space`). Buckets must be addressed via the URL form:

```bash
hf sync . hf://buckets/<user>/<bucket>/ --include "*.bin" --include "*.png" --include "*.log"
```

Verified working 2026-05-08. Fixed in commit [`088fefb`](https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu/commit/088fefb). Pre-fix watchdogs need `git pull` before relaunching.

**Auth:** must run loudly, never with `2>/dev/null`:
```bash
hf auth login --token "$HF_TOKEN"
hf auth whoami       # MUST print username, not "Not logged in"
```

### Settings that don't help atomic-bound throughput

Reject any advice to bump `SAMPLES_PER_THREAD` above 32 to fix throughput. The Buddhabrot IS kernel at 16K is HBM-atomic-bound, not launch-overhead-bound:
- Per-launch wallclock at 12 M/s with `samples_per_thread=32`: 2.79 sec
- CUDA kernel launch overhead: 50 μs
- Overhead fraction: 0.002% of launch time

Increasing samples_per_thread to 1024 makes launches 32× longer for zero throughput gain and worse progress visibility. The bottleneck is HBM atomic contention, fixed only by:
1. Different memory architecture (per-block private histograms, tiled merge) — kernel rewrite
2. Different hardware (better HBM atomic throughput)
3. **Dedicated tenancy** (the immediate practical answer)

### RunPod-specific notes

- **Web Terminal** (browser) is full bash shell — equivalent to SSH for our purposes. Use this and skip SSH key drama entirely.
- **Pod template:** `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04` — has nvcc preinstalled. Critical: the **`-devel`** suffix. Runtime-only images won't compile.
- **SSH key registration:** https://www.runpod.io/console/user/settings → SSH public keys. Multiple keys allowed (newline-separated). Auto-injects to all newly-deployed pods.
- **Filter Secure Cloud at deploy time** — Community is the cheap shared tier; Secure is dedicated. The price difference ($2.99 vs $3.49) buys 3-5× actual throughput.

### Bootstrap script bugs (now fixed)

These hit on the first attempt; fixed in commits below the original release:

- [`6f9360a`](https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu/commit/6f9360a) — bootstrap was trying to `cd cuda-render-16k/` (subdirectory doesn't exist; renderer files are at repo root).
- [`603e67a`](https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu/commit/603e67a) — `--target-[rgb]` banned-pattern guard self-detected its own regex literal.
- [`088fefb`](https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu/commit/088fefb) — HF watchdog used `hf upload --repo-type bucket` (broken syntax).

Always `git pull` before relaunch on a long-running pod to pick up fixes.

### Configuration tested working on dedicated H100

For the next attempt on RunPod Secure Cloud or Lambda Labs:

```bash
export HF_TOKEN=<your_token>
export WIDTH=16384
export HEIGHT=12288
export TARGET_SAMPLES=400000000000   # 400B IS at 16K
export N_DEVICES=1
export TRIM_R=0.57
export TRIM_G=0.39
export TRIM_B=0.22
export LAUNCHES_PER_ROUND=32         # NOT 4 — keep small launches for progress visibility
export SAMPLES_PER_THREAD=32         # NOT 1024 — bigger doesn't help atomic-bound kernel
export CHECKPOINT_EVERY=47
export WALLCLOCK_HARD_CAP=7200
export SIGUSR1_LEAD=300
export OUTPUT_BASE=buddhabrot_cloud_16k_400B
./run-cloud-hyperbolic.sh
```

Predicted trims at 16K @ 400B IS, derived from `count_p50/R_max ∝ N^0.388`:
- `trim_R = 0.57` (from 0.00220 × 7.65 / 0.0294)
- `trim_G = 0.39`
- `trim_B = 0.22`

Expected wallclock at dedicated 50 M/s: ~2h. SIGUSR1 fires at T-300s if under-budget; .bin saves regardless.

---

## Final words

**The render is the goal. The .bin is the artifact. The PNG is derivative.**

If anything goes wrong but you have the .bin, you can:
- Re-tonemap with different trims in 3 min
- Convert to EXR for graphics-pipeline use
- Resume from this point on a fresh instance
- Archive forever and regenerate any size PNG later

If you have the PNG but lost the .bin, you have a frozen image you cannot improve.

**Therefore: when in doubt, save the .bin first. The HF bucket sync is doing this for you automatically. Trust it, but verify by checking the bucket UI mid-render.**

---

*This runbook is part of the [buddhabrot-cuda-multigpu](https://github.com/bochen2029-pixel/buddhabrot-cuda-multigpu) repository. Updates land at the master branch. To pull the latest version on a running instance: `cd ~/buddhabrot-cuda-multigpu && git pull`.*

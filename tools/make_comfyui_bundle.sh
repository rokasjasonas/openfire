#!/usr/bin/env bash
# Build the ComfyUI bundle .zip that the game auto-downloads + extracts on first launch
# (see ComfyUI.ensure_installed / _bundled_launcher). The zip contains ComfyUI's source plus
# cross-platform launchers (start.sh for Linux/macOS, start.bat for Windows). PyTorch is not
# baked in — it can't be built cross-platform from one machine — so each launcher installs it
# on FIRST run (needs python3/py + pip + internet; a GPU build of torch for speed).
#
# Output:  build/comfyui-bundle.zip   → host it and set Settings.comfyui_bundle_url to its URL.
#
# For a zero-dependency Windows build (embedded Python, no first-run pip), repackage the
# official ComfyUI Windows *portable* as .zip on a Windows box instead — Godot needs .zip, not
# the portable's .7z.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
OUT="$ROOT/build/comfyui-bundle.zip"
mkdir -p "$ROOT/build"
trap 'rm -rf "$WORK"' EXIT

echo "[bundle] cloning ComfyUI…"
git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$WORK/ComfyUI"
rm -rf "$WORK/ComfyUI/.git"

# --- text→3D custom nodes (any-GPU) -----------------------------------------
# The game's workflow_model.json drives TripoSR (lean standalone ComfyUI-Flowty-TripoSR node) for
# cross-vendor geometry plus an Inspyrenet rembg node for the foreground mask. Both are torch-only
# (no CUDA-compiled kernels), so text→3D runs on any GPU with zero user setup. (SF3D was dropped:
# its texture baker is CUDA/NVIDIA-only via slangtorch. The heavy ComfyUI-3D-Pack was dropped for
# the lean Flowty node to avoid its CUDA-only sibling deps breaking import on non-NVIDIA GPUs.)
mkdir -p "$WORK/ComfyUI/custom_nodes"
FLOWTY_REPO="${FLOWTY_REPO:-https://github.com/flowtyone/ComfyUI-Flowty-TripoSR.git}"
REMBG_REPO="${REMBG_REPO:-https://github.com/john-mnz/ComfyUI-Inspyrenet-Rembg.git}"
for entry in "TripoSR|$FLOWTY_REPO" "InspyrenetRembg|$REMBG_REPO"; do
	name="${entry%%|*}"; repo="${entry#*|}"
	echo "[bundle] cloning $name ($repo)…"
	if git clone --depth 1 "$repo" "$WORK/ComfyUI/custom_nodes/$name" 2>/dev/null; then
		rm -rf "$WORK/ComfyUI/custom_nodes/$name/.git"
	else
		echo "[bundle] WARN: could not clone $name — text→3D may be unavailable until it's added." >&2
	fi
done

# Bundled workflow templates (copied to the bundle root; the game auto-discovers them).
echo "[bundle] adding workflow templates…"
cp "$ROOT/tools/comfyui/"workflow_*.json "$WORK/" 2>/dev/null || true

# --- Linux/macOS launcher ---------------------------------------------------
cat > "$WORK/start.sh" <<'SH'
#!/usr/bin/env bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
if [ ! -d venv ]; then
	echo "[comfyui] first run: creating venv + installing PyTorch/ComfyUI (large, one time)…"
	python3 -m venv venv
	./venv/bin/pip install --upgrade pip
	# Install the PyTorch build that matches the GPU so it runs on ANY vendor: CUDA for NVIDIA,
	# ROCm for AMD (Linux), else CPU/MPS (the default wheel is MPS-capable on macOS).
	if command -v nvidia-smi >/dev/null 2>&1; then
		./venv/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
	elif [ -e /dev/kfd ]; then
		./venv/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/rocm6.2
	else
		./venv/bin/pip install torch torchvision
	fi
	./venv/bin/pip install -r ComfyUI/requirements.txt
	# text→3D node deps (TripoSR + rembg) — torch-only, no compiled CUDA kernels.
	for req in ComfyUI/custom_nodes/*/requirements.txt; do
		[ -f "$req" ] && ./venv/bin/pip install -r "$req" || true
	done
fi
# TripoSR weights (ungated) into checkpoints so TripoSRModelLoader finds "triposr.ckpt".
CKPT="ComfyUI/models/checkpoints/triposr.ckpt"
if [ ! -f "$CKPT" ]; then
	echo "[comfyui] downloading TripoSR model (one time, ~1.6 GB)…"
	mkdir -p "$(dirname "$CKPT")"
	curl -fL -o "$CKPT" "https://huggingface.co/stabilityai/TripoSR/resolve/main/model.ckpt" \
		|| echo "[comfyui] WARN: TripoSR model download failed — 3D won't work until it's at $CKPT"
fi
exec ./venv/bin/python ComfyUI/main.py --listen 127.0.0.1 --port 8188 "$@"
SH
chmod +x "$WORK/start.sh"

# --- Windows launcher -------------------------------------------------------
cat > "$WORK/start.bat" <<'BAT'
@echo off
cd /d "%~dp0"
if not exist venv (
	echo [comfyui] first run: creating venv + installing PyTorch/ComfyUI ^(large, one time^)...
	py -3 -m venv venv || python -m venv venv
	venv\Scripts\python -m pip install --upgrade pip
	rem CUDA torch if an NVIDIA GPU is present, else CPU. (AMD on Windows needs torch-directml,
	rem which users can install manually.)
	where nvidia-smi >nul 2>nul && (
		venv\Scripts\pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
	) || (
		venv\Scripts\pip install torch torchvision
	)
	venv\Scripts\pip install -r ComfyUI\requirements.txt
	rem text->3D node deps (TripoSR + rembg) — torch-only, no compiled kernels.
	for /d %%d in (ComfyUI\custom_nodes\*) do (
		if exist "%%d\requirements.txt" venv\Scripts\pip install -r "%%d\requirements.txt"
	)
)
if not exist ComfyUI\models\checkpoints\triposr.ckpt (
	echo [comfyui] downloading TripoSR model ^(one time, ~1.6 GB^)...
	curl -fL -o ComfyUI\models\checkpoints\triposr.ckpt "https://huggingface.co/stabilityai/TripoSR/resolve/main/model.ckpt"
)
venv\Scripts\python ComfyUI\main.py --listen 127.0.0.1 --port 8188 %*
BAT

echo "[bundle] zipping…"
rm -f "$OUT"
( cd "$WORK" && zip -q -r "$OUT" . -x '*/.git/*' )
echo "[bundle] wrote $OUT ($(du -h "$OUT" | cut -f1))"

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

# --- Stable Fast 3D node (text→image→textured-3D stage) ---------------------
# The game's workflow_model.json drives an SF3D image→3D node. Ship the node pack so text→3D
# works with zero user setup. Override the repo with SF3D_NODE_REPO if a leaner fork is used.
SF3D_NODE_REPO="${SF3D_NODE_REPO:-https://github.com/MrForExample/ComfyUI-3D-Pack.git}"
echo "[bundle] cloning Stable Fast 3D node pack ($SF3D_NODE_REPO)…"
mkdir -p "$WORK/ComfyUI/custom_nodes"
if git clone --depth 1 "$SF3D_NODE_REPO" "$WORK/ComfyUI/custom_nodes/SF3D" 2>/dev/null; then
	rm -rf "$WORK/ComfyUI/custom_nodes/SF3D/.git"
else
	echo "[bundle] WARN: could not clone SF3D node pack — 3D will be unavailable until it's added." >&2
fi

# The SF3D model weights (stabilityai/stable-fast-3d) are license-gated on HuggingFace, so they
# can't be pulled anonymously at first run. Mirror them on the release (like the SD checkpoint)
# and let the first-run launcher fetch from $SF3D_MODEL_URL into models/. If unset, 3D still
# installs but the model must be dropped in manually.
SF3D_MODEL_URL="${SF3D_MODEL_URL:-}"

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
	# CPU torch by default; swap for the CUDA/ROCm build from pytorch.org for GPU speed.
	./venv/bin/pip install torch torchvision
	./venv/bin/pip install -r ComfyUI/requirements.txt
	# Stable Fast 3D node deps (for text→textured-3D). Best-effort: some SF3D packs need
	# compiled extensions that require a toolchain — a GPU build should ship prebuilt wheels.
	for req in ComfyUI/custom_nodes/*/requirements.txt; do
		[ -f "$req" ] && ./venv/bin/pip install -r "$req" || true
	done
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
	rem CPU torch by default; swap for the CUDA build from pytorch.org for GPU speed.
	venv\Scripts\pip install torch torchvision
	venv\Scripts\pip install -r ComfyUI\requirements.txt
	rem Stable Fast 3D node deps (text->textured-3D). Some SF3D packs need prebuilt wheels.
	for /d %%d in (ComfyUI\custom_nodes\*) do (
		if exist "%%d\requirements.txt" venv\Scripts\pip install -r "%%d\requirements.txt"
	)
)
venv\Scripts\python ComfyUI\main.py --listen 127.0.0.1 --port 8188 %*
BAT

echo "[bundle] zipping…"
rm -f "$OUT"
( cd "$WORK" && zip -q -r "$OUT" . -x '*/.git/*' )
echo "[bundle] wrote $OUT ($(du -h "$OUT" | cut -f1))"

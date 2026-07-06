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
# Uses `uv` to fetch a pinned Python 3.12 (self-contained — the host may have no Python, or an
# incompatible one like 3.14 which has no PyTorch wheels). Invoked via `bash start.sh` by the
# game, so the missing exec bit (Godot's ZIP extractor drops it) doesn't matter.
cat > "$WORK/start.sh" <<'SH'
#!/usr/bin/env bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
if [ ! -x ./uv ]; then
	echo "[comfyui] fetching uv…"
	case "$(uname -s)" in
		Darwin) UVF="uv-$(uname -m | sed 's/arm64/aarch64/')-apple-darwin.tar.gz" ;;
		*)      UVF="uv-$(uname -m)-unknown-linux-gnu.tar.gz" ;;
	esac
	curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/$UVF" -o uv.tgz
	tar xzf uv.tgz && mv uv-*/uv ./uv && rm -rf uv.tgz uv-*/
fi
PY=venv/bin/python
if [ ! -d venv ]; then
	echo "[comfyui] first run: Python 3.12 env + PyTorch/ComfyUI (large, one time)…"
	./uv venv --python 3.12 venv
	# Vendor-matched PyTorch so it runs on ANY GPU: CUDA (NVIDIA), ROCm (AMD/Linux), else CPU/MPS.
	if command -v nvidia-smi >/dev/null 2>&1; then IDX="https://download.pytorch.org/whl/cu124";
	elif [ -e /dev/kfd ]; then IDX="https://download.pytorch.org/whl/rocm6.2";
	else IDX=""; fi
	# Install torch + torchvision + torchaudio ALL from the vendor index — ComfyUI imports
	# torchaudio, and if it comes from the default PyPI it's the CUDA build (libcudart) and
	# crashes on AMD/CPU. Installing it here first stops the requirements step pulling CUDA.
	if [ -n "$IDX" ]; then ./uv pip install --python "$PY" torch torchvision torchaudio --index-url "$IDX";
	else ./uv pip install --python "$PY" torch torchvision torchaudio; fi
	./uv pip install --python "$PY" -r ComfyUI/requirements.txt
	for req in ComfyUI/custom_nodes/*/requirements.txt; do [ -f "$req" ] && ./uv pip install --python "$PY" -r "$req" || true; done
	# Override Flowty's broken pins (validated live on ROCm): transformers 4.35 lacks ComfyUI's
	# Qwen2Tokenizer; trimesh 4.0.5 calls numpy-2-removed ndarray.ptp().
	./uv pip install --python "$PY" "transformers==4.44.2" "trimesh>=4.5"
fi
exec "$PY" ComfyUI/main.py --listen 127.0.0.1 --port 8188 "$@"
SH
chmod +x "$WORK/start.sh"

# --- Windows launcher -------------------------------------------------------
cat > "$WORK/start.bat" <<'BAT'
@echo off
cd /d "%~dp0"
if not exist uv.exe (
	echo [comfyui] fetching uv...
	curl -fsSL https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip -o uv.zip
	powershell -Command "Expand-Archive -Force uv.zip ."
)
set PY=venv\Scripts\python.exe
if not exist venv (
	echo [comfyui] first run: Python 3.12 env + PyTorch/ComfyUI ^(large, one time^)...
	uv.exe venv --python 3.12 venv
	where nvidia-smi >nul 2>nul && (
		uv.exe pip install --python %PY% torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
	) || (
		uv.exe pip install --python %PY% torch torchvision torchaudio
	)
	uv.exe pip install --python %PY% -r ComfyUI\requirements.txt
	for /d %%d in (ComfyUI\custom_nodes\*) do (
		if exist "%%d\requirements.txt" uv.exe pip install --python %PY% -r "%%d\requirements.txt"
	)
	uv.exe pip install --python %PY% "transformers==4.44.2" "trimesh>=4.5"
)
%PY% ComfyUI\main.py --listen 127.0.0.1 --port 8188 %*
BAT

echo "[bundle] zipping…"
rm -f "$OUT"
( cd "$WORK" && zip -q -r "$OUT" . -x '*/.git/*' )
echo "[bundle] wrote $OUT ($(du -h "$OUT" | cut -f1))"

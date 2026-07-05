#!/usr/bin/env bash
# Bundled ComfyUI launcher for OpenFire.
#
# Ship this as  <game_dir>/comfyui/start.sh  — the game auto-runs it on startup (see
# ComfyUI._bundled_launcher). The FIRST run creates a Python venv and installs ComfyUI +
# PyTorch (a few GB, needs python3 + internet; a GPU build of torch for speed); later runs
# just start the server. The game passes --extra-model-paths-config so ComfyUI reads the
# model the game downloads into <game_dir>/comfyui/models/checkpoints/.
#
# This is the "embedded ComfyUI" path: from the player's side the game starts everything;
# the only thing the game itself can't do is bundle Python+PyTorch into its binary, so that
# one-time self-install lives here.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [ ! -d ComfyUI ]; then
	echo "[comfyui] first run: fetching ComfyUI…"
	git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git
fi

if [ ! -d venv ]; then
	echo "[comfyui] first run: creating venv + installing PyTorch/ComfyUI (this is large)…"
	python3 -m venv venv
	./venv/bin/pip install --upgrade pip
	# CPU PyTorch by default. For an NVIDIA GPU, replace with the matching CUDA build from
	# https://pytorch.org/get-started/locally/ for much faster generation.
	./venv/bin/pip install torch torchvision
	./venv/bin/pip install -r ComfyUI/requirements.txt
fi

exec ./venv/bin/python ComfyUI/main.py --listen 127.0.0.1 --port 8188 "$@"

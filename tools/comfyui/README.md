# Bundled ComfyUI workflows

These JSON files are copied into the ComfyUI bundle (`comfyui-bundle.zip`) at its root, next
to the bundled ComfyUI. The game auto-discovers them via `ComfyUI.workflow_template_path()`
(`scripts/autoload/comfyui.gd`) — no user setup. Placeholders `%PROMPT% %NEG% %SEED% %WIDTH%
%HEIGHT% %STEPS% %CKPT%` are substituted before each POST to `/prompt`.

## workflow_model.json — text → 3D (any GPU)

Two stages, chosen so it runs on **any GPU with enough VRAM, zero setup** (see the
`openfire-text-to-3d` design note):

1. **SD txt2img** (nodes `3–8`) turns the prompt into a single, centered, plain-background
   object image.
2. **Image → 3D** (nodes `12–15`): `InspyrenetRembg` makes the foreground mask, then the lean
   **ComfyUI-Flowty-TripoSR** node (`TripoSRModelLoader` → `TripoSRSampler` → `TripoSRViewer`)
   reconstructs a vertex-coloured mesh and saves it as a **`.obj`** (Y-up, vertex colours), which
   `TripoSRViewer` reports in `/history` under `mesh`. The game fetches that `.obj` and parses it
   into a mesh at runtime (`hud.gd::_mesh_from_obj` — Godot has no runtime OBJ importer).

**Why not SF3D?** Stable Fast 3D's texture baker is CUDA/NVIDIA-only (`import slangtorch` +
`raise ValueError("must be on cuda")`), so it can't run on AMD/Intel. TripoSR's mesh extraction
is PyMCubes (CPU, prebuilt wheels) and its transformer runs on any torch device — truly
cross-vendor. Texture is TripoSR's baked vertex colours (optionally enhanced by projecting the
SD image in-engine in Godot).

**Why the lean Flowty node** (not ComfyUI-3D-Pack)? 3D-Pack bundles many nodes, some with
CUDA-only deps that can break import on non-NVIDIA GPUs. Flowty is TripoSR-only, torch-only.

**Model:** `TripoSRModelLoader` reads `triposr.ckpt` from `models/checkpoints/`. It is **not**
auto-downloaded — the bundle launcher fetches it (ungated `stabilityai/TripoSR/model.ckpt`) on
first run. The build (`tools/make_comfyui_bundle.sh`) clones the Flowty + rembg nodes into
`custom_nodes/` and installs their requirements. Override by dropping a `workflow_model.json` in
the game's `comfyui/` folder or `user://comfyui/`.

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
2. **Image → 3D** (nodes `12–15`): an Inspyrenet rembg node (`InspyrenetRembg`) makes the
   foreground mask, then **TripoSR** (`[Comfy3D] Load TripoSR Model` + `[Comfy3D] TripoSR`)
   reconstructs a vertex-coloured mesh, saved as GLB by `[Comfy3D] Save 3D Mesh` to a **fixed
   filename** (`openfire3d.glb`) the game fetches from ComfyUI's output dir.

**Why not SF3D?** Stable Fast 3D's texture baker is CUDA/NVIDIA-only (`import slangtorch` +
`raise ValueError("must be on cuda")`), so it can't run on AMD/Intel. TripoSR's mesh extraction
is PyMCubes (CPU, prebuilt wheels) and its transformer runs on any torch device — truly
cross-vendor. Texture is TripoSR's baked vertex colours (optionally enhanced by projecting the
SD image in-engine in Godot).

**Node names:** ComfyUI-3D-Pack builds each API `class_type` as `"[Comfy3D] " +
ClassName.replace("_", " ")`. The graph here matches 3D-Pack's own
`example_workflows/TripoSR_to_Mesh.json`. TripoSR's model (`stabilityai/TripoSR`, ungated) is
auto-downloaded by its node on first run — nothing to bundle or configure.

The bundle build (`tools/make_comfyui_bundle.sh`) clones ComfyUI-3D-Pack + the rembg node into
`custom_nodes/` and installs their requirements on first launch. To override on your machine,
drop a `workflow_model.json` in the game's `comfyui/` folder or in `user://comfyui/`.

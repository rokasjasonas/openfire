# Bundled ComfyUI workflows

These JSON files are copied into the ComfyUI bundle (`comfyui-bundle.zip`) at its root, next
to the bundled ComfyUI. The game auto-discovers them via `ComfyUI.workflow_template_path()`
(`scripts/autoload/comfyui.gd`) — no user setup. Placeholders `%PROMPT% %NEG% %SEED% %WIDTH%
%HEIGHT% %STEPS% %CKPT%` are substituted before each POST to `/prompt`.

## workflow_model.json — text → textured 3D (two-stage)

Nodes `3–8` are the standard SD txt2img graph (identical to the game's built-in image
workflow): the player's text prompt becomes a single-object image. Nodes `20–22` are the
image→3D stage: **Stable Fast 3D** turns that image into a UV-textured mesh, saved as a GLB
the game loads via `GLTFDocument` and spawns.

⚠️ **The `20–22` node `class_type`s must match the Stable Fast 3D ComfyUI node pack that the
bundle installs** (see `tools/make_comfyui_bundle.sh`). Node class names differ between packs
(ComfyUI-3D-Pack vs. standalone SF3D nodes) and versions. The correct way to (re)generate this
file is to build the graph once in the ComfyUI web UI against the *installed* SF3D nodes, then
export it via **Save (API Format)** and re-apply the placeholders. The names here
(`StableFast3DLoader` / `StableFast3DPreview` / `SaveGLB`) are the expected shape and are
pinned/validated when the bundle is built on a GPU machine.

To override on your own machine, drop a corrected `workflow_model.json` in the game's
`comfyui/` folder (next to the binary) or in `user://comfyui/` — the user path wins.

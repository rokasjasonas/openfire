# ComfyUI asset bridge

OpenFire uses a local **ComfyUI** server to pre-bake **themed props** (textures / billboard
sprites, and GLB models with a 3D workflow). ComfyUI ships **alongside the game binary** and
is always on — there is no enable toggle, and the checkpoints folder is derived from the
game's own location (`<game_dir>/comfyui/models/checkpoints/`, or `user://comfyui/…` in the
editor). The AI **model** auto-downloads there from the Options menu.

## Why it's a *bridge*, not embedded

ComfyUI is a Python + PyTorch + GPU stack (several GB, needs a real GPU). Unlike the tiny
in-process text model, it can't run inside the game. Instead the game talks to a **local
ComfyUI server over HTTP** (like the LM Studio story fallback) and can **launch** it for you
so it feels built-in. Generation is slow (seconds–minutes per asset, GPU-gated), so assets
are **pre-baked once** into `user://generated/` and reused — never generated mid-match. When
disabled/unreachable, the game falls back to its procedural (primitive) objects.

## Setup

1. Install ComfyUI and a checkpoint model (e.g. an SDXL `.safetensors`) on a machine with a
   GPU. Confirm it runs at `http://127.0.0.1:8188`.
2. In OpenFire → **Options → AI assets (ComfyUI)**:
   - **Endpoint** — default `http://127.0.0.1:8188`
   - **Download the AI model** — fetches a Stable Diffusion 1.5 checkpoint into the bundled
     `comfyui/models/checkpoints/` folder (next to the game) and selects it. (Restart ComfyUI
     once if it doesn't list the new file — it caches the folder on start.) On an HTTP 400 the
     bridge also auto-detects any already-installed checkpoint and retries.
   - Point ComfyUI itself at that same bundled `comfyui/models/` folder so it finds the model.
4. (Optional, "embedded" launch) In `settings.cfg` set `[comfyui] exec` to a launch script
   and `args`; the game will start ComfyUI via `OS.create_process` when baking.
5. Click **Bake sample asset library**. Watch ComfyUI process the queue; results land in
   `user://generated/*.png`.

## Custom / 3D workflows

The default is a text→image graph. To use your own graph (including a **3D**
ComfyUI-3D-Pack workflow that outputs GLB), drop a ComfyUI **API-format** JSON at:

- `user://comfyui/workflow_image.json`
- `user://comfyui/workflow_model.json`  (for `kind = "model"`, GLB output)

Use these placeholders; the bridge substitutes them per asset:
`%PROMPT%` `%NEG%` `%SEED%` `%WIDTH%` `%HEIGHT%` `%STEPS%` `%CKPT%`

The bridge reads the produced file from `/history` (`images`, `gltf`, `3d`, or `meshes`
outputs) and downloads it via `/view` into the cache. `.glb` files are loaded by the world
with `GLTFDocument`; images become textures via `ComfyUI.asset_texture(key)`.

## API (scripts/autoload/comfyui.gd)

- `enabled()`, `endpoint()`
- `ensure_server()` → `server_checked(ok)`
- `bake(prompt, key, kind="image")` → `asset_ready(key, path)` / `asset_failed(key)`
- `bake_library(specs)` → `bake_progress(done,total)`, `bake_finished()`
- `has_asset(key)`, `cache_path(key, ext)`, `asset_texture(key)`
- `sample_library()` — starter themed prompts

## Status

The bridge (HTTP client, workflow templating, caching, managed launch, Options UI) is built
and unit-tested for everything that doesn't need a live server. The live generation path
must be verified against a real ComfyUI install — it was authored without one available.
Placing baked assets into the world by theme is a **separate follow-up** (the procedural
object-placement track); today baking populates the cache and `asset_texture(key)` can load
them, but worlds don't yet auto-consume them.

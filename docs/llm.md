# AI story & NPC generation (Survival)

Survival's story (briefing, faction lore, NPC greetings, victory line) and the NPC
names/personas are generated from the **Story theme** you enter before the match.

It tries three backends, in order:

1. **Embedded llama.cpp (in-process)** — runs a local GGUF model inside the game.
2. **Local HTTP server** — an OpenAI-compatible endpoint (e.g. LM Studio / Ollama).
3. **Offline fallback** — a deterministic, themed story with the procedural name
   pools. Always available, so the game never blocks on AI.

## 1. Embedded model (recommended)

Runs entirely inside the app — no server to start.

1. Install the **NobodyWho** GDExtension (it wraps llama.cpp and ships precompiled
   binaries for Windows / macOS / Linux). In the Godot editor: *AssetLib → search
   "NobodyWho" → Download → Install*, then re-open the project. This adds the
   `NobodyWhoModel` / `NobodyWhoChat` classes the game looks for.
2. Start a **Survival** match. On first run the game downloads the GGUF model into
   `user://models/` (a loading screen shows "Downloading AI model… NN%"). It's
   downloaded once and reused after that.

The model defaults to a small instruct model (`Qwen2.5-1.5B-Instruct-Q4_K_M`,
~1 GB). To change it, edit `user://settings.cfg`:

```ini
[ai]
model_url="https://huggingface.co/.../your-model-Q4_K_M.gguf"
model_file="your-model-Q4_K_M.gguf"
```

If the NobodyWho addon isn't installed, the embedded path is skipped (no download)
and the game uses backend 2 or 3.

## 2. Local HTTP server (LM Studio / Ollama)

Run a local server exposing the OpenAI chat API, then set the endpoint/model in the
in-game **Options** screen (defaults to LM Studio: `http://localhost:1234/...`).

## 3. Offline

If neither of the above is available, the themed offline generator is used.

## user:// location

`user://` resolves to the per-user app data dir
(`~/.local/share/godot/app_userdata/OpenFire/` on Linux, the equivalent on
Windows/macOS), so the downloaded model and settings persist between runs.

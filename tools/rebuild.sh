#!/usr/bin/env bash
# Bump the game's patch version (project.godot config/version) and re-export the
# Linux / Windows / macOS executables. Invoked automatically by the Stop hook in
# .claude/settings.json after every turn, and runnable by hand.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

GODOT=".tools/godot"
if [ ! -x "$GODOT" ]; then
	echo "rebuild: $GODOT not found — skipping build"
	exit 0
fi

# Bump the patch component of config/version="MAJOR.MINOR.PATCH".
NEW=$(python3 - <<'PY'
import re
p = "project.godot"
s = open(p).read()
m = re.search(r'config/version="(\d+)\.(\d+)\.(\d+)"', s)
if not m:
	print("")
else:
	major, minor, patch = (int(x) for x in m.groups())
	new = f"{major}.{minor}.{patch + 1}"
	s = s[:m.start()] + f'config/version="{new}"' + s[m.end():]
	open(p, "w").write(s)
	print(new)
PY
)
if [ -z "$NEW" ]; then
	echo "rebuild: no config/version found in project.godot — skipping"
	exit 0
fi

"$GODOT" --headless --import --path . >/dev/null 2>&1
mkdir -p build
"$GODOT" --headless --path . --export-release "Linux"   build/openfire.x86_64 >/dev/null 2>&1
"$GODOT" --headless --path . --export-release "Windows" build/openfire.exe     >/dev/null 2>&1
"$GODOT" --headless --path . --export-release "macOS"   build/openfire.zip     >/dev/null 2>&1
echo "rebuild: built OpenFire v$NEW (linux/windows/macos)"

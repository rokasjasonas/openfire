#!/usr/bin/env python3
"""Bump project.godot's config/version and print the new version.

Usage: bump_version.py [patch|minor|major]   (default: patch)

Shared by the release CI workflow. The Stop-hook rebuild.sh bumps the patch
component inline; this script adds minor/major bumps and is the single source of
truth for the version string format.
"""
import re
import sys

KIND = sys.argv[1] if len(sys.argv) > 1 else "patch"
PATH = "project.godot"

src = open(PATH).read()
m = re.search(r'config/version="(\d+)\.(\d+)\.(\d+)"', src)
if not m:
    sys.exit("bump_version: no config/version in project.godot")

major, minor, patch = (int(x) for x in m.groups())
if KIND == "major":
    major, minor, patch = major + 1, 0, 0
elif KIND == "minor":
    minor, patch = minor + 1, 0
elif KIND == "patch":
    patch += 1
else:
    sys.exit(f"bump_version: unknown bump kind {KIND!r} (use patch|minor|major)")

new = f"{major}.{minor}.{patch}"
src = src[: m.start()] + f'config/version="{new}"' + src[m.end():]
open(PATH, "w").write(src)
print(new)

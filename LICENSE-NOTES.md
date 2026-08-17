# LICENSE notes (ffmpeg-lgpl-builds)

## What we redistribute

Each Release attaches:

1. A Windows shared FFmpeg build (DLLs + MSVC import libs + headers)
2. The corresponding FFmpeg source tarball for the same tag

Both are on the same public GitHub Release. That is intentional for LGPL.

## FFmpeg license for this build

LGPL version 2.1 or later.

The binary zip includes `LICENSE.txt` copied from FFmpeg `COPYING.LGPLv2.1`.

## What we do not claim

- This repo does not re-license FFmpeg.
- wonder_flow application code remains under its own license; linking is dynamic (DLL).

## Source offer

- Tag tree: https://github.com/FFmpeg/FFmpeg/tree/n8.1.2
- Tarball (also attached to the Release): n8.1.2.tar.gz
- Upstream URL: https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz
- Exact configure line: see `ORIGIN.txt` inside the binary zip (generic `--prefix=<prefix>`)

## Build scripts

`scripts/build-ffmpeg-8.1-lgpl.ps1` documents MSVC in-tree requirements and does not enable GPL / version3 / nonfree.
# LICENSE notes (ffmpeg-lgpl-builds)

## What we redistribute

Each Release attaches:

1. A Windows shared FFmpeg build (DLLs + MSVC import libs + headers + the `ffmpeg` /
   `ffprobe` command-line tools)
2. The corresponding FFmpeg source tarball for the same tag
3. The corresponding Snappy source tarball
4. The corresponding zlib source tarball

All four are on the same public GitHub Release. That is intentional for LGPL.

**Why three source tarballs.** Snappy and zlib are permissive and carry no source
obligation of their own, but they are linked **statically into `avcodec`**. They are
therefore part of that DLL's *corresponding source*, and the FFmpeg tarball alone
would not satisfy LGPL for the binary we publish.

## FFmpeg license for this build

LGPL version 2.1 or later.

The binary zip includes `LICENSE.txt` copied from FFmpeg `COPYING.LGPLv2.1`.

The `ffmpeg` and `ffprobe` programs are covered by the same licence in this build:
`--enable-gpl` is absent, so they are LGPL v2.1+ rather than GPL, and the FFmpeg
tarball above is their corresponding source too.

## External libraries

| Library | Version | License | Linked |
|---------|---------|---------|--------|
| Snappy | 1.2.2 | BSD-3-Clause | statically into `avcodec` |
| zlib | 1.3.1 | Zlib | statically into `avcodec` |

Both licences are permissive and compatible with LGPL v2.1. Redistributing the
binary requires keeping their copyright notices; consumers bundle those notices
next to their own (loopeek ships `COPYING.snappy` and the zlib notice with the app).

Nothing else is linked: the build passes `--pkg-config=false` so configure cannot
autodetect a library from the MSYS2 environment that happens to be on PATH.

## What we do not claim

- This repo does not re-license FFmpeg, Snappy or zlib.
- Consumer application code remains under its own license; the FFmpeg linkage is
  dynamic (DLL), so a compatible build can be substituted without rebuilding the
  application.

## Source offer

FFmpeg:

- Tag tree: https://github.com/FFmpeg/FFmpeg/tree/n8.1.2
- Tarball (attached to the Release): n8.1.2.tar.gz
- Upstream URL: https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz

Snappy:

- Tarball (attached to the Release): snappy-1.2.2.tar.gz
- Upstream URL: https://github.com/google/snappy/archive/refs/tags/1.2.2.tar.gz

zlib:

- Tarball (attached to the Release): zlib-1.3.1.tar.gz
- Upstream URL: https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz

Exact configure line: see `ORIGIN.txt` inside the binary zip (generic
`--prefix=<prefix>` and `<deps>`). `ORIGIN.txt` also records the Snappy and zlib
versions and their upstream URLs.

## Build scripts

`scripts/build-ffmpeg-8.1-lgpl.ps1` builds Snappy, zlib and FFmpeg, documents the
MSVC in-tree requirements, and does not enable GPL / version3 / nonfree. It fails
the build if any of those flags reappear, if the expected encoders are missing, or
if the resulting DLL is not self-contained.

LGPL v2.1 section 6 asks for the scripts used to control compilation and
installation of the library. That is this directory, in this public repository,
covering all three components.
# ffmpeg-lgpl-builds

Public LGPL **v2.1+** Windows shared builds of FFmpeg, shared by
**wonder_flow**, **loopeek** and **kinocore** (#321).

All three link the same binary. That is the point: kinocore is compiled against
whatever FFmpeg its consumer supplies, so two separately produced builds mean
"works in kinocore, breaks in the app" is possible without anything recording
which one a given test ran under.

This repository hosts:

- **Build scripts** (reproduce the MSVC shared build)
- **GitHub Release assets**: prebuilt `win64` zip **and** the corresponding source
  for everything linked into it

Binaries and corresponding source are published on the **same Release page** so LGPL's
offer of corresponding source from the same public place is satisfied.

## License

FFmpeg itself is LGPL v2.1 or later for this build.

- No `--enable-gpl`
- No `--enable-version3` (that would make the build LGPL **v3**)
- No `--enable-nonfree`

Two external libraries are linked, both **statically into `avcodec`**:

| Library | Version | License |
|---------|---------|---------|
| [Snappy](https://github.com/google/snappy) | 1.2.2 | BSD-3-Clause |
| [zlib](https://github.com/madler/zlib) | 1.3.1 | Zlib |

Snappy provides the HAP encoder and zlib the PNG / EXR encoders, which loopeek
needs. Because they are compiled into the LGPL DLL, their source belongs to that
DLL's corresponding source and is attached to the same Release.

See `LICENSE-NOTES.md` and the `LICENSE.txt` inside each binary zip (FFmpeg `COPYING.LGPLv2.1`).

## Configure (recorded / reproducible form)

Actual builds use a real `--prefix=...` path on the builder machine.
Published `ORIGIN.txt` / `config.h` record the **generic** form:

```
./configure --toolchain=msvc --prefix=<prefix> --pkg-config=false --enable-shared --disable-static --disable-doc --disable-debug --disable-ffplay --enable-libsnappy --enable-zlib --extra-cflags=-I<deps>/include --extra-ldflags=-libpath:<deps>/lib
```

The line is not written here by hand. `build-ffmpeg-8.1-lgpl.ps1` records it in
`ORIGIN.txt` and the packaging script reads it back, so the published record cannot
drift from the flags actually used. The real `--prefix` and the external-library
prefix are replaced with `<prefix>` and `<deps>`.

## Reproduce (Windows)

1. Visual Studio Build Tools 2022 (MSVC + VsDevShell, including the
   *C++ CMake tools for Windows* component -- Snappy and zlib are built with CMake)
2. MSYS2 with `make`, `diffutils`; nasm on mingw64 PATH
3. From a checkout of **this** repo. The scripts here are the originals; wonder_flow
   keeps a copy of the build script for reference, but packaging happens here:

```powershell
pwsh -NoProfile -File scripts/build-ffmpeg-8.1-lgpl.ps1
pwsh -NoProfile -File scripts/package-ffmpeg-8.1-lgpl21.ps1
```

## Release assets (this tag: n8.1.2-2)

| Asset | Contents |
|-------|----------|
| `ffmpeg-windows-8.1-lgpl21-n8.1.2-2-win64.zip` | `bin/*.dll`, `bin/ffmpeg.exe`, `bin/ffprobe.exe`, `lib/*.lib`, `include/`, `LICENSE.txt`, `ORIGIN.txt`, scrubbed `config.h` |
| `n8.1.2.tar.gz` | Upstream FFmpeg tag tarball (`n8.1.2`) |
| `snappy-1.2.2.tar.gz` | Snappy 1.2.2 source (statically linked into `avcodec`) |
| `zlib-1.3.1.tar.gz` | zlib 1.3.1 source (statically linked into `avcodec`) |

`ffplay.exe` is deliberately not built (`--disable-ffplay`): it would add an SDL2
dependency and no consumer uses it.

Release page: https://github.com/TTI-DCS/ffmpeg-lgpl-builds/releases/tag/n8.1.2-2

## Consumers

| Project | How it installs | What it uses |
|---------|-----------------|--------------|
| wonder_flow | `scripts/setup-ffmpeg-8.1-lgpl21.ps1` (Releases API) | DLLs + import libs |
| loopeek | `scripts/fetch-ffmpeg-dev-libs-windows.sh` (Releases, SHA-256 pinned) | DLLs + import libs + the CLI |
| kinocore | whatever `FFMPEG_DIR` its consumer sets | DLLs + import libs |

loopeek spawns `ffmpeg` / `ffprobe` as processes for conversion, probing and proxy
generation, which is why the CLI ships here rather than being fetched separately.
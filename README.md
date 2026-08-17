# ffmpeg-lgpl-builds

Public LGPL **v2.1+** Windows shared builds of FFmpeg for Wonder Screen / wonder_flow (#321).

This repository hosts:

- **Build scripts** (reproduce the MSVC shared build)
- **GitHub Release assets**: prebuilt `win64` zip **and** the corresponding FFmpeg source tarball

Binaries and corresponding source are published on the **same Release page** so LGPL's
offer of corresponding source from the same public place is satisfied.

## License

FFmpeg itself is LGPL v2.1 or later for this build.

- No `--enable-gpl`
- No `--enable-version3` (that would make the build LGPL **v3**)
- No `--enable-nonfree`

See `LICENSE-NOTES.md` and the `LICENSE.txt` inside each binary zip (FFmpeg `COPYING.LGPLv2.1`).

## Configure (recorded / reproducible form)

Actual builds use a real `--prefix=...` path on the builder machine.
Published `ORIGIN.txt` / `config.h` record the **generic** form:

```
./configure --toolchain=msvc --prefix=<prefix> --enable-shared --disable-static --disable-programs --disable-doc --disable-debug
```

Extra flags used by the packaging scripts: none beyond the line above.

## Reproduce (Windows)

1. Visual Studio Build Tools 2022 (MSVC + VsDevShell)
2. MSYS2 with `make`, `diffutils`; nasm on mingw64 PATH
3. From a checkout of this repo (or wonder_flow `scripts/`):

```powershell
pwsh -NoProfile -File scripts/build-ffmpeg-8.1-lgpl.ps1
pwsh -NoProfile -File scripts/package-ffmpeg-8.1-lgpl21.ps1
```

## Release assets (this tag: n8.1.2)

| Asset | Contents |
|-------|----------|
| `ffmpeg-windows-8.1-lgpl21-n8.1.2-win64.zip` | `bin/*.dll`, `lib/*.lib`, `include/`, `LICENSE.txt`, `ORIGIN.txt`, scrubbed `config.h` |
| `n8.1.2.tar.gz` | Upstream FFmpeg tag tarball (`n8.1.2`) |

Release page: https://github.com/TTI-DCS/ffmpeg-lgpl-builds/releases/tag/n8.1.2

## Consumers

wonder_flow installs the binary zip via `scripts/setup-ffmpeg-8.1-lgpl21.ps1`
(GitHub Releases API for `TTI-DCS/ffmpeg-lgpl-builds`).
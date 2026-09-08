# FFmpeg 8.1 LGPL v2.1 自前ビルド成果物を公開用アセットにする (#321)。
#
# 配布先: TTI-DCS/ffmpeg-lgpl-builds の GitHub Release (public)
#   - バイナリ zip と対応ソース tarball は **別アセット** (同じ Release = 同じ公開の場所)
#   - zip 内に source/ は入れない
#
# ★ 対応ソースは3つある。snappy と zlib は avcodec へ **静的リンク** されるので、
#   この DLL の corresponding source に含まれる。FFmpeg の tarball だけでは
#   LGPL の要求を満たさない。
#
# 生成物 (既定 OutDir = dist/ffmpeg-lgpl-builds-handoff/):
#   RELEASE_ASSETS/ffmpeg-windows-8.1-lgpl21-<tag>-win64.zip
#   RELEASE_ASSETS/<ffmpeg-tag>.tar.gz
#   RELEASE_ASSETS/snappy-<ver>.tar.gz
#   RELEASE_ASSETS/zlib-<ver>.tar.gz
#
# README.md / LICENSE-NOTES.md はこのリポジトリのルートへ直接書く。以前は別リポへ
# 手で移す前提で REPO_FILES/ に出していたが、このスクリプト自体がその別リポに
# 移ったので、その間接は無くした。
#
# 使い方:
#   pwsh -File scripts/package-ffmpeg-8.1-lgpl21.ps1
#   pwsh -File scripts/package-ffmpeg-8.1-lgpl21.ps1 -VendorDir ...\vendor -OutDir ...\dist\...

param(
    [string]$VendorDir = (Join-Path $PSScriptRoot "..\vendor"),
    [string]$DirName = "ffmpeg-windows-8.1-lgpl21",
    [string]$FFmpegTag = "n8.1.2",
    [string]$OutDir = (Join-Path $PSScriptRoot "..\dist\ffmpeg-lgpl-builds-handoff"),
    [string]$SourceTarball = "",
    [string]$BuildsRepo = "TTI-DCS/ffmpeg-lgpl-builds",
    [string]$ReleaseTag = "",
    # 静的リンクされる外部ライブラリ。build-ffmpeg-8.1-lgpl.ps1 の既定と揃えること
    # (ORIGIN.txt の記録と照合して食い違えば失敗する)。
    [string]$SnappyVersion = "1.2.2",
    [string]$ZlibVersion = "1.3.1"
)

$ErrorActionPreference = "Stop"

if (-not $ReleaseTag) { $ReleaseTag = $FFmpegTag }

$VendorDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VendorDir)
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$FFmpegDir = Join-Path $VendorDir $DirName
$WorkRoot = Join-Path $VendorDir ".ffmpeg-8.1-lgpl21-build"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# ★ configure 行はここに書かない。build-ffmpeg-8.1-lgpl.ps1 が vendor の ORIGIN.txt に
#   書いたものを読む。以前はこのスクリプトにも同じ文字列がハードコードされており、
#   ビルド側にフラグを足すと **公開記録だけが古いまま**になる余地があった。
#   ORIGIN.txt の書き手はビルドスクリプト1つに限る。
$PublicConfigure = ""
$ReleasePageUrl = "https://github.com/$BuildsRepo/releases/tag/$ReleaseTag"
$BinaryZipName = "$DirName-$ReleaseTag-win64.zip"
$SourceAssetName = "$FFmpegTag.tar.gz"
$SnappyAssetName = "snappy-$SnappyVersion.tar.gz"
$ZlibAssetName = "zlib-$ZlibVersion.tar.gz"
$SnappyTarUrl = "https://github.com/google/snappy/archive/refs/tags/$SnappyVersion.tar.gz"
$ZlibTarUrl = "https://github.com/madler/zlib/archive/refs/tags/v$ZlibVersion.tar.gz"

function Scrub-LocalPathsInText {
    param([string]$Text)
    $Text = [regex]::Replace($Text, "--prefix='[^']*'", "--prefix='<prefix>'")
    $Text = [regex]::Replace($Text, '--prefix="[^"]*"', '--prefix="<prefix>"')
    $Text = [regex]::Replace($Text, '--prefix=(?!<prefix>)(?:[A-Za-z]:)?[^\s"'']+', '--prefix=<prefix>')
    $Text = [regex]::Replace($Text, '(#define\s+(?:FFMPEG_DATADIR|AVCONV_DATADIR)\s+")[^"]+(")', '${1}<prefix>/share/ffmpeg${2}')
    $Text = [regex]::Replace($Text, '(?i)[A-Za-z]:/(?:Users|home)/[^\s"'']+', '<local-path>')
    $Text = [regex]::Replace($Text, '(?i)\\Users\\[^\s"'']+', '<local-path>')
    $Text = [regex]::Replace($Text, '(?i)/c/Users/[^\s"'']+', '<local-path>')
    return $Text
}

function Assert-NoLocalSecrets {
    param([string]$Root)
    $patterns = @(
        '(?i)C:/Users/',
        '(?i)C:\\Users\\',
        '(?i)/c/Users/',
        '(?i)\\.herdr\\',
        '(?i)/.herdr/',
        '(?i)sho1i',
        '(?i)worktrees',
        '(?i)probe-v3'
    )
    $files = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -match '\.(txt|h|log|md|pc|cmake)$' -or
            $_.Name -match '^(ORIGIN|SOURCE|NOTICE|LICENSE|config)' -or
            $_.Extension -eq '.dll'
        }
    foreach ($f in $files) {
        if ($f.Extension -eq '.dll') {
            continue  # DLL は Assert-ZipPublicClean で strings 実測
        }
        $raw = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }
        foreach ($pat in $patterns) {
            if ($raw -match $pat) {
                throw "Public scrub failed: local path/user in $($f.FullName) (pattern $pat)"
            }
        }
    }
}

function Assert-ZipPublicClean {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    if ($ZipPath -notmatch '-win64\.zip$') {
        throw "Zip name must end with -win64.zip (got: $(Split-Path $ZipPath -Leaf))"
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ff-zip-verify-" + [guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $tmp -Force
        $origin = Get-ChildItem $tmp -Recurse -Filter 'ORIGIN.txt' | Select-Object -First 1
        if (-not $origin) { throw "ORIGIN.txt missing inside zip" }
        $originText = Get-Content $origin.FullName -Raw
        Write-Host "=== ORIGIN.txt (from zip) ==="
        Write-Host $originText.TrimEnd()
        if ($originText -match '(?i)sho1i|(?i)\.herdr|(?i)worktrees|(?i)C:/Users/|(?i)\\Users\\') {
            throw "ORIGIN.txt inside zip still has local paths"
        }
        if ($originText -notmatch '--prefix=<prefix>') {
            throw "ORIGIN.txt configure must use generic --prefix=<prefix>"
        }

        $cfg = Get-ChildItem $tmp -Recurse -Filter 'config.h' | Select-Object -First 1
        if ($cfg) {
            $cfgText = Get-Content $cfg.FullName -Raw
            if ($cfgText -match '--enable-gpl\b') { throw "config.h has --enable-gpl" }
            if ($cfgText -match '--enable-version3\b') { throw "config.h has --enable-version3" }
            if ($cfgText -match '--enable-nonfree\b') { throw "config.h has --enable-nonfree" }
            Write-Host "=== license flags in config.h ==="
            Write-Host "  --enable-gpl:      absent"
            Write-Host "  --enable-version3: absent"
            Write-Host "  --enable-nonfree:  absent"
            $m = [regex]::Match($cfgText, '#define\s+FFMPEG_CONFIGURATION\s+"([^"]+)"')
            if ($m.Success) { Write-Host ("  FFMPEG_CONFIGURATION: {0}" -f $m.Groups[1].Value) }
        }

        $needles = @('sho1i', '.herdr', 'worktrees', 'Users')
        # ★ .exe も走査する。CLI を配るようになった分、ここを *.dll のままにすると
        #   ffmpeg.exe / ffprobe.exe が検査を素通りする。
        #   (C:/ffmpeg-build/... は意図して選んだ中立パスなので needles に入れない。
        #    禁じているのはユーザ名と worktree パスである。)
        $dlls = @(Get-ChildItem $tmp -Recurse -Include '*.dll', '*.exe')
        if (@(Get-ChildItem $tmp -Recurse -Filter '*.dll').Count -eq 0) { throw "No DLLs inside zip" }
        foreach ($exe in @('ffmpeg.exe', 'ffprobe.exe')) {
            if (-not (Get-ChildItem $tmp -Recurse -Filter $exe)) { throw "$exe missing inside zip" }
        }
        if (Get-ChildItem $tmp -Recurse -Filter 'ffplay.exe') { throw "ffplay.exe must not be in the zip" }
        Write-Host "=== strings scan (DLL + EXE, ASCII+UTF16) ==="
        $totalHits = 0
        foreach ($d in $dlls) {
            $bytes = [System.IO.File]::ReadAllBytes($d.FullName)
            $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
            $utf16 = [System.Text.Encoding]::Unicode.GetString($bytes)
            foreach ($n in $needles) {
                $ca = ([regex]::Matches($ascii, [regex]::Escape($n))).Count
                $cu = ([regex]::Matches($utf16, [regex]::Escape($n))).Count
                $c = $ca + $cu
                Write-Host ("  {0}: {1} = {2}" -f $d.Name, $n, $c)
                $totalHits += $c
            }
        }
        if ($totalHits -ne 0) {
            throw "Public scrub failed: $totalHits forbidden string hit(s) in zip DLLs"
        }
        Write-Host "=== strings verdict: ALL ZERO (sho1i / .herdr / worktrees / Users) ==="
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    }
}

function Update-VendorForPublic {
    param([string]$Root)

    # configure.log は絶対パスだらけ → 公開物から削除
    $clog = Join-Path $Root "configure.log"
    if (Test-Path $clog) { Remove-Item -Force $clog }

    # 旧方針の同梱 source/ は Release 別アセットへ移したので zip から外す
    $srcSide = Join-Path $Root "source"
    if (Test-Path $srcSide) { Remove-Item -Recurse -Force $srcSide }
    $sourceTxt = Join-Path $Root "SOURCE.txt"
    if (Test-Path $sourceTxt) { Remove-Item -Force $sourceTxt }

    # ★ ORIGIN.txt は build-ffmpeg-8.1-lgpl.ps1 が書いたものを **そのまま使う**。
    #   ここで書き直していた頃は configure 行と外部ライブラリの記録が
    #   ビルド側と二重管理になり、フラグを足すと公開記録だけ古くなった。
    #   ここでやるのは検証と、Release URL 行の差し替えだけである。
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $originPath = Join-Path $Root "ORIGIN.txt"
    $originText = [System.IO.File]::ReadAllText($originPath)

    foreach ($needed in @('kind=selfbuild', 'license=LGPLv2.1+', "ffmpeg_tag=$FFmpegTag",
                          "snappy_version=$SnappyVersion", "zlib_version=$ZlibVersion")) {
        if ($originText -notmatch [regex]::Escape($needed)) {
            throw "ORIGIN.txt is missing '$needed'. Rebuild with scripts/build-ffmpeg-8.1-lgpl.ps1 (its parameters must match this script's)."
        }
    }
    $cfgMatch = [regex]::Match($originText, '(?m)^configure=(.+)$')
    if (-not $cfgMatch.Success) { throw "ORIGIN.txt has no configure= line" }
    $script:PublicConfigure = $cfgMatch.Groups[1].Value.Trim()
    if ($script:PublicConfigure -notmatch '--prefix=<prefix>') {
        throw "ORIGIN.txt configure line is not in generic form: $($script:PublicConfigure)"
    }
    if ($script:PublicConfigure -match '--disable-programs') {
        throw "ORIGIN.txt configure line still has --disable-programs; the CLI must be built (loopeek spawns it)"
    }
    # Release URL だけは公開先のタグに合わせて差し替える。
    $originText = [regex]::Replace($originText, '(?m)^builds_release_url=.*$', "builds_release_url=$ReleasePageUrl")
    [System.IO.File]::WriteAllText($originPath, $originText, $utf8)

    $configH = Join-Path $Root "config.h"
    if (Test-Path $configH) {
        $cfgRaw = Scrub-LocalPathsInText -Text (Get-Content $configH -Raw)
        [System.IO.File]::WriteAllText($configH, $cfgRaw, $utf8)
    }

    $ffver = Join-Path $Root "include\libavutil\ffversion.h"
    if (Test-Path $ffver) {
        $verNum = $FFmpegTag -replace '^n', ''
        $ffverBody = @"
#ifndef AVUTIL_FFVERSION_H
#define AVUTIL_FFVERSION_H
#define FFMPEG_VERSION "$verNum"
#endif /* AVUTIL_FFVERSION_H */
"@
        [System.IO.File]::WriteAllText($ffver, ($ffverBody -replace "`r`n", "`n"), $utf8)
    }

    Assert-NoLocalSecrets -Root $Root
}

$required = @(
    (Join-Path $FFmpegDir "lib\avcodec.lib"),
    (Join-Path $FFmpegDir "bin"),
    (Join-Path $FFmpegDir "bin\ffmpeg.exe"),
    (Join-Path $FFmpegDir "bin\ffprobe.exe"),
    (Join-Path $FFmpegDir "include\libavcodec\avcodec.h"),
    (Join-Path $FFmpegDir "LICENSE.txt"),
    (Join-Path $FFmpegDir "ORIGIN.txt")
)
foreach ($r in $required) {
    if (-not (Test-Path $r)) {
        throw "Vendor incomplete: $r — run scripts/build-ffmpeg-8.1-lgpl.ps1 first"
    }
}

$origin = Get-Content (Join-Path $FFmpegDir "ORIGIN.txt") -Raw
if ($origin -notmatch 'kind=selfbuild') {
    throw "ORIGIN.txt must have kind=selfbuild"
}

# 対応ソースは3つ。snappy と zlib は avcodec へ静的リンクされるので、この DLL の
# corresponding source に含まれる。FFmpeg の tarball だけでは LGPL を満たさない。
function Resolve-SourceTarball {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Preferred = ""
    )
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    foreach ($dir in @("C:\ffmpeg-build\src", $WorkRoot, "C:\ffmpeg-lgpl21-src")) {
        $c = Join-Path $dir $FileName
        if (Test-Path $c) { return $c }
    }
    $dest = Join-Path "C:\ffmpeg-build\src" $FileName
    Write-Host "Source tarball missing; downloading $Url ..."
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Invoke-WebRequest -Uri $Url -OutFile $dest
    return $dest
}

$SourceTarball = Resolve-SourceTarball -FileName "$FFmpegTag.tar.gz" `
    -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FFmpegTag.tar.gz" `
    -Preferred $SourceTarball
# build-ffmpeg-8.1-lgpl.ps1 は snappy-<ver>.tar.gz / zlib-v<ver>.tar.gz という名前で
# WorkRoot へ落とす (Get-TarballSource が Label を前置する)。無ければ取り直す。
$SnappyTarball = Resolve-SourceTarball -FileName "snappy-$SnappyVersion.tar.gz" -Url $SnappyTarUrl
$ZlibTarball = Resolve-SourceTarball -FileName "zlib-v$ZlibVersion.tar.gz" -Url $ZlibTarUrl

$assetsDir = Join-Path $OutDir "RELEASE_ASSETS"
# README / LICENSE-NOTES はこのリポジトリのルートへ直接書く (このスクリプトが
# builds リポに移ったので、別リポへ手で移す中間ディレクトリは不要)。
$repoFilesDir = $RepoRoot
$stage = Join-Path $OutDir ".$DirName-pack.tmp"
$zipPath = Join-Path $assetsDir $BinaryZipName
$sourceOut = Join-Path $assetsDir $SourceAssetName
$snappyOut = Join-Path $assetsDir $SnappyAssetName
$zlibOut = Join-Path $assetsDir $ZlibAssetName

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
New-Item -ItemType Directory -Force -Path $repoFilesDir | Out-Null
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$payload = Join-Path $stage $DirName
Write-Host "Staging scrubbed binary payload -> $payload"
Copy-Item -Recurse $FFmpegDir $payload
Update-VendorForPublic -Root $payload

# 手元 vendor も scrub (次回 NOTICE / ローカル検証が公開形と一致)
Update-VendorForPublic -Root $FFmpegDir

if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
# 旧名 ( -win64 無し ) が残っていたら消す — setup が期待する名前に統一
$legacyZip = Join-Path $assetsDir "$DirName-$FFmpegTag.zip"
if (Test-Path $legacyZip) {
    Write-Host "Removing legacy zip without -win64: $legacyZip"
    Remove-Item -Force $legacyZip
}
# dist/ 直下に古い -win64 無し zip があると誤添付しやすいので消す
$distRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\dist")).Path
$legacyDistZip = Join-Path $distRoot "$DirName-$FFmpegTag.zip"
if (Test-Path $legacyDistZip) {
    Write-Host "Removing legacy dist zip without -win64: $legacyDistZip"
    Remove-Item -Force $legacyDistZip
}
$legacySourceName = Join-Path $assetsDir "FFmpeg-$FFmpegTag.tar.gz"
if ((Test-Path $legacySourceName) -and ($SourceAssetName -ne "FFmpeg-$FFmpegTag.tar.gz")) {
    Write-Host "Removing legacy source asset name: $legacySourceName"
    Remove-Item -Force $legacySourceName
}
Write-Host "Compressing $zipPath ..."
Compress-Archive -Path $payload -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -Recurse -Force $stage

Copy-Item $SourceTarball $sourceOut -Force
Copy-Item $SnappyTarball $snappyOut -Force
Copy-Item $ZlibTarball $zlibOut -Force

# ★ 公開前必須: zip を展開し DLL を strings 走査 (sho1i / .herdr / worktrees / Users = 0)
Assert-ZipPublicClean -ZipPath $zipPath

# --- 別リポ TTI-DCS/ffmpeg-lgpl-builds 向けファイル ---
# スクリプトのコピーは要らない。このファイル自身が builds リポの scripts/ にある。
$scriptsOut = Join-Path $RepoRoot "scripts"

$readme = @"
# ffmpeg-lgpl-builds

Public LGPL **v2.1+** Windows shared builds of FFmpeg, shared by
**wonder_flow**, **loopeek** and **kinocore** (#321).

All three link the same binary. That is the point: kinocore is compiled against
whatever FFmpeg its consumer supplies, so two separately produced builds mean
"works in kinocore, breaks in the app" is possible without anything recording
which one a given test ran under.

This repository hosts:

- **Build scripts** (reproduce the MSVC shared build)
- **GitHub Release assets**: prebuilt ``win64`` zip **and** the corresponding source
  for everything linked into it

Binaries and corresponding source are published on the **same Release page** so LGPL's
offer of corresponding source from the same public place is satisfied.

## License

FFmpeg itself is LGPL v2.1 or later for this build.

- No ``--enable-gpl``
- No ``--enable-version3`` (that would make the build LGPL **v3**)
- No ``--enable-nonfree``

Two external libraries are linked, both **statically into ``avcodec``**:

| Library | Version | License |
|---------|---------|---------|
| [Snappy](https://github.com/google/snappy) | $SnappyVersion | BSD-3-Clause |
| [zlib](https://github.com/madler/zlib) | $ZlibVersion | Zlib |

Snappy provides the HAP encoder and zlib the PNG / EXR encoders, which loopeek
needs. Because they are compiled into the LGPL DLL, their source belongs to that
DLL's corresponding source and is attached to the same Release.

See ``LICENSE-NOTES.md`` and the ``LICENSE.txt`` inside each binary zip (FFmpeg ``COPYING.LGPLv2.1``).

## Configure (recorded / reproducible form)

Actual builds use a real ``--prefix=...`` path on the builder machine.
Published ``ORIGIN.txt`` / ``config.h`` record the **generic** form:

``````
$PublicConfigure
``````

The line is not written here by hand. ``build-ffmpeg-8.1-lgpl.ps1`` records it in
``ORIGIN.txt`` and the packaging script reads it back, so the published record cannot
drift from the flags actually used. The real ``--prefix`` and the external-library
prefix are replaced with ``<prefix>`` and ``<deps>``.

## Reproduce (Windows)

1. Visual Studio Build Tools 2022 (MSVC + VsDevShell, including the
   *C++ CMake tools for Windows* component -- Snappy and zlib are built with CMake)
2. MSYS2 with ``make``, ``diffutils``; nasm on mingw64 PATH
3. From a checkout of **this** repo. The scripts here are the originals; wonder_flow
   keeps a copy of the build script for reference, but packaging happens here:

``````powershell
pwsh -NoProfile -File scripts/build-ffmpeg-8.1-lgpl.ps1
pwsh -NoProfile -File scripts/package-ffmpeg-8.1-lgpl21.ps1
``````

## Release assets (this tag: $ReleaseTag)

| Asset | Contents |
|-------|----------|
| ``$BinaryZipName`` | ``bin/*.dll``, ``bin/ffmpeg.exe``, ``bin/ffprobe.exe``, ``lib/*.lib``, ``include/``, ``LICENSE.txt``, ``ORIGIN.txt``, scrubbed ``config.h`` |
| ``$SourceAssetName`` | Upstream FFmpeg tag tarball (``$FFmpegTag``) |
| ``$SnappyAssetName`` | Snappy $SnappyVersion source (statically linked into ``avcodec``) |
| ``$ZlibAssetName`` | zlib $ZlibVersion source (statically linked into ``avcodec``) |

``ffplay.exe`` is deliberately not built (``--disable-ffplay``): it would add an SDL2
dependency and no consumer uses it.

Release page: $ReleasePageUrl

## Consumers

| Project | How it installs | What it uses |
|---------|-----------------|--------------|
| wonder_flow | ``scripts/setup-ffmpeg-8.1-lgpl21.ps1`` (Releases API) | DLLs + import libs |
| loopeek | ``scripts/fetch-ffmpeg-dev-libs-windows.sh`` (Releases, SHA-256 pinned) | DLLs + import libs + the CLI |
| kinocore | whatever ``FFMPEG_DIR`` its consumer sets | DLLs + import libs |

loopeek spawns ``ffmpeg`` / ``ffprobe`` as processes for conversion, probing and proxy
generation, which is why the CLI ships here rather than being fetched separately.
"@

$licenseNotes = @"
# LICENSE notes (ffmpeg-lgpl-builds)

## What we redistribute

Each Release attaches:

1. A Windows shared FFmpeg build (DLLs + MSVC import libs + headers + the ``ffmpeg`` /
   ``ffprobe`` command-line tools)
2. The corresponding FFmpeg source tarball for the same tag
3. The corresponding Snappy source tarball
4. The corresponding zlib source tarball

All four are on the same public GitHub Release. That is intentional for LGPL.

**Why three source tarballs.** Snappy and zlib are permissive and carry no source
obligation of their own, but they are linked **statically into ``avcodec``**. They are
therefore part of that DLL's *corresponding source*, and the FFmpeg tarball alone
would not satisfy LGPL for the binary we publish.

## FFmpeg license for this build

LGPL version 2.1 or later.

The binary zip includes ``LICENSE.txt`` copied from FFmpeg ``COPYING.LGPLv2.1``.

The ``ffmpeg`` and ``ffprobe`` programs are covered by the same licence in this build:
``--enable-gpl`` is absent, so they are LGPL v2.1+ rather than GPL, and the FFmpeg
tarball above is their corresponding source too.

## External libraries

| Library | Version | License | Linked |
|---------|---------|---------|--------|
| Snappy | $SnappyVersion | BSD-3-Clause | statically into ``avcodec`` |
| zlib | $ZlibVersion | Zlib | statically into ``avcodec`` |

Both licences are permissive and compatible with LGPL v2.1. Redistributing the
binary requires keeping their copyright notices; consumers bundle those notices
next to their own (loopeek ships ``COPYING.snappy`` and the zlib notice with the app).

Nothing else is linked: the build passes ``--pkg-config=false`` so configure cannot
autodetect a library from the MSYS2 environment that happens to be on PATH.

## What we do not claim

- This repo does not re-license FFmpeg, Snappy or zlib.
- Consumer application code remains under its own license; the FFmpeg linkage is
  dynamic (DLL), so a compatible build can be substituted without rebuilding the
  application.

## Source offer

FFmpeg:

- Tag tree: https://github.com/FFmpeg/FFmpeg/tree/$FFmpegTag
- Tarball (attached to the Release): $SourceAssetName
- Upstream URL: https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FFmpegTag.tar.gz

Snappy:

- Tarball (attached to the Release): $SnappyAssetName
- Upstream URL: $SnappyTarUrl

zlib:

- Tarball (attached to the Release): $ZlibAssetName
- Upstream URL: $ZlibTarUrl

Exact configure line: see ``ORIGIN.txt`` inside the binary zip (generic
``--prefix=<prefix>`` and ``<deps>``). ``ORIGIN.txt`` also records the Snappy and zlib
versions and their upstream URLs.

## Build scripts

``scripts/build-ffmpeg-8.1-lgpl.ps1`` builds Snappy, zlib and FFmpeg, documents the
MSVC in-tree requirements, and does not enable GPL / version3 / nonfree. It fails
the build if any of those flags reappear, if the expected encoders are missing, or
if the resulting DLL is not self-contained.

LGPL v2.1 section 6 asks for the scripts used to control compilation and
installation of the library. That is this directory, in this public repository,
covering all three components.
"@

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $repoFilesDir "README.md"), ($readme -replace "`r`n", "`n"), $utf8)
[System.IO.File]::WriteAllText((Join-Path $repoFilesDir "LICENSE-NOTES.md"), ($licenseNotes -replace "`r`n", "`n"), $utf8)

$manifest = @"
# Handoff for owner: create GitHub Release on $BuildsRepo

Release tag (suggested): $ReleaseTag
Release page URL: $ReleasePageUrl

## Attach these files (Release assets)

1. $zipPath
2. $sourceOut
3. $snappyOut
4. $zlibOut

All four belong on the same Release. Snappy and zlib are linked statically into
``avcodec``, so their source is part of that DLL's corresponding source under LGPL --
attaching only the FFmpeg tarball is not enough.

## Already written into this repository (review, then commit)

- $(Join-Path $repoFilesDir "README.md")
- $(Join-Path $repoFilesDir "LICENSE-NOTES.md")

These are generated, not hand-maintained. Edit the here-strings in
``scripts/package-ffmpeg-8.1-lgpl21.ps1`` and re-run, rather than editing the files.

## After the Release exists

Update the consumers' pinned tag:

- wonder_flow ``scripts/setup-ffmpeg-8.1-lgpl21.ps1`` -- default ``-ReleaseTag``
- loopeek ``scripts/fetch-ffmpeg-dev-libs-windows.sh`` -- ``RELEASE_TAG`` **and** the
  pinned SHA-256 of ``$BinaryZipName``, which loopeek verifies before unpacking

Both fetch asset ``$BinaryZipName`` from ``$BuildsRepo`` releases/tags/$ReleaseTag.
Keep the previous Release in place so a consumer can roll back by reverting one line.
"@
[System.IO.File]::WriteAllText((Join-Path $OutDir "HANDOFF.md"), ($manifest -replace "`r`n", "`n"), $utf8)

function Show-Asset([string]$Label, [string]$Path) {
    $mb = [math]::Round((Get-Item $Path).Length / 1MB, 2)
    Write-Host ("  {0,-22} {1} ({2} MB)" -f $Label, $Path, $mb)
}
Write-Host "DONE."
Show-Asset "Binary:" $zipPath
Show-Asset "FFmpeg source:" $sourceOut
Show-Asset "Snappy source:" $snappyOut
Show-Asset "zlib source:" $zlibOut
Write-Host "  Repo files written to: $repoFilesDir (README.md, LICENSE-NOTES.md)"
Write-Host "  See: $(Join-Path $OutDir 'HANDOFF.md')"

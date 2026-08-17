# FFmpeg 8.1 を MSVC toolchain で自前ビルドし、LGPL v2.1+ の shared vendor を作る (#321)。
#
# ⚠ BtbN の win64-lgpl-shared は --enable-version3 付き (= LGPL v3)。v2.1 にするには自前ビルドが必要。
# ⚠ ffmpeg-sys-next は MSVC でリンクするので .lib が要る → 必ず --toolchain=msvc。
#    MinGW で出る .dll.a を .lib に改名する回避はしない。
# ⚠ 既存の vendor/ffmpeg-windows-8.1 (BtbN) は触らない。別ディレクトリへ入れる。
# ⚠ --enable-gpl / --enable-version3 / --enable-nonfree は付けない。
# ⚠ --disable-everything でコーデックを絞らない。
#
# worktree から親リポの vendor へ入れる例:
#   pwsh -NoProfile -File scripts/build-ffmpeg-8.1-lgpl.ps1 `
#     -VendorDir C:\Users\sho1i\workspace\wonder_flow\vendor
#
# ビルドが失敗したらこのスクリプトは非 0 で止まり、エラーを隠さない。
#
# ★ 2026-08-17 失敗記録と定石 (#321):
#   (1) ソースを MSYS 形式 (/c/...) で out-of-tree configure → make → cl が
#       D8043 (unknown option '/c/...')。cl は先頭 '/' をスイッチと見る。
#   (2) パスを Windows 形式 (C:/...) にして out-of-tree し直しても、
#       configure が MSYS2 上で source path を /c/... に正規化するため同じ D8043。
#       --prefix は C:/... のまま保持される。変換抑止
#       (MSYS2_ARG_CONV_EXCL=* / MSYS_NO_PATHCONV=1) は維持したまま。
#       ⇒ out-of-tree は MSYS2+MSVC では原理的に通らない。
#   (3) 定石は FFmpeg doc/platform.texi (Microsoft Visual C++ 節) どおりの
#       **in-tree** ビルド。ソースツリーで ./configure すると SRC_PATH=. になり、
#       cl には libavdevice/alldevices.c のような相対パスが渡るので D8043 が起きない。
#       ソースは汚れるが vendor 用の使い捨て — 成功後にソースツリーを削除する。
#   (6) ORIGIN / 公開用 config.h の --prefix は <prefix> と記録する。実ビルドは実パス。
#       configure.log はローカル絶対パスを含むので vendor 公開物には入れない。

param(
    [string]$VendorDir = (Join-Path $PSScriptRoot "..\vendor"),
    [string]$DirName = "ffmpeg-windows-8.1-lgpl21",
    [string]$FFmpegTag = "n8.1.2",
    [string]$SourceDir = "",
    [string]$MsysBash = "C:\msys64\usr\bin\bash.exe",
    [int]$Jobs = 0,
    # 既存の prefix + ソースから vendor 整形だけやり直す (フルビルドを飛ばす)
    [switch]$PackageOnly,
    # 受け入れ検証完了後にソース / prefix を消すときだけ付ける
    [switch]$RemoveSource
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$VendorDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VendorDir)
$FFmpegDir = Join-Path $VendorDir $DirName
# ★ ソースツリーの絶対パスは MSVC が __FILE__ 等で DLL に焼き付ける。
#   ユーザホーム / .herdr worktree 配下でビルドすると公開 zip にユーザ名が残る (#321)。
#   ソース展開・ビルド・--prefix はすべて中立パス C:\ffmpeg-build\... を既定にする。
$WorkRoot = if ($env:WONDER_FFMPEG_BUILD_WORKROOT) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:WONDER_FFMPEG_BUILD_WORKROOT)
} else {
    "C:\ffmpeg-build\src"
}
$SrcDir = if ($SourceDir) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceDir)
} else {
    Join-Path $WorkRoot "FFmpeg-$FFmpegTag"
}
# ★ --prefix も configuration 文字列として DLL に焼き付く。ユーザ名を含めない。
$PrefixDir = if ($env:WONDER_FFMPEG_BUILD_PREFIX) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:WONDER_FFMPEG_BUILD_PREFIX)
} else {
    "C:\ffmpeg-build\prefix"
}
# ログだけはリポ側 vendor に残してよい (公開 zip には入れない)
$LogDir = Join-Path $VendorDir ".ffmpeg-8.1-lgpl21-build\logs"
$ConfigureLog = Join-Path $LogDir "configure.log"
$MakeLog = Join-Path $LogDir "make.log"
$InstallLog = Join-Path $LogDir "install.log"

$TagUrl = "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FFmpegTag.tar.gz"
$TagBrowseUrl = "https://github.com/FFmpeg/FFmpeg/tree/$FFmpegTag"

# 指示書どおりの configure フラグ (gpl / version3 / nonfree / disable-everything は付けない)
$ConfigureArgs = @(
    "--toolchain=msvc",
    "--prefix=PREFIX_PLACEHOLDER",
    "--enable-shared",
    "--disable-static",
    "--disable-programs",
    "--disable-doc",
    "--disable-debug"
)

# PATH 上のツール位置だけ MSYS 形式 (/c/...) にする。bash の which 用。
# ★ソース／ビルド／prefix には使わないこと — 下記 ConvertTo-WinFwdPath を見よ。
function ConvertTo-MsysPath([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    $full = $full -replace '\\', '/'
    if ($full -match '^([A-Za-z]):/(.*)$') {
        return "/$($Matches[1].ToLower())/$($Matches[2])"
    }
    return $full
}

# MSVC (cl.exe / link.exe) 向けパスメモ。
#
# 失敗記録 (2026-08-17 / #321):
#   out-of-tree で絶対パスを渡すと、形式が C:/... でも configure が source path を
#   /c/... に正規化し、make → cl が D8043。out-of-tree は原理的に不可。
#   in-tree (ソースで ./configure) なら SRC_PATH=. で相対パスになり回避できる。
#   --prefix だけは Windows 形式 C:/... でよい (install 先は cl を通らない)。
#   MSYS2_ARG_CONV_EXCL=* / MSYS_NO_PATHCONV=1 は justfile 同様「抑止したまま」。
function ConvertTo-WinFwdPath([string]$WinPath) {
    return ([System.IO.Path]::GetFullPath($WinPath)) -replace '\\', '/'
}

function Import-VsDevEnvironment {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere not found: $vswhere"
    }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
        Select-Object -First 1
    if (-not $vsPath) {
        throw "Visual Studio with VC tools not found"
    }
    $launch = Join-Path $vsPath "Common7\Tools\Launch-VsDevShell.ps1"
    if (-not (Test-Path $launch)) {
        throw "Launch-VsDevShell.ps1 not found: $launch"
    }
    Write-Host "Loading VsDevShell (amd64): $vsPath"
    & $launch -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null

    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    $link = Get-Command link.exe -ErrorAction SilentlyContinue
    if (-not $cl) { throw "cl.exe not on PATH after VsDevShell" }
    if (-not $link) { throw "link.exe not on PATH after VsDevShell" }
    Write-Host "  cl:   $($cl.Source)"
    Write-Host "  link: $($link.Source)"
    if ($link.Source -match '\\usr\\bin\\link\.exe$') {
        throw "MSVC link.exe is shadowed by MSYS link.exe: $($link.Source)"
    }
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-FFmpegSource {
    # 既存ソースがユーザホーム配下なら捨てて中立 WorkRoot へ取り直す
    if ((Test-Path (Join-Path $SrcDir "configure"))) {
        $fwd = ConvertTo-WinFwdPath $SrcDir
        if ($fwd -match '(?i)/Users/|(?i)/home/|(?i)/\.herdr/') {
            Write-Host "Existing source is under a user path ($SrcDir); removing for public-safe rebuild..."
            Remove-Item -Recurse -Force $SrcDir
        } else {
            Write-Host "Using existing FFmpeg source: $SrcDir"
            return
        }
    }
    Ensure-Dir $WorkRoot
    $tarPath = Join-Path $WorkRoot "$FFmpegTag.tar.gz"
    if (-not (Test-Path $tarPath)) {
        $legacyTar = Join-Path $VendorDir ".ffmpeg-8.1-lgpl21-build\$FFmpegTag.tar.gz"
        if (Test-Path $legacyTar) {
            Copy-Item $legacyTar $tarPath -Force
        } else {
            Write-Host "Downloading $TagUrl ..."
            Invoke-WebRequest -Uri $TagUrl -OutFile $tarPath
        }
    }

    Write-Host "Extracting source to $WorkRoot ..."
    if (Test-Path $SrcDir) {
        Remove-Item -Recurse -Force $SrcDir
    }
    Push-Location $WorkRoot
    try {
        & tar.exe -xf $tarPath
        if ($LASTEXITCODE -ne 0) {
            throw "tar extract failed with exit $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
    if (-not (Test-Path (Join-Path $SrcDir "configure"))) {
        throw "configure not found after extract: $SrcDir"
    }
}

function Invoke-MsysBash {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$LogPath = ""
    )
    if (-not (Test-Path $MsysBash)) {
        throw "MSYS2 bash not found: $MsysBash"
    }

    # Windows PATH (VsDevShell 済み) を MSYS に引き継ぎ、MSVC の link/cl を優先させる。
    $env:MSYS2_PATH_TYPE = "inherit"
    #
    # ★ MSYS2 path 自動変換について (justfile と同じく抑止する):
    #   MSYS2_ARG_CONV_EXCL=* / MSYS_NO_PATHCONV=1 を立てたままにする。
    #   in-tree でも --prefix は C:/... で渡す。変換を有効にするとそのパスが
    #   化けて install 先が狂う。justfile と同様、ここでは外さない。
    $env:MSYS2_ARG_CONV_EXCL = "*"
    $env:MSYS_NO_PATHCONV = "1"

    $bashArgs = @("-lc", $Command)
    Write-Host "---- msys bash ----"
    Write-Host $Command
    Write-Host "-------------------"

    if ($LogPath) {
        Ensure-Dir (Split-Path $LogPath -Parent)
        # パイプラインだと native exit code が消えることがあるので先に受ける。
        $output = & $MsysBash @bashArgs 2>&1
        $exitCode = $LASTEXITCODE
        $output | Tee-Object -FilePath $LogPath | Out-Host
    } else {
        & $MsysBash @bashArgs
        $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0) {
        throw "MSYS bash command failed with exit $exitCode"
    }
}

function Build-FFmpeg {
    Ensure-Dir $PrefixDir
    Ensure-Dir $LogDir

    if (Test-Path $PrefixDir) {
        Remove-Item -Recurse -Force $PrefixDir
    }
    Ensure-Dir $PrefixDir

    # ★ in-tree 必須 (doc/platform.texi / MSVC 節)。
    # out-of-tree だと configure が SRC_PATH を /c/... 絶対パスに正規化し、
    # make → cl が D8043 になる (2026-08-17 で二度確認)。ソースで ./configure すると
    # SRC_PATH=. になり相対パスだけが cl に渡る。
    $srcWin = ConvertTo-WinFwdPath $SrcDir
    # --prefix は Windows 形式でよい (make install 先。cl のソース引数ではない)。
    $prefixWin = ConvertTo-WinFwdPath $PrefixDir

    $cfg = @()
    foreach ($a in $ConfigureArgs) {
        if ($a -eq "--prefix=PREFIX_PLACEHOLDER") {
            $cfg += "--prefix=$prefixWin"
        } else {
            $cfg += $a
        }
    }
    $cfgLine = ($cfg -join " ")

    # 実ビルドは実パスの --prefix。ORIGIN / NOTICE / 公開用 config.h には汎用形だけ書く
    # (ローカルユーザ名・worktree パスを公開成果物に焼き付けない #321)。
    $script:ConfigureLineBuild = "./configure $cfgLine"
    $script:ConfigureLine = "./configure --toolchain=msvc --prefix=<prefix> --enable-shared --disable-static --disable-programs --disable-doc --disable-debug"
    $script:PrefixWinForBuild = $prefixWin

    $nJobs = $Jobs
    if ($nJobs -le 0) {
        $nJobs = [Math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS)
    }

    # mingw64 の nasm を PATH 先頭へ。/usr/bin/link より先に MSVC の Hostx64/x64 を置く。
    # PATH 要素だけは bash 向けに MSYS 形式でよい (which 用。cl へのソース引数ではない)。
    $msvcLinkDir = Split-Path (Get-Command link.exe).Source -Parent
    $msvcLinkDirMsys = ConvertTo-MsysPath $msvcLinkDir
    $nasmDirMsys = "/c/msys64/mingw64/bin"

    $pathExport = "export PATH=`"${msvcLinkDirMsys}:${nasmDirMsys}:/usr/bin:/bin`""

    $verNum = $FFmpegTag -replace '^n', ''
    $configureScript = @"
set -euo pipefail
$pathExport
export GIT_CEILING_DIRECTORIES="$srcWin"
# 親の wonder_flow git を掴んで ffversion が probe-v... になるのを防ぐ (#321)
export revision="$verNum"
echo "forced revision=$verNum"
echo "which cl:   `$(which cl || true)"
echo "which link: `$(which link || true)"
echo "which nasm: `$(which nasm || true)"
echo "which make: `$(which make || true)"
echo "which diff: `$(which diff || true)"
cl 2>&1 | head -n 1 || true
link 2>&1 | head -n 1 || true
nasm -v
test -x "`$(which cl)"
test -x "`$(which link)"
test -x "`$(which nasm)"
# MSYS の link が掴まれていないこと
case "`$(which link)" in
  */usr/bin/link|*/bin/link) echo "ERROR: MSYS link.exe is first on PATH"; exit 1 ;;
esac
case "$prefixWin" in
  [A-Za-z]:/*) ;;
  *) echo "ERROR: prefix path must be Windows form C:/..., got: $prefixWin"; exit 1 ;;
esac
# 公開用: ユーザホーム配下の prefix / ソースは拒否 (DLL・__FILE__ に焼き付く)
case "$prefixWin" in
  *[Uu]sers/*|*/home/*|*/.herdr/*|*worktrees*) echo "ERROR: --prefix must not contain Users/home/.herdr/worktrees: $prefixWin"; exit 1 ;;
esac
case "$srcWin" in
  *[Uu]sers/*|*/home/*|*/.herdr/*|*worktrees*) echo "ERROR: source path must not contain Users/home/.herdr/worktrees: $srcWin"; exit 1 ;;
esac
cd "$srcWin"
# 前回の in-tree 残骸があれば消す (使い捨てソース前提)
if [ -f ffbuild/config.mak ] || [ -f config.mak ]; then
  make distclean || true
fi
echo "configure (in-tree, build): $($script:ConfigureLineBuild)"
echo "configure (recorded public): $($script:ConfigureLine)"
echo "cwd=`$(pwd -W 2>/dev/null || pwd) prefix=$prefixWin"
./configure $cfgLine
# 自己点検: source path が '.' であること (絶対 /c/... なら out-of-tree 化している)
if grep -q '^SRC_PATH=\.$' ffbuild/config.mak 2>/dev/null || grep -q '^SRC_PATH=\.$' config.mak 2>/dev/null; then
  echo "SRC_PATH=. (in-tree OK)"
else
  echo "ERROR: SRC_PATH is not '.' — in-tree configure failed to stick"
  grep -E '^SRC_PATH=' ffbuild/config.mak config.mak 2>/dev/null || true
  exit 1
fi
"@

    Invoke-MsysBash -Command $configureScript -LogPath $ConfigureLog

    # PowerShell 側で version.sh を差し替え (bash heredoc のエスケープ事故を避ける)
    Install-PinnedVersionSh -SrcDir $SrcDir -Version $verNum

    $makeScript = @"
set -euo pipefail
$pathExport
cd "$srcWin"
export revision="$verNum"
export GIT_CEILING_DIRECTORIES="$srcWin"
ver=`$(./ffbuild/version.sh .)`
echo "FFmpeg version.sh => `$ver"
test "`$ver" = "$verNum"
make -j$nJobs
"@
    Invoke-MsysBash -Command $makeScript -LogPath $MakeLog

    $installScript = @"
set -euo pipefail
$pathExport
cd "$srcWin"
export revision="$verNum"
export GIT_CEILING_DIRECTORIES="$srcWin"
make install
"@
    Invoke-MsysBash -Command $installScript -LogPath $InstallLog
}

function Install-PinnedVersionSh {
    param(
        [string]$SrcDir,
        [string]$Version
    )
    $path = Join-Path $SrcDir "ffbuild\version.sh"
    $bak = Join-Path $SrcDir "ffbuild\version.sh.upstream.bak"
    if ((Test-Path $path) -and -not (Test-Path $bak)) {
        Copy-Item $path $bak -Force
    }
    $body = @"
#!/bin/sh
# Forced by build-ffmpeg-8.1-lgpl.ps1 — pin FFMPEG_VERSION (no git describe).
version=$Version
if [ -z "`$2" ]; then
  echo "`$version"
  exit 0
fi
cat > "`$2" <<EOF
/* Forced by build-ffmpeg-8.1-lgpl.ps1 (no git describe) */
#ifndef AVUTIL_FFVERSION_H
#define AVUTIL_FFVERSION_H
#define FFMPEG_VERSION "$Version"
#endif /* AVUTIL_FFVERSION_H */
EOF
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, ($body -replace "`r`n", "`n"), $utf8)
    $ffver = Join-Path $SrcDir "libavutil\ffversion.h"
    $hdr = @"
/* Forced by build-ffmpeg-8.1-lgpl.ps1 (no git describe) */
#ifndef AVUTIL_FFVERSION_H
#define AVUTIL_FFVERSION_H
#define FFMPEG_VERSION "$Version"
#endif /* AVUTIL_FFVERSION_H */
"@
    [System.IO.File]::WriteAllText($ffver, ($hdr -replace "`r`n", "`n"), $utf8)
    Write-Host "Pinned ffbuild/version.sh and libavutil/ffversion.h to $Version"
}

function Install-VendorLayout {
    $prefixBin = Join-Path $PrefixDir "bin"
    $prefixLib = Join-Path $PrefixDir "lib"
    $incSrc = Join-Path $PrefixDir "include"
    $licSrc = Join-Path $SrcDir "COPYING.LGPLv2.1"

    foreach ($p in @($prefixBin, $incSrc, $licSrc)) {
        if (-not (Test-Path $p)) {
            throw "Expected build output missing: $p"
        }
    }

    # ★ MSVC --toolchain=msvc の make install 配置 (2026-08-17 実測 / #321):
    #   prefix/bin/  … *.dll と *.lib が同居する
    #   prefix/lib/  … *.def と pkgconfig のみ (.lib は無い)
    # BtbN / wonder_flow vendor 規約は bin/*.dll + lib/*.lib なのでここで整形する。
    # (.dll.a を .lib に改名する話ではない。本物の MSVC インポートライブラリを移すだけ。)
    $dlls = @()
    foreach ($pat in @(
            "avcodec-*.dll", "avdevice-*.dll", "avfilter-*.dll", "avformat-*.dll",
            "avutil-*.dll", "swresample-*.dll", "swscale-*.dll"
        )) {
        $hit = Get-ChildItem -Path $prefixBin -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hit) { throw "Missing DLL matching $pat under $prefixBin" }
        $dlls += $hit
    }

    $requiredLibs = @("avcodec.lib", "avdevice.lib", "avfilter.lib", "avformat.lib", "avutil.lib", "swresample.lib", "swscale.lib")
    $libs = @()
    foreach ($name in $requiredLibs) {
        $p = Join-Path $prefixBin $name
        if (-not (Test-Path $p)) {
            throw "Missing import lib in prefix/bin (MSVC install layout): $p"
        }
        $libs += Get-Item $p
    }

    Ensure-Dir $VendorDir
    if (Test-Path $FFmpegDir) {
        Write-Host "Removing previous $FFmpegDir ..."
        Remove-Item -Recurse -Force $FFmpegDir
    }
    $destBin = Join-Path $FFmpegDir "bin"
    $destLib = Join-Path $FFmpegDir "lib"
    Ensure-Dir $destBin
    Ensure-Dir $destLib

    foreach ($dll in $dlls) {
        Copy-Item $dll.FullName (Join-Path $destBin $dll.Name) -Force
    }
    foreach ($lib in $libs) {
        Copy-Item $lib.FullName (Join-Path $destLib $lib.Name) -Force
    }
    # .def は BtbN 版と同様 lib/ にあれば便利。あれば移す。
    if (Test-Path $prefixLib) {
        Get-ChildItem $prefixLib -Filter "*.def" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $destLib $_.Name) -Force
        }
    }
    Copy-Item -Recurse $incSrc (Join-Path $FFmpegDir "include")
    # ★ LICENSE は必ず LGPLv2.1 全文。BtbN vendor の v3 LICENSE.txt を流用しない。
    Copy-Item $licSrc (Join-Path $FFmpegDir "LICENSE.txt")

    if (-not $script:ConfigureLine) {
        # -PackageOnly / 再パッケージ時: 公開記録形を固定 (実パスを ORIGIN に書かない)
        $script:ConfigureLine = "./configure --toolchain=msvc --prefix=<prefix> --enable-shared --disable-static --disable-programs --disable-doc --disable-debug"
    }

    # configure 結果の証拠 (programs 無しでも configuration / hwaccel を追える)。
    # 公開 zip 向けにローカル絶対パスを scrub する (#321)。
    $configH = Join-Path $SrcDir "config.h"
    $destConfigH = Join-Path $FFmpegDir "config.h"
    if (Test-Path $configH) {
        $cfgRaw = Get-Content $configH -Raw
        $cfgRaw = Scrub-LocalPathsInText -Text $cfgRaw
        $utf8NoBomCfg = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($destConfigH, $cfgRaw, $utf8NoBomCfg)
    }
    # configure.log は cwd/prefix の絶対パスを含むので vendor 公開物には入れない。
    # ローカル診断用は $LogDir に残る。

    # in-tree だと version.sh が親リポの git describe を掴むことがある → タグ版に直す
    $ffver = Join-Path $FFmpegDir "include\libavutil\ffversion.h"
    if (Test-Path $ffver) {
        $verNum = $FFmpegTag -replace '^n', ''
        $ffverBody = @"
#ifndef AVUTIL_FFVERSION_H
#define AVUTIL_FFVERSION_H
#define FFMPEG_VERSION `"$verNum`"
#endif /* AVUTIL_FFVERSION_H */
"@
        $utf8NoBomVer = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ffver, $ffverBody.Replace("`r`n", "`n"), $utf8NoBomVer)
    }

    $originLines = @(
        "# Written by scripts/build-ffmpeg-8.1-lgpl.ps1 — do not hand-edit.",
        "kind=selfbuild",
        "ffmpeg_tag=$FFmpegTag",
        "ffmpeg_tag_url=$TagBrowseUrl",
        "ffmpeg_tarball_url=$TagUrl",
        "builds_release_url=https://github.com/TTI-DCS/ffmpeg-lgpl-builds/releases/tag/$FFmpegTag",
        "license=LGPLv2.1+",
        "configure=$script:ConfigureLine"
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines((Join-Path $FFmpegDir "ORIGIN.txt"), $originLines, $utf8NoBom)

    Write-Host "Installed vendor at $FFmpegDir (bin=DLL, lib=import .lib from prefix/bin)"
}

function Scrub-LocalPathsInText {
    param([string]$Text)
    # --prefix='C:/Users/...' / --prefix=C:/Users/... → --prefix='<prefix>'
    $Text = [regex]::Replace($Text, "--prefix='[^']*'", "--prefix='<prefix>'")
    $Text = [regex]::Replace($Text, '--prefix="[^"]*"', '--prefix="<prefix>"')
    $Text = [regex]::Replace($Text, '--prefix=(?!<prefix>)(?:[A-Za-z]:)?[^\s"'']+', '--prefix=<prefix>')
    # FFMPEG_DATADIR / AVCONV_DATADIR
    $Text = [regex]::Replace($Text, '(#define\s+(?:FFMPEG_DATADIR|AVCONV_DATADIR)\s+")[^"]+(")', '${1}<prefix>/share/ffmpeg${2}')
    # 残余のユーザホーム / herdr worktree (保険)
    $Text = [regex]::Replace($Text, '(?i)[A-Za-z]:/(?:Users|home)/[^\s"'']+', '<local-path>')
    $Text = [regex]::Replace($Text, '(?i)\\Users\\[^\s"'']+', '<local-path>')
    return $Text
}

function Test-VendorComplete {
    $checks = @(
        (Join-Path $FFmpegDir "lib\avcodec.lib"),
        (Join-Path $FFmpegDir "include\libavcodec\avcodec.h"),
        (Join-Path $FFmpegDir "include\libavutil\hwcontext_d3d12va.h"),
        (Join-Path $FFmpegDir "LICENSE.txt"),
        (Join-Path $FFmpegDir "ORIGIN.txt")
    )
    foreach ($c in $checks) {
        if (-not (Test-Path $c)) {
            throw "Post-install missing: $c"
        }
    }
    $dll = Get-ChildItem (Join-Path $FFmpegDir "bin") -Filter "avcodec-*.dll" | Select-Object -First 1
    if (-not $dll) { throw "Post-install missing avcodec-*.dll" }

    $licHead = Get-Content (Join-Path $FFmpegDir "LICENSE.txt") -TotalCount 3
    $licText = $licHead -join "`n"
    if ($licText -notmatch 'Version 2\.1') {
        throw "LICENSE.txt does not look like LGPLv2.1 (head: $licText)"
    }

    if (Test-Path (Join-Path $FFmpegDir "config.h")) {
        $cfg = Get-Content (Join-Path $FFmpegDir "config.h") -Raw
        if ($cfg -match '--enable-gpl\b') { throw "config.h contains --enable-gpl" }
        if ($cfg -match '--enable-version3\b') { throw "config.h contains --enable-version3" }
        if ($cfg -match '--enable-nonfree\b') { throw "config.h contains --enable-nonfree" }
        if ($cfg -notmatch 'FFMPEG_CONFIGURATION') {
            throw "config.h missing FFMPEG_CONFIGURATION"
        }
        if ($cfg -match '(?i)C:/Users/|(?i)\\Users\\|(?i)sho1i|(?i)\.herdr') {
            throw "config.h still contains local path/user — scrub before publish"
        }
    }
    $originTxt = Get-Content (Join-Path $FFmpegDir "ORIGIN.txt") -Raw
    if ($originTxt -match '(?i)C:/Users/|(?i)\\Users\\|(?i)sho1i|(?i)\.herdr') {
        throw "ORIGIN.txt still contains local path/user"
    }
    if ($originTxt -notmatch '--prefix=<prefix>') {
        throw "ORIGIN.txt configure line must use generic --prefix=<prefix>"
    }

    Write-Host "Vendor verification OK ($($dll.Name))"
}

Write-Host "=== build-ffmpeg-8.1-lgpl.ps1 ==="
Write-Host "  Tag:       $FFmpegTag"
Write-Host "  VendorDir: $VendorDir"
Write-Host "  Output:    $FFmpegDir"
Write-Host "  WorkRoot:  $WorkRoot"

# 安全: 既存 BtbN ツリーを dest に指定していないこと
$forbidden = Join-Path $VendorDir "ffmpeg-windows-8.1"
if ([System.IO.Path]::GetFullPath($FFmpegDir) -eq [System.IO.Path]::GetFullPath($forbidden)) {
    throw "Refusing to overwrite vendor/ffmpeg-windows-8.1 (BtbN). Use a different -DirName."
}

if (-not $PackageOnly) {
    Import-VsDevEnvironment
    Get-FFmpegSource
    Build-FFmpeg
} else {
    if (-not (Test-Path (Join-Path $PrefixDir "bin"))) {
        throw "-PackageOnly requires existing prefix at $PrefixDir"
    }
    if (-not (Test-Path (Join-Path $SrcDir "COPYING.LGPLv2.1"))) {
        throw "-PackageOnly requires existing source at $SrcDir (for COPYING.LGPLv2.1 / config.h)"
    }
    Write-Host "PackageOnly: skipping configure/make, packaging from $PrefixDir"
}
Install-VendorLayout
Test-VendorComplete

# ★ ソース削除は受け入れ検証 (cargo check 等) の後。このスクリプト単体では
#   vendor 配置検証まで。フル受け入れ後に -RemoveSource で消す。
if ($RemoveSource) {
    Write-Host "Removing disposable FFmpeg source tree: $SrcDir"
    if (Test-Path $SrcDir) {
        Remove-Item -Recurse -Force $SrcDir
    }
    if (Test-Path $PrefixDir) {
        Remove-Item -Recurse -Force $PrefixDir
    }
    $legacyBuild = Join-Path $WorkRoot "build"
    if (Test-Path $legacyBuild) {
        Remove-Item -Recurse -Force $legacyBuild
    }
}

Write-Host "DONE. Point FFMPEG_DIR at: $FFmpegDir"
Write-Host "Configure line: $script:ConfigureLine"
Write-Host "Logs: $LogDir"

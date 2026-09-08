# FFmpeg 8.1 を MSVC toolchain で自前ビルドし、LGPL v2.1+ の shared vendor を作る (#321)。
#
# ⚠ BtbN の win64-lgpl-shared は --enable-version3 付き (= LGPL v3)。v2.1 にするには自前ビルドが必要。
# ⚠ ffmpeg-sys-next は MSVC でリンクするので .lib が要る → 必ず --toolchain=msvc。
#    MinGW で出る .dll.a を .lib に改名する回避はしない。
# ⚠ 既存の vendor/ffmpeg-windows-8.1 (BtbN) は触らない。別ディレクトリへ入れる。
# ⚠ --enable-gpl / --enable-version3 / --enable-nonfree は付けない。
# ⚠ --disable-everything でコーデックを絞らない。
#
# 消費者は wonder_flow・loopeek・kinocore の3つで、全員がこの1ビルドにリンクする。
# 外部ライブラリは snappy (BSD-3-Clause) と zlib (Zlib) の2つだけで、どちらも
# avcodec へ静的リンクされる。したがって**この DLL の対応ソースに両者が含まれる** —
# LGPL の corresponding source として、FFmpeg のソース tarball と一緒に snappy と
# zlib の tarball も同じ Release へ添付すること (LICENSE-NOTES.md 参照)。
#
# ⚠ CLI (ffmpeg.exe / ffprobe.exe) も配る。loopeek の変換・解析はこれを外部プロセス
#    として起動する構造なので、--disable-programs を戻すとその機能が丸ごと死ぬ。
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
    # 外部ライブラリ。どちらも avcodec へ静的リンクされ、対応ソースは同じ Release に
    # 添付する (LGPL の corresponding source に含まれるため)。
    #   snappy → HAP エンコーダ    (configure: hap_encoder_deps="libsnappy")
    #   zlib   → PNG / EXR エンコーダ (png_encoder_select="deflate_wrapper" →
    #            deflate_wrapper_deps="zlib" / exr_encoder_deps="zlib")
    [string]$SnappyVersion = "1.2.2",
    [string]$ZlibVersion = "1.3.1",
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

# 外部ライブラリの prefix。ここも configuration 文字列として DLL に焼き付くので
# ユーザ名を含めない中立パスにし、公開物では <deps> に scrub する。
$DepsDir = if ($env:WONDER_FFMPEG_BUILD_DEPS) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:WONDER_FFMPEG_BUILD_DEPS)
} else {
    "C:\ffmpeg-build\deps"
}

$TagUrl = "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FFmpegTag.tar.gz"
$TagBrowseUrl = "https://github.com/FFmpeg/FFmpeg/tree/$FFmpegTag"
$SnappyTarUrl = "https://github.com/google/snappy/archive/refs/tags/$SnappyVersion.tar.gz"
$ZlibTarUrl = "https://github.com/madler/zlib/archive/refs/tags/v$ZlibVersion.tar.gz"

# 指示書どおりの configure フラグ (gpl / version3 / nonfree / disable-everything は付けない)
#
# ★ --disable-programs を外してある。ffmpeg / ffprobe の CLI は loopeek が変換と
#   解析に使う。ffplay だけは SDL2 依存が増えるうえ誰も使わないので落とす。
# ★ --extra-ldflags は -L ではなく -libpath: を渡すこと。configure:4440 が
#   ldflags_filter を素通しの echo で初期化し、--extra-ldflags を処理する
#   configure:4624 はまだその素通しを使う。MSVC 用フィルタが入るのは
#   configure:5467 と後なので、-L → -libpath: の変換 (configure:5136) が
#   間に合わず LNK4044 → LNK1181 になる。--extra-cflags の -I は MSVC が
#   直接解釈するので影響を受けない。
# ★ --pkg-config=false は必須である (2026-09-08 に実測で踏んだ)。
#   PATH には nasm のために /c/msys64/mingw64/bin が載っており、そこには pkgconf と
#   MSYS2 の .pc 一式がある。configure:7185 は zlib をまず pkg-config で探すので、
#   放っておくと **MinGW の zlib** を掴む:
#       CFLAGS  += -IC:/msys64/mingw64/bin/../include
#       EXTRALIBS += -libpath:C:/msys64/mingw64/bin/../lib zlib.lib
#   その include パスに入る MinGW の math.h は `__asm__` を使うので cl が C2065 で
#   落ちる (libavdevice/avdevice.o)。pkg-config を止めると configure:7186 の
#   check_lib へフォールバックし、-lz が zlib.lib に変換されて下の -libpath: で
#   解決される。libsnappy は require = check_lib なので元から pkg-config を通らない。
#
#   これは「MSVC ビルドが見る外部ライブラリは、ここで明示的に渡した2つだけ」という
#   ことを保証する意味も持つ。MSYS2 のライブラリを1つでも自動検出すると、MinGW の
#   成果物が MSVC の DLL に混入する。
$ConfigureArgs = @(
    "--toolchain=msvc",
    "--prefix=PREFIX_PLACEHOLDER",
    "--pkg-config=false",
    "--enable-shared",
    "--disable-static",
    "--disable-doc",
    "--disable-debug",
    "--disable-ffplay",
    "--enable-libsnappy",
    "--enable-zlib",
    "--extra-cflags=-IDEPS_PLACEHOLDER/include",
    "--extra-ldflags=-libpath:DEPS_PLACEHOLDER/lib"
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

function Resolve-CMake {
    # VS 同梱を優先する。PATH 上の cmake がどれかは機械によって変わるため。
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
            Select-Object -First 1
        if ($vsPath) {
            $bundled = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
            if (Test-Path $bundled) { return $bundled }
        }
    }
    $cmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "cmake.exe not found (neither bundled with Visual Studio nor on PATH). Install the 'C++ CMake tools for Windows' component."
}

function Get-TarballSource {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$SrcPath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (Test-Path (Join-Path $SrcPath "CMakeLists.txt")) {
        Write-Host "Using existing $Label source: $SrcPath"
        return
    }
    Ensure-Dir $WorkRoot
    $tar = Join-Path $WorkRoot ("{0}-{1}" -f $Label, [System.IO.Path]::GetFileName($Url))
    if (-not (Test-Path $tar)) {
        Write-Host "Downloading $Url ..."
        Invoke-WebRequest -Uri $Url -OutFile $tar
    }
    Write-Host "Extracting $Label to $WorkRoot ..."
    Push-Location $WorkRoot
    try {
        & tar.exe -xf $tar
        if ($LASTEXITCODE -ne 0) { throw "tar extract failed for $Label with exit $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
    if (-not (Test-Path (Join-Path $SrcPath "CMakeLists.txt"))) {
        throw "CMakeLists.txt not found after extracting ${Label}: $SrcPath"
    }
}

# snappy と zlib を MSVC で静的ビルドし、$DepsDir に FFmpeg が期待する名前で置く。
#
# ★ ライブラリ名が要点である。configure:5134 の msvc_common_flags が -lsnappy を
#   snappy.lib に、configure:5131 が -lz を zlib.lib に変換するので、その名前で
#   見つかる必要がある。zlib の CMake は zlib.lib という名前で *zlib.dll の
#   インポートライブラリ* も作るため、素直に install すると動的リンクになり
#   zlib.dll の同梱が要る。静的な zlibstatic.lib をその名前で置き直す。
#
# ★ configure:7372 は require libsnappy ... -lsnappy -lstdc++ だが、
#   configure:5133 が MSVC のとき -lstdc++ を捨てる。C++ ランタイムは snappy.lib の
#   デフォルトライブラリ指令から MSVC が自動解決するので、明示的な指定は要らない。
function Build-Dependencies {
    $cmake = Resolve-CMake
    Write-Host "cmake: $cmake"

    $snappySrc = Join-Path $WorkRoot "snappy-$SnappyVersion"
    $zlibSrc = Join-Path $WorkRoot "zlib-$ZlibVersion"
    Get-TarballSource -Url $SnappyTarUrl -SrcPath $snappySrc -Label "snappy"
    Get-TarballSource -Url $ZlibTarUrl -SrcPath $zlibSrc -Label "zlib"

    if (Test-Path $DepsDir) { Remove-Item -Recurse -Force $DepsDir }
    Ensure-Dir (Join-Path $DepsDir "lib")
    Ensure-Dir (Join-Path $DepsDir "include")

    # ---- snappy: そのまま install すれば snappy.lib になる ----
    $snappyBuild = Join-Path $WorkRoot "snappy-build"
    if (Test-Path $snappyBuild) { Remove-Item -Recurse -Force $snappyBuild }
    Write-Host "==> Building snappy $SnappyVersion (MSVC, static)"
    & $cmake -S $snappySrc -B $snappyBuild -G "Visual Studio 17 2022" -A x64 `
        "-DCMAKE_INSTALL_PREFIX=$DepsDir" `
        -DSNAPPY_BUILD_TESTS=OFF `
        -DSNAPPY_BUILD_BENCHMARKS=OFF `
        -DBUILD_SHARED_LIBS=OFF `
        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
    if ($LASTEXITCODE -ne 0) { throw "snappy cmake configure failed" }
    & $cmake --build $snappyBuild --config Release --target install
    if ($LASTEXITCODE -ne 0) { throw "snappy build/install failed" }

    # ---- zlib: staging へ入れて、静的なほうを zlib.lib として採る ----
    $zlibBuild = Join-Path $WorkRoot "zlib-build"
    $zlibStage = Join-Path $WorkRoot "zlib-stage"
    foreach ($d in @($zlibBuild, $zlibStage)) {
        if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    }
    Write-Host "==> Building zlib $ZlibVersion (MSVC)"
    & $cmake -S $zlibSrc -B $zlibBuild -G "Visual Studio 17 2022" -A x64 `
        "-DCMAKE_INSTALL_PREFIX=$zlibStage" `
        -DZLIB_BUILD_EXAMPLES=OFF `
        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
    if ($LASTEXITCODE -ne 0) { throw "zlib cmake configure failed" }
    & $cmake --build $zlibBuild --config Release --target install
    if ($LASTEXITCODE -ne 0) { throw "zlib build/install failed" }

    $zlibStatic = Join-Path $zlibStage "lib\zlibstatic.lib"
    if (-not (Test-Path $zlibStatic)) {
        throw "zlibstatic.lib not produced (looked in $zlibStatic). A dynamic zlib.lib would make FFmpeg depend on zlib.dll."
    }
    Copy-Item $zlibStatic (Join-Path $DepsDir "lib\zlib.lib") -Force
    foreach ($h in @("zlib.h", "zconf.h")) {
        Copy-Item (Join-Path $zlibStage "include\$h") (Join-Path $DepsDir "include\$h") -Force
    }

    # ★ zconf.h の HAVE_UNISTD_H ブロックを塞ぐ (2026-09-08 に実測で踏んだ)。
    #
    #   zconf.h:438 は `#ifdef HAVE_UNISTD_H` で Z_HAVE_UNISTD_H を立てる。FFmpeg の
    #   config.h は `#define HAVE_UNISTD_H 0` と **値 0 で定義する**ので #ifdef は真に
    #   なり、zconf.h が <unistd.h> を include して MSVC が C1083 で死ぬ
    #   (libavformat/http.o)。
    #
    #   単なるコンパイルエラーではなく ABI の不一致でもある。zlib.lib 自身は CMake が
    #   生成した zconf.h (`/* #undef Z_HAVE_UNISTD_H */`) で、かつ HAVE_UNISTD_H 未定義
    #   でコンパイルされている = Z_HAVE_UNISTD_H は off。消費者側だけ on になると
    #   z_off_t が off_t に変わり、ライブラリの実体と食い違う。off に固定するのは
    #   **ヘッダを実際のビルドに合わせる**修正である。
    #
    #   この行を書き換えること自体は zlib 自身の ./configure がやるのと同じ機構で
    #   (あちらは `#if 1` にする)、値の選択だけが逆である。patch した zconf.h は
    #   ビルド入力にしか使わない — Install-VendorLayout が公開 zip に入れるのは
    #   $PrefixDir/include (FFmpeg のヘッダ) だけで、deps の include は入らない。
    #
    #   すぐ下の HAVE_STDARG_H ブロックは塞がない。FFmpeg は HAVE_STDARG_H を定義せず、
    #   かつ zconf.h:452 が `#if defined(STDC) || defined(Z_HAVE_STDARG_H)` なので
    #   どちらでも結果が変わらない。
    $zconf = Join-Path $DepsDir "include\zconf.h"
    $needle = '#ifdef HAVE_UNISTD_H    /* may be set to #if 1 by ./configure */'
    $zconfText = [System.IO.File]::ReadAllText($zconf)
    if (-not $zconfText.Contains($needle)) {
        throw "zconf.h does not contain the expected HAVE_UNISTD_H guard verbatim; zlib $ZlibVersion may have changed it. Re-check before assuming this patch is still needed."
    }
    $zconfText = $zconfText.Replace(
        $needle,
        '#if 0    /* forced off by build-ffmpeg-8.1-lgpl.ps1: MSVC has no unistd.h, and zlib.lib was compiled with Z_HAVE_UNISTD_H off */')
    [System.IO.File]::WriteAllText($zconf, $zconfText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  patched zconf.h: HAVE_UNISTD_H guard forced off"

    foreach ($required in @("lib\snappy.lib", "lib\zlib.lib", "include\snappy-c.h", "include\zlib.h")) {
        $p = Join-Path $DepsDir $required
        if (-not (Test-Path $p)) { throw "Dependency prefix incomplete: $p" }
    }
    Write-Host "Dependencies ready at $DepsDir"
    Get-ChildItem (Join-Path $DepsDir "lib") -Filter *.lib |
        ForEach-Object { Write-Host ("    lib\{0}  ({1} bytes)" -f $_.Name, $_.Length) }
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
    $depsWin = ConvertTo-WinFwdPath $DepsDir

    # 実ビルド用と公開記録用を同じ配列から作る。以前は公開用の文字列を別に
    # 書き下していたので、フラグを足すたびに両者がずれる余地があった。
    $cfg = @()
    $pub = @()
    foreach ($a in $ConfigureArgs) {
        $cfg += $a.Replace("PREFIX_PLACEHOLDER", $prefixWin).Replace("DEPS_PLACEHOLDER", $depsWin)
        $pub += $a.Replace("PREFIX_PLACEHOLDER", "<prefix>").Replace("DEPS_PLACEHOLDER", "<deps>")
    }
    $cfgLine = ($cfg -join " ")

    # 実ビルドは実パスの --prefix。ORIGIN / NOTICE / 公開用 config.h には汎用形だけ書く
    # (ローカルユーザ名・worktree パスを公開成果物に焼き付けない #321)。
    $script:ConfigureLineBuild = "./configure $cfgLine"
    $script:ConfigureLine = "./configure " + ($pub -join " ")
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

    # CLI。loopeek が変換・解析・プロキシ生成に使う。隣の DLL に動的リンクしている
    # ので bin/ に DLL と同居させる。ffplay は --disable-ffplay で作られない。
    foreach ($exe in @("ffmpeg.exe", "ffprobe.exe")) {
        $src = Join-Path $prefixBin $exe
        if (-not (Test-Path $src)) {
            throw "Missing CLI in prefix/bin: $src (--disable-programs must not be set)"
        }
        Copy-Item $src (Join-Path $destBin $exe) -Force
    }
    if (Test-Path (Join-Path $prefixBin "ffplay.exe")) {
        throw "ffplay.exe was built; --disable-ffplay is missing from the configure line"
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
        $pubOnly = @()
        foreach ($a in $ConfigureArgs) {
            $pubOnly += $a.Replace("PREFIX_PLACEHOLDER", "<prefix>").Replace("DEPS_PLACEHOLDER", "<deps>")
        }
        $script:ConfigureLine = "./configure " + ($pubOnly -join " ")
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
        # 外部ライブラリは avcodec へ静的リンクされるので、この DLL の対応ソースに
        # 含まれる。どちらも同じ Release にソース tarball を添付すること。
        "snappy_version=$SnappyVersion",
        "snappy_tarball_url=$SnappyTarUrl",
        "snappy_license=BSD-3-Clause",
        "zlib_version=$ZlibVersion",
        "zlib_tarball_url=$ZlibTarUrl",
        "zlib_license=Zlib",
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
    # 外部ライブラリの prefix も configuration 文字列に載る。--prefix と同じ扱いで
    # 汎用形にする (既定は中立パスなのでユーザ名は載らないが、-DepsDir を差し替えた
    # ときに漏れないようにする)。
    $depsFwd = ConvertTo-WinFwdPath $DepsDir
    $Text = $Text.Replace($depsFwd, '<deps>')
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

    Test-CodecCoverage
    Write-Host "Vendor verification OK ($($dll.Name))"
}

# 消費者が実際に要求するものが揃っているかを、ビルドした CLI に訊いて確かめる。
#
# config.h の CONFIG_* を読むだけでは足りない。外部ライブラリのリンクが外れていても
# ヘッダは残りうるし、逆に configure が黙って機能を落としていても気付けない。
# ここで落ちるということは、その Release を出しても消費者側で機能が欠ける。
#
#   hap            loopeek の HAP / HapAlpha / HapQ 出力 (libsnappy)
#   png / exr      loopeek の画像シーケンス書き出し (zlib)
#   prores_ks      loopeek の ProRes 出力
#   h264_mf        loopeek の H.264 出力 (OS ネイティブ)
#   d3d11va        kinocore のゼロコピー再生経路
function Test-CodecCoverage {
    $ffmpeg = Join-Path $FFmpegDir "bin\ffmpeg.exe"
    if (-not (Test-Path $ffmpeg)) { throw "Post-install missing bin\ffmpeg.exe" }
    if (-not (Test-Path (Join-Path $FFmpegDir "bin\ffprobe.exe"))) {
        throw "Post-install missing bin\ffprobe.exe"
    }
    if (Test-Path (Join-Path $FFmpegDir "bin\ffplay.exe")) {
        throw "bin\ffplay.exe present; it must not be built"
    }

    $banner = & $ffmpeg -hide_banner -version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg.exe failed to run:`n$banner" }
    foreach ($bad in @('--enable-gpl', '--enable-version3', '--enable-nonfree')) {
        if ($banner -match [regex]::Escape($bad)) { throw "version banner contains $bad" }
    }
    foreach ($want in @('--enable-libsnappy', '--enable-zlib')) {
        if ($banner -notmatch [regex]::Escape($want)) { throw "version banner is missing $want" }
    }

    $encoders = & $ffmpeg -hide_banner -encoders 2>&1 | Out-String
    foreach ($enc in @('hap', 'png', 'exr', 'prores_ks', 'h264_mf', 'pcm_s16le')) {
        if ($encoders -notmatch "(?m)^\s*\S+\s+$([regex]::Escape($enc))\s") {
            throw "encoder missing: $enc"
        }
    }

    $decoders = & $ffmpeg -hide_banner -decoders 2>&1 | Out-String
    foreach ($dec in @('hap', 'notchlc', 'prores', 'prores_raw', 'h264', 'aac')) {
        if ($decoders -notmatch "(?m)^\s*\S+\s+$([regex]::Escape($dec))\s") {
            throw "decoder missing: $dec"
        }
    }

    $hwaccels = & $ffmpeg -hide_banner -hwaccels 2>&1 | Out-String
    if ($hwaccels -notmatch '(?m)^\s*d3d11va\s*$') {
        throw "d3d11va hwaccel missing (kinocore's zero-copy path needs it)"
    }

    # 静的リンクの確認。zlib.dll / snappy.dll に依存していたら、その DLL も配らねば
    # ならず、消費者の同梱物が静かに壊れる。
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($dumpbin) {
        $avcodec = Get-ChildItem (Join-Path $FFmpegDir "bin") -Filter "avcodec-*.dll" | Select-Object -First 1
        $deps = & $dumpbin.Source /dependents $avcodec.FullName 2>&1 | Out-String
        foreach ($bad in @('zlib', 'snappy')) {
            if ($deps -match "(?i)$bad[0-9]*\.dll") {
                throw "$($avcodec.Name) depends on a $bad DLL; the dependency must be linked statically"
            }
        }
    } else {
        Write-Host "  (dumpbin not on PATH; skipped the static-linkage check)"
    }

    # MinGW の成果物が混入していないこと。--pkg-config=false で塞いでいるが、
    # 一度実際に踏んでいるので結果側でも見る (banner は configuration 文字列を持つ)。
    if ($banner -match '(?i)msys64|mingw') {
        throw "version banner references MSYS2/MinGW paths; a MinGW library leaked into this MSVC build"
    }

    Write-Host "Codec coverage OK (hap/png/exr/prores_ks/h264_mf encoders, d3d11va)"
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
    Build-Dependencies
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

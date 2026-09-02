#!/bin/sh
# build-tigervnc-h264.sh - build the TigerVNC Windows viewer with the
# contrib/tigervnc-windows-h264 patch, on Windows, from Git Bash.
#
#   ./tools/build-tigervnc-h264.sh [<work-dir>] [--install <dir>]
#
# Needs MSYS2 at C:\msys64 (winget install -e --id MSYS2.MSYS2). Installs the
# MinGW-w64 toolchain and TigerVNC's dependencies with pacman, builds FLTK
# 1.3.9 from source (TigerVNC 1.16.2 refuses MSYS2's 1.4), clones TigerVNC
# v1.16.2, applies the patch, builds vncviewer, and copies the exe with the
# MinGW runtime DLLs it imports to the install dir (default:
# %LOCALAPPDATA%\Programs\TigerVNC-h264). Never touches C:\Program Files.
#
# Why: stock TigerVNC on Windows shows black for H.264 above 1080p; see
# contrib/tigervnc-windows-h264/README.md for the measurement and the fix.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PATCH="$ROOT/contrib/tigervnc-windows-h264/h264-win-decoder-limits.diff"
WORK="${1:-$ROOT/build/tigervnc-h264}"
INSTALL="$LOCALAPPDATA/Programs/TigerVNC-h264"
[ "${2:-}" = "--install" ] && INSTALL="${3:?--install needs a directory}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

MSYS_BASH=/c/msys64/usr/bin/bash.exe
[ -x "$MSYS_BASH" ] || die "MSYS2 not found at C:\\msys64 - run: winget install -e --id MSYS2.MSYS2"
[ -f "$PATCH" ] || die "patch missing: $PATCH"
command -v git >/dev/null || die "git (Windows) is needed for the clones"

mkdir -p "$WORK"
WORKW="$(cd "$WORK" && pwd)"
export MSYSTEM=MINGW64 CHERE_INVOKING=1
msys() { "$MSYS_BASH" -lc "export PATH=/mingw64/bin:\$PATH; cd '$WORKW'; $*"; }

echo ">> 1. MSYS2 packages"
msys 'pacman -Syu --noconfirm >/dev/null 2>&1 || true; pacman -Syu --noconfirm >/dev/null 2>&1 || true
      pacman -S --noconfirm --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja mingw-w64-x86_64-pkgconf mingw-w64-x86_64-libjpeg-turbo mingw-w64-x86_64-zlib mingw-w64-x86_64-pixman mingw-w64-x86_64-libpng >/dev/null
      gcc --version | head -1; cmake --version | head -1'
ok "toolchain present"

echo ">> 2. FLTK 1.3.9 (static, private prefix)"
if [ ! -f "$WORKW/fltk13/lib/libfltk.a" ]; then
    [ -d "$WORKW/fltk" ] || git clone -q --depth 1 --branch release-1.3.9 https://github.com/fltk/fltk "$WORKW/fltk"
    msys "cmake -G Ninja -S fltk -B build-fltk -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX='$WORKW/fltk13' -DOPTION_BUILD_SHARED_LIBS=OFF -DOPTION_USE_GL=OFF -DOPTION_BUILD_EXAMPLES=OFF -DFLTK_BUILD_TEST=OFF -DOPTION_USE_SYSTEM_LIBJPEG=ON -DOPTION_USE_SYSTEM_ZLIB=ON -DOPTION_USE_SYSTEM_LIBPNG=ON >/dev/null && cmake --build build-fltk --target install >/dev/null"
fi
ok "FLTK 1.3.9 at $WORKW/fltk13"

echo ">> 3. TigerVNC v1.16.2 + patch"
if [ ! -d "$WORKW/tigervnc" ]; then
    git clone -q --depth 1 --branch v1.16.2 https://github.com/TigerVNC/tigervnc "$WORKW/tigervnc" 2>/dev/null
fi
if git -C "$WORKW/tigervnc" apply --check "$PATCH" 2>/dev/null; then
    git -C "$WORKW/tigervnc" apply "$PATCH"
    ok "patch applied"
elif git -C "$WORKW/tigervnc" apply --reverse --check "$PATCH" 2>/dev/null; then
    ok "patch already applied"
else
    die "patch does not apply to $WORKW/tigervnc (wrong tag, or local edits)"
fi

echo ">> 4. build vncviewer"
msys "cmake -G Ninja -S tigervnc -B build-tigervnc -DCMAKE_BUILD_TYPE=Release -DBUILD_VIEWER=1 -DENABLE_H264=1 -DENABLE_NLS=0 -DENABLE_GNUTLS=0 -DENABLE_NETTLE=0 -DCMAKE_PREFIX_PATH='$WORKW/fltk13' -DFLTK_INCLUDE_DIR='$WORKW/fltk13/include' -DFLTK_BASE_LIBRARY='$WORKW/fltk13/lib/libfltk.a' -DFLTK_IMAGES_LIBRARY='$WORKW/fltk13/lib/libfltk_images.a' -DFLTK_FORMS_LIBRARY='$WORKW/fltk13/lib/libfltk_forms.a' >/dev/null && cmake --build build-tigervnc --target vncviewer 2>&1 | grep -E ' error|undefined' || true"
EXE="$WORKW/build-tigervnc/vncviewer/vncviewer.exe"
[ -f "$EXE" ] || die "vncviewer.exe was not produced - run the cmake steps by hand to see the error"
ok "built $EXE"

echo ">> 5. install to $INSTALL (exe + the MinGW DLLs it imports)"
mkdir -p "$INSTALL"
cp "$EXE" "$INSTALL/"
OBJDUMP=/c/msys64/mingw64/bin/objdump
for _ in 1 2 3; do   # three passes pick up transitive imports
    for f in "$INSTALL"/*.exe "$INSTALL"/*.dll; do
        [ -f "$f" ] || continue
        "$OBJDUMP" -p "$f" | awk '/DLL Name/{print $3}'
    done | sort -u | while IFS= read -r d; do
        [ -f "$INSTALL/$d" ] && continue
        [ -f "/c/msys64/mingw64/bin/$d" ] && cp "/c/msys64/mingw64/bin/$d" "$INSTALL/"
    done
done
n=$(ls "$INSTALL"/*.dll 2>/dev/null | wc -l | tr -d ' ')
ok "$n runtime DLLs bundled"
echo
echo "=== done: $INSTALL\\vncviewer.exe ==="
echo "  connect: vncviewer.exe -SecurityTypes=None <unit-ip>:5900   (kvmd auth off)"
echo "  H.264 is negotiated automatically; keep the unit's video format on H.264."

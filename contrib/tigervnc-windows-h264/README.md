# TigerVNC for Windows with H.264 above 1080p

**Status: VERIFIED 2026-09-01** — the patched viewer renders the unit's
2560×1440 stream, live and from replay. `tools/build-tigervnc-h264.sh`
reproduces the build; the installed copy lives in
`%LOCALAPPDATA%\Programs\TigerVNC-h264`.

## Why this exists

kvmd-vnc on the RM10 streams Open H.264 (RFB encoding 50) at the attached
host's native 2560×1440. TigerVNC is the only mainstream viewer that speaks
that encoding, and on Windows its decoder is Media Foundation
(`common/rfb/H264WinDecoderContext.cxx`), with every decoder error
swallowed. Measured on 2026-09-01 with TigerVNC 1.16.2 and
`tools/vnc-h264-replay.py`: a 1920×1080 transcode of the unit's stream
renders, the unit's own 2560×1440 stream and a 2560×1440 Main-profile
transcode stay black.

**The cause, found by logging what the code swallowed:** the buffer that
receives decoded NV12 frames is allocated once, in the constructor, from
the decoder's *placeholder* output type — before any stream has been seen —
which sizes it for 1920×1088 (4,147,200 bytes). A 2560×1440 NV12 frame is
5,529,600 bytes, so every `ProcessOutput` failed, silently, for every frame,
and the loop that drains output spun on the error. 1080p fitted; anything
larger was black regardless of profile or level.

`h264-win-decoder-limits.diff` (against TigerVNC v1.16.2):

- on the decoder's stream-change notification, re-reads the output stream
  info and grows the decoded-frame buffer to the size it now needs;
- logs `ProcessInput`/`ProcessOutput` failures and the stream-change sizes
  instead of returning silently, and breaks out of the drain loop on an
  unexpected error instead of spinning;
- adds two includes to `common/rdr/FdInStream.cxx` so it compiles on current
  MinGW-w64 (its `#define close closesocket` otherwise renames a later
  `close()` prototype into a conflicting `closesocket(int)`).

Raising `CODECAPI_AVDecVideoMaxCodedWidth/Height` was tried first and is
**not** needed: with it removed the 1440p stream still renders (ablation
with the same build, 2026-09-01). The decoder accepted 1440p all along.

## Build (MSYS2 / MinGW-w64, on Windows)

TigerVNC 1.16.2 insists on FLTK 1.3; MSYS2 ships 1.4, so FLTK 1.3.9 is built
first into a private prefix.

```bash
winget install -e --id MSYS2.MSYS2
# in a MINGW64 shell (C:\msys64\msys2_shell.cmd -mingw64), or via
#   C:\msys64\usr\bin\bash.exe -lc with MSYSTEM=MINGW64:
pacman -Syu --noconfirm && pacman -Syu --noconfirm
pacman -S --noconfirm --needed mingw-w64-x86_64-{gcc,cmake,ninja,pkgconf,libjpeg-turbo,zlib,pixman}
git clone --depth 1 --branch release-1.3.9 https://github.com/fltk/fltk
cmake -G Ninja -S fltk -B build-fltk -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PWD/fltk13" -DOPTION_BUILD_SHARED_LIBS=OFF -DOPTION_USE_GL=OFF \
  -DOPTION_BUILD_EXAMPLES=OFF -DFLTK_BUILD_TEST=OFF \
  -DOPTION_USE_SYSTEM_LIBJPEG=ON -DOPTION_USE_SYSTEM_ZLIB=ON -DOPTION_USE_SYSTEM_LIBPNG=ON
cmake --build build-fltk --target install
git clone --depth 1 --branch v1.16.2 https://github.com/TigerVNC/tigervnc
git -C tigervnc apply ../contrib/tigervnc-windows-h264/h264-win-decoder-limits.diff
cmake -G Ninja -S tigervnc -B build-tigervnc -DCMAKE_BUILD_TYPE=Release -DBUILD_VIEWER=1 \
  -DENABLE_H264=1 -DENABLE_NLS=0 -DENABLE_GNUTLS=0 -DENABLE_NETTLE=0 \
  -DFLTK_DIR="$PWD/fltk13/CMake" -DCMAKE_PREFIX_PATH="$PWD/fltk13"
cmake --build build-tigervnc --target vncviewer
```

The result is `build-tigervnc/vncviewer/vncviewer.exe`. It needs the MinGW
runtime DLLs next to it or `C:\msys64\mingw64\bin` on PATH (libjpeg, zlib,
pixman, libgcc, libstdc++, libwinpthread). GnuTLS and RSA-AES are left out,
so only `SecurityTypes=None` (kvmd auth off) and VNCAuth/VeNCrypt-less
setups work; add `mingw-w64-x86_64-gnutls` and drop the two `-DENABLE_*=0`
flags to get VeNCrypt back.

## Test without touching a unit

```bash
python tools/vnc-h264-replay.py sample-2560x1440.h264 2560 1440 5901 30
build-tigervnc/vncviewer/vncviewer.exe -Log '*:stderr:100' -AutoSelect=0 \
  -PreferredEncoding=H.264 -SecurityTypes=None 127.0.0.1:5901
```

A sample comes from the unit with
`ustreamer-dump --sink kvmd::ustreamer::h264 --output s.h264` (a few seconds).
The log line `Coded-size limits raised to 4096x2304: width hr=0x00000000
height hr=0x00000000` confirms the patch is in and the MFT accepted it.

## Upstream

Sent as [TigerVNC/tigervnc#2153](https://github.com/TigerVNC/tigervnc/pull/2153)
from `heidrickla/tigervnc`, branch `h264-win-decoded-buffer`, rebased on
master. After the first review round (2026-09-15) the commits are
`342ce80` (the fix, 30 added lines) and `8e2c556` (the test). The upstream
version is smaller than the diff here: master had already fixed the MinGW
`closesocket` clash; the coded-size limit code is left out because the
ablation showed it does nothing; and the review removed the logging
(TigerVNC's decoders run on worker threads and its logger is not safe
there) and a no-op rewrite of the `ProcessInput()` call, whose extra `hr`
had tripped `-Werror=shadow` on CI's Windows build. With logging in place
the failing call was `ProcessOutput()` returning `E_FAIL` (0x80004005) on
every frame. The reviewer asked where the too-small size comes from: the
constructor sizes the decoded buffer from the output stream info before
any input has been seen, when the MFT's output type still carries its
default 1920×1080 frame size (4,147,200 bytes on Windows 11); the code
comment now says so.

Regression run for the revised branch, 2026-09-15, on this desktop with
CI's Debug `-Werror` flags under MSYS2 MinGW64 (Lewis allowed the local
build for this): the revision builds clean and passes both tests; the
previous revision fails with CI's exact `declaration of 'hr' shadows a
previous local` error; master's decoder passes 1080p and fails 1440p on
all three pixels; restored, green again.

The PR's second commit is a regression test, `tests/unit/h264decoder.cxx`
(copy here as `h264decoder-test.cxx`): it decodes an embedded flat-grey
IDR frame at 1920×1080 and at 2560×1440 through `H264Decoder` into a
black pixel buffer and checks three pixels. Run against master's decoder
it fails the 1440p case with every pixel still 0 and passes 1080p; with
the fix both pass. `0001-upstream-pr-2153-master.patch` holds both
commits as sent.

## Verification record

- 2026-09-01, TigerVNC 1.16.2 + patch, MSYS2 MinGW-w64 GCC 16.2, FLTK
  1.3.9 static, Windows 11: replay of the unit's 2560×1440 High-5.0 stream
  renders (log: `Stream change: decoder output 2560x1440, SPS says
  2560x1440` then `Decoded-frame buffer grown from 4147200 to 7372800
  bytes`); live against `.15` with TigerVNC's default Auto select renders at
  ~59 updates/s on the H.264 memsink with no ustreamer restarts; the
  installed copy runs with only its own folder on PATH. Ablation: the
  coded-size limit code removed, still renders.

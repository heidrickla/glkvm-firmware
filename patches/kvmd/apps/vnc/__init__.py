# ========================================================================== #
#                                                                            #
#    KVMD - The main PiKVM daemon.                                           #
#                                                                            #
#    Copyright (C) 2018-2024  Maxim Devaev <mdevaev@gmail.com>               #
#                                                                            #
#    This program is free software: you can redistribute it and/or modify    #
#    it under the terms of the GNU General Public License as published by    #
#    the Free Software Foundation, either version 3 of the License, or       #
#    (at your option) any later version.                                     #
#                                                                            #
#    This program is distributed in the hope that it will be useful,         #
#    but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#    GNU General Public License for more details.                            #
#                                                                            #
#    You should have received a copy of the GNU General Public License       #
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.  #
#                                                                            #
# ========================================================================== #

# ---------------------------------------------------------------------------
# LOCAL PATCH (glkvm-firmware repo), 2026-09-01 -- firmware 1.10.0 only
#
# VNC showed a black screen to TightVNC. Measured on .15:
#
#   * A VNC client without Open H.264 (TightVNC, RealVNC, UltraVNC ...) makes
#     kvmd-vnc read the JPEG memsink `kvmd::ustreamer::jpeg`. GL.iNet's
#     ustreamer never writes it: the RV1126 pipeline produces H.264/H.265
#     only (the sink file's mtime never moves, ustreamer-dump gets 0 bytes).
#     MemsinkStreamerClient then waits forever and no frame is ever sent.
#   * The upstream fallback, HttpStreamerClient on /stream, is useless here
#     too: GL.iNet's /stream is a raw H.264 elementary stream, not MJPEG.
#   * ustreamer's /snapshot, however, returns a hardware-encoded JPEG
#     ("X-UStreamer-Snapshot-Method: rv1126-direct") in ~16 ms at 2560x1440,
#     with the X-UStreamer-Width/Height/Online headers the VNC code wants.
#
# So this file adds SnapshotStreamerClient: JPEG frames by polling /snapshot,
# paced at vnc.desired_fps, and puts it in place of the two dead JPEG paths.
# The H.264 memsink client is untouched: with the streamer in H.264 mode
# (video_format 0) it feeds TigerVNC >= 1.13 as before. In H.265 mode the
# sink is tagged HEVC, the H.264 client rightly refuses it, and kvmd-vnc
# falls back to this JPEG client -- so a picture in every case.
#
# Cost: about 0.4 MB per frame at 2560x1440 / JPEG quality 70, i.e. the
# same full-frame Tight JPEG stream upstream kvmd-vnc sends from a Pi's
# JPEG sink. Lower vnc.desired_fps in override.yaml on slow links.
#
# Provenance, measured 2026-09-01 on .15: the device's apps/vnc/__init__.pyc
# compiles from the vendor source with zero semantic differences.
#
# Apply with: tools/apply-module.sh <ip> patches/kvmd/apps/vnc/__init__.py
# ---------------------------------------------------------------------------

import asyncio
import contextlib
import time

from typing import Callable
from typing import Awaitable
from typing import AsyncGenerator

import aiohttp

from ...clients.kvmd import KvmdClient
from ...clients.streamer import StreamerFormats
from ...clients.streamer import StreamerTempError
from ...clients.streamer import BaseStreamerClient
from ...clients.streamer import HttpStreamerClient
from ...clients.streamer import MemsinkStreamerClient
from ...clients.streamer import _http_reading_handle_errors  # pylint: disable=protected-access

from ... import htclient

from .. import init

from .server import VncServer


# =====
class SnapshotStreamerClient(HttpStreamerClient):
    # LOCAL PATCH: JPEG frames from ustreamer's /snapshot, for VNC clients
    # that cannot take H.264. See the header of this file.

    def __init__(self, name: str, user_agent: str, unix_path: str, timeout: float, max_fps: float) -> None:
        # config.streamer._unpack() yields unix_path (Option unpack_as) and timeout.
        super().__init__(name=name, user_agent=user_agent, unix_path=unix_path, timeout=timeout)
        self.__interval = (1.0 / max_fps if max_fps > 0 else 0.0)

    @contextlib.asynccontextmanager
    async def reading(self) -> AsyncGenerator[Callable[[bool], Awaitable[dict]], None]:
        with _http_reading_handle_errors():
            async with self._make_http_session() as session:
                last = 0.0

                async def read_frame(key_required: bool) -> dict:
                    nonlocal last
                    _ = key_required
                    delay = self.__interval - (time.monotonic() - last)
                    if delay > 0:
                        await asyncio.sleep(delay)
                    with _http_reading_handle_errors():
                        async with session.get(
                            url="/snapshot",
                            timeout=aiohttp.ClientTimeout(
                                connect=session.timeout.total,
                                sock_read=session.timeout.total,
                            ),
                        ) as resp:
                            htclient.raise_not_200(resp)
                            data = bytes(await resp.read())
                            last = time.monotonic()
                            if not data:
                                raise StreamerTempError("Empty snapshot")
                            return {
                                "online": (resp.headers.get("X-UStreamer-Online") == "true"),
                                "width": int(resp.headers["X-UStreamer-Width"]),
                                "height": int(resp.headers["X-UStreamer-Height"]),
                                "data": data,
                                "format": StreamerFormats.JPEG,
                            }

                yield read_frame

    def __str__(self) -> str:
        return "SnapshotStreamerClient(JPEG)"


# =====
def main(argv: (list[str] | None)=None) -> None:
    config = init(
        prog="kvmd-vnc",
        description="VNC to KVMD proxy",
        check_run=True,
        argv=argv,
    )[2].vnc

    user_agent = htclient.make_user_agent("KVMD-VNC")

    def make_memsink_streamer(name: str, fmt: int) -> (MemsinkStreamerClient | None):
        if getattr(config.memsink, name).sink:
            return MemsinkStreamerClient(name.upper(), fmt, **getattr(config.memsink, name)._unpack())
        return None

    # LOCAL PATCH: the JPEG memsink is never written on this firmware and
    # /stream is not MJPEG, so the snapshot poller is the only JPEG source.
    # It is also the last entry, hence the fallback when the H.264 memsink
    # refuses an H.265-tagged sink.
    streamers: list[BaseStreamerClient] = list(filter(None, [
        make_memsink_streamer("h264", StreamerFormats.H264),
        SnapshotStreamerClient(name="JPEG", user_agent=user_agent, max_fps=config.desired_fps, **config.streamer._unpack()),
    ]))

    VncServer(
        host=config.server.host,
        port=config.server.port,
        max_clients=config.server.max_clients,

        no_delay=config.server.no_delay,

        tls_ciphers=config.server.tls.ciphers,
        tls_timeout=config.server.tls.timeout,
        x509_cert_path=config.server.tls.x509.cert,
        x509_key_path=config.server.tls.x509.key,

        desired_fps=config.desired_fps,
        mouse_output=config.mouse_output,
        keymap_path=config.keymap,
        scroll_rate=config.scroll_rate,

        kvmd=KvmdClient(user_agent=user_agent, **config.kvmd._unpack()),
        streamers=streamers,

        **config.server.keepalive._unpack(),
        **config.auth.vncauth._unpack(),
        **config.auth.vencrypt._unpack(),
    ).run()

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
# LOCAL PATCH (glkvm-firmware repo), 2026-09-01
#
# GET /api/export/prometheus/metrics returned HTTP 500 on a stock unit:
#
#     File ".../kvmd/apps/kvmd/info/__init__.py", line 65, in get_state
#     KeyError: 'fan'
#
# GL.iNet commented the "fan" submanager out of InfoManager.__subs but left
# this module asking get_state(["health", "fan"]) for it. Nothing else in the
# product hits that path, so the Prometheus endpoint has simply never worked.
#
# Fixed here rather than by re-registering "fan", because this hardware has no
# kvmd-fan daemon (kvmd.info.fan.unix is '') -- a fan submanager would only
# ever report {"monitored": false, "state": null}. Asking for what exists is
# also self-healing if a fan is ever wired up.
#
# NOTE ON PROVENANCE: the device runs firmware 1.8.1 and this source is from
# 1.10.0. Both call themselves kvmd 4.82, but they are NOT the same code --
# compiling the 1.10.0 source and comparing bytecode against the shipped .pyc
# shows every module differs. For THIS module the structure matches exactly
# (same functions, same metric-name constants, verified by disassembling the
# device's export.pyc), so the swap is safe. Do not assume that of other
# modules without running the same comparison.
#
# Apply with: tools/apply-module.sh <ip> patches/kvmd/apps/kvmd/api/export.py
# ---------------------------------------------------------------------------

import asyncio

from typing import Any

import async_lru

from aiohttp.web import Request
from aiohttp.web import Response

from .... import tools

from ....htserver import exposed_http

from ....plugins.atx import BaseAtx
from ....plugins.ugpio import UserGpioModes

from ..info import InfoManager
from ..ugpio import UserGpio


# =====
class ExportApi:
    def __init__(self, info_manager: InfoManager, atx: BaseAtx, user_gpio: UserGpio) -> None:
        self.__info_manager = info_manager
        self.__atx = atx
        self.__user_gpio = user_gpio

    # =====

    @exposed_http("GET", "/export/prometheus/metrics")
    async def __prometheus_metrics_handler(self, _: Request) -> Response:
        return Response(text=(await self.__get_prometheus_metrics()))

    @async_lru.alru_cache(maxsize=1, ttl=5)
    async def __get_prometheus_metrics(self) -> str:
        # LOCAL PATCH: ask InfoManager only for submanagers it actually
        # registered. See the banner at the top of this file.
        fields = sorted({"health", "fan"} & self.__info_manager.get_subs())
        (atx_state, info_state, gpio_state) = await asyncio.gather(*[
            self.__atx.get_state(),
            self.__info_manager.get_state(fields),
            self.__user_gpio.get_state(),
        ])
        rows: list[str] = []

        self.__append_prometheus_rows(rows, atx_state["enabled"], "pikvm_atx_enabled")  # type: ignore
        self.__append_prometheus_rows(rows, atx_state["leds"]["power"], "pikvm_atx_power")  # type: ignore

        for mode in sorted(UserGpioModes.ALL):
            for (channel, ch_state) in gpio_state["state"][f"{mode}s"].items():  # type: ignore
                if not channel.startswith("__"):  # Hide special GPIOs
                    for key in ["online", "state"]:
                        self.__append_prometheus_rows(rows, ch_state["state"], f"pikvm_gpio_{mode}_{key}_{channel}")

        # LOCAL PATCH: emit only what we asked for, so a submanager the fork
        # disabled costs a missing metric rather than the whole endpoint.
        for (field, prefix) in (("health", "pikvm_hw"), ("fan", "pikvm_fan")):
            if field in info_state:
                self.__append_prometheus_rows(rows, info_state[field], prefix)  # type: ignore

        return "\n".join(rows)

    def __append_prometheus_rows(self, rows: list[str], value: Any, path: str) -> None:
        if isinstance(value, bool):
            value = int(value)
        if isinstance(value, (int, float)):
            rows.extend([
                f"# TYPE {path} gauge",
                f"{path} {value}",
                "",
            ])
        elif isinstance(value, dict):
            for (sub_key, sub_value) in tools.sorted_kvs(value):
                sub_path = (f"{path}_{sub_key}" if sub_key != "parsed_flags" else path)
                self.__append_prometheus_rows(rows, sub_value, sub_path)

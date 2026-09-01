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
# Registers the "health" info submanager. GL.iNet ships health.pyc in the image
# but never registers it, so CPU temperature, CPU load and memory were collected
# by code wired to nothing -- invisible to both UIs and to Prometheus.
#
# PROVENANCE, verified rather than assumed. Disassembling the device's own
# info/__init__.pyc shows InfoManager.__init__ builds only:
#
#     system, auth, meta, extras
#
# while get_state()'s constants ('hw', 'system', 'health', 'platform') and
# poll_state() match this 1.10.0 source exactly. __init__ is therefore the only
# method that differs, and this file reproduces the rest faithfully.
#
# The device is firmware 1.8.1; this source is 1.10.0. Both call themselves
# kvmd 4.82, but their bytecode differs in EVERY module. Do not port anything
# else on the strength of the version string -- compile the source on the device
# and compare against the shipped .pyc first.
#
# Pairs with patches/kvmd/apps/kvmd/info/health.py; apply both together.
# ---------------------------------------------------------------------------

import asyncio

from typing import AsyncGenerator

from ....yamlconf import Section

from .base import BaseInfoSubmanager
from .auth import AuthInfoSubmanager
from .system import SystemInfoSubmanager
from .meta import MetaInfoSubmanager
from .extras import ExtrasInfoSubmanager
from .health import HealthInfoSubmanager
from .fan import FanInfoSubmanager


# =====
class InfoManager:
    def __init__(self, config: Section) -> None:
        self.__subs: dict[str, BaseInfoSubmanager] = {
            "system": SystemInfoSubmanager(config.kvmd.info.hw.platform, config.kvmd.streamer.cmd),
            "auth":   AuthInfoSubmanager(config.kvmd.auth.enabled),
            "meta":   MetaInfoSubmanager(config.kvmd.info.meta),
            "extras": ExtrasInfoSubmanager(config),
            # LOCAL PATCH -- see banner. state_poll is passed explicitly
            # rather than via **_unpack(): this device's config still carries
            # an `ignore_past` option that the ported health.py no longer
            # takes, so unpacking the whole section would raise TypeError.
            "health": HealthInfoSubmanager(
                state_poll=config.kvmd.info.hw.state_poll,
            ),
            # "fan": deliberately left off. kvmd.info.fan.unix is '' and there
            # is no kvmd-fan daemon on this hardware, so it could only ever
            # report {"monitored": false, "state": null}. api/export.py is
            # patched to ask only for submanagers that are registered.
        }
        self.__queue: "asyncio.Queue[tuple[str, (dict | None)]]" = asyncio.Queue()

    def get_subs(self) -> set[str]:
        return set(self.__subs)

    async def get_state(self, fields: (list[str] | None)=None) -> dict:
        fields_set = set(fields or list(self.__subs))

        hw = ("hw" in fields_set)  # Old for compatible
        system = ("system" in fields_set)
        if hw:
            fields_set.remove("hw")
            fields_set.add("health")
            fields_set.add("system")

        state = dict(zip(fields_set, await asyncio.gather(*[
            self.__subs[field].get_state()
            for field in fields_set
        ])))

        if hw:
            state["hw"] = {
                "health":   state.pop("health"),
                "platform": (state["system"] or {}).pop("platform"),  # {} makes mypy happy
            }
            if not system:
                state.pop("system")
        return state

    async def trigger_state(self) -> None:
        await asyncio.gather(*[
            sub.trigger_state()
            for sub in self.__subs.values()
        ])

    async def poll_state(self) -> AsyncGenerator[dict, None]:
        # ==== Granularity table ====
        #   - system -- Partial
        #   - auth   -- Partial
        #   - meta   -- Partial, nullable
        #   - extras -- Partial, nullable
        #   - health -- Partial
        #   - fan    -- Partial
        # ===========================

        while True:
            (field, value) = await self.__queue.get()
            yield {field: value}

    async def systask(self) -> None:
        tasks = [
            asyncio.create_task(self.__poller(field))
            for field in self.__subs
        ]
        try:
            await asyncio.gather(*tasks)
        except Exception:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            raise

    async def __poller(self, field: str) -> None:
        async for state in self.__subs[field].poll_state():
            self.__queue.put_nowait((field, state))

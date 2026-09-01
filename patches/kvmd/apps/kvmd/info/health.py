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
# PORTED MODULE (glkvm-firmware repo), 2026-09-01
#
# Replaces the health submanager shipped with firmware 1.8.1 with the 1.10.0
# implementation, for one concrete reason: the 1.8.1 version probes Raspberry Pi
# throttling via `vcgencmd get_throttled`, which does not exist on RV1126. That
# probe failed on every poll and wrote
#
#     kvmd.apps.kvmd.info.health ERROR --- Error while executing: get_throttled
#
# to the log every 5 seconds, forever.
#
# The 1.10.0 version drops vcgencmd entirely, returns throttling: None (GL.iNet's
# own comment notes RV1126 has no vcgencmd, and both info.js and export.py handle
# the null), and adds per-interface network rate counters.
#
# Signature changed with it: (vcgencmd_cmd, ignore_past, state_poll) became
# (state_poll). The matching registration lives in this package's __init__.py.
#
# Requires psutil, which the device already has (7.2.2).
# ---------------------------------------------------------------------------

import asyncio
import copy
import time

from typing import AsyncGenerator

import psutil

from ....logging import get_logger

from .... import env
from .... import aiotools

from .base import BaseInfoSubmanager


# =====
class HealthInfoSubmanager(BaseInfoSubmanager):
    def __init__(
        self,
        state_poll: float,
    ) -> None:

        self.__state_poll = state_poll

        self.__notifier = aiotools.AioNotifier()

        # 网络流量速率计算需要保存上一次的累计计数与采样时刻
        self.__prev_net: (tuple[float, int, int] | None) = None

    async def get_state(self) -> dict:
        (
            cpu_percent,
            cpu_temp,
            mem,
            net,
        ) = await asyncio.gather(
            self.__get_cpu_percent(),
            self.__get_cpu_temp(),
            self.__get_mem(),
            self.__get_net(),
        )
        return {
            "temp": {
                "cpu": cpu_temp,
            },
            "cpu": {
                "percent": cpu_percent,
            },
            "mem": mem,
            "net": net,
            # throttling 依赖树莓派专属的 vcgencmd，本机型（RV1126）不存在，
            # 始终为 None。前端 info.js / export.py 已对 null 做兼容处理。
            "throttling": None,
        }

    async def trigger_state(self) -> None:
        self.__notifier.notify(1)

    async def poll_state(self) -> AsyncGenerator[dict, None]:
        prev: dict = {}
        while True:
            if (await self.__notifier.wait(timeout=self.__state_poll)) > 0:
                prev = {}
            new = await self.get_state()
            if new != prev:
                prev = copy.deepcopy(new)
                yield new

    # =====

    async def __get_cpu_temp(self) -> (float | None):
        temp_path = f"{env.SYSFS_PREFIX}/sys/class/thermal/thermal_zone0/temp"
        try:
            return int((await aiotools.read_file(temp_path)).strip()) / 1000
        except Exception as ex:
            get_logger(0).error("Can't read CPU temp from %s: %s", temp_path, ex)
            return None

    async def __get_cpu_percent(self) -> (float | None):
        try:
            st = psutil.cpu_times_percent()
            user = st.user - st.guest
            nice = st.nice - st.guest_nice
            idle_all = st.idle + st.iowait
            system_all = st.system + st.irq + st.softirq
            virtual = st.guest + st.guest_nice
            total = max(1, user + nice + system_all + idle_all + st.steal + virtual)
            return int(
                st.nice / total * 100
                + st.user / total * 100
                + system_all / total * 100
                + (st.steal + st.guest) / total * 100
            )
        except Exception as ex:
            get_logger(0).error("Can't get CPU percent: %s", ex)
            return None

    async def __get_mem(self) -> dict:
        try:
            st = psutil.virtual_memory()
            return {
                "percent": st.percent,
                "total": st.total,
                "available": st.available,
            }
        except Exception as ex:
            get_logger(0).error("Can't get memory info: %s", ex)
            return {
                "percent": None,
                "total": None,
                "available": None,
            }

    async def __get_net(self) -> dict:
        # 网络流量：psutil 返回累计字节数，需用两次采样的差值除以时间间隔得到速率（B/s）。
        # 排除 lo 回环接口，统计所有物理网卡之和。
        try:
            counters = psutil.net_io_counters(pernic=True)
            bytes_sent = sum(c.bytes_sent for (nic, c) in counters.items() if nic != "lo")
            bytes_recv = sum(c.bytes_recv for (nic, c) in counters.items() if nic != "lo")
            now = time.monotonic()

            tx_rate = 0
            rx_rate = 0
            if self.__prev_net is not None:
                (prev_ts, prev_sent, prev_recv) = self.__prev_net
                dt = now - prev_ts
                if dt > 0:
                    # max(0, ...) 防止网卡计数器回绕/重置导致负值
                    tx_rate = int(max(0, bytes_sent - prev_sent) / dt)
                    rx_rate = int(max(0, bytes_recv - prev_recv) / dt)
            self.__prev_net = (now, bytes_sent, bytes_recv)

            return {
                "bytes_sent": bytes_sent,
                "bytes_recv": bytes_recv,
                "tx_rate": tx_rate,  # 上行速率 B/s
                "rx_rate": rx_rate,  # 下行速率 B/s
            }
        except Exception as ex:
            get_logger(0).error("Can't get network IO: %s", ex)
            return {
                "bytes_sent": None,
                "bytes_recv": None,
                "tx_rate": None,
                "rx_rate": None,
            }

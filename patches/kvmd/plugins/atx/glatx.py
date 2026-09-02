import asyncio
import subprocess
import os
from typing import AsyncGenerator

from ... import aiotools
from ...logging import get_logger

from . import AtxError
from . import AtxIsBusyError

# ---------------------------------------------------------------------------
# LOCAL PATCH (glkvm-firmware repo), 2026-09-02 -- firmware 1.10.0 only
#
# kvmd's Redfish maps leds.power to PowerState. GL.iNet's plugin reads the
# real power state from the USB ATX board (atxpower <dev> power_state ->
# "on"/"off") and reports it as "power", but hard-codes leds.power to False,
# so /redfish/v1/Systems/0 says PowerState "Off" while /api/atx says "on".
# Anything fencing or automating on Redfish is misled. This file derives
# leds.power from that reading and changes nothing else.
#
# Provenance, measured 2026-09-02 on .15: the device's glatx.pyc compiles from
# the vendor source with zero semantic differences.
#
# Apply with: tools/apply-module.sh <ip> patches/kvmd/plugins/atx/glatx.py
# ---------------------------------------------------------------------------
from . import BaseAtx


# =====
class Plugin(BaseAtx):
    def __init__(self) -> None:
        self.__device = "/dev/ttyACM0"
        self.__atxpower_bin = "/usr/sbin/atxpower"
        self.__notifier = aiotools.AioNotifier()
        self.__region = aiotools.AioExclusiveRegion(AtxIsBusyError, self.__notifier)
        self.__need_update = False

    async def get_state(self) -> dict:
        try:
            # 检查设备是否存在
            device_exists = os.path.exists(self.__device)
            if not device_exists:
                return {
                    "enabled": False,
                    "busy": self.__region.is_busy(),
                    "power": "off",
                    "leds": {
                        "power": False,
                        "hdd": False,
                    },
                }
                
            # 使用run_async将subprocess.run放入线程池中执行，避免阻塞事件循环
            cmd = [self.__atxpower_bin, self.__device, "power_state"]

            try:
                # 直接传递同步函数到run_async
                def run_command():
                    return subprocess.run(cmd, capture_output=True, text=True, timeout=3)
                
                result = await aiotools.run_async(run_command)
                
                if result.returncode != 0:
                    error = result.stderr.strip() if result.stderr else "Unknown error"
                    raise AtxError(f"Failed to get power state: {error}")
                
                power_state = result.stdout.strip()
                
                return {
                    "enabled": True,
                    "busy": self.__region.is_busy(),
                    "power": power_state,
                    "leds": {
                        # LOCAL PATCH: what the board says, so Redfish PowerState is right
                        "power": (power_state == "on"),
                        "hdd": False,
                    },
                }
            except subprocess.TimeoutExpired:
                get_logger(0).error("Timeout while getting power state")
                raise AtxError("Command timeout while getting power state")
            
        except Exception as e:
            get_logger(0).error("Failed to get power state: %s", str(e))
            return {
                "enabled": False,
                "busy": self.__region.is_busy(),
                "power": "off",
                "leds": {
                    "power": False,
                    "hdd": False,
                },
            }
    
    async def trigger_state(self) -> None:
        self.__need_update = True

    async def poll_state(self) -> AsyncGenerator[dict, None]:
        prev_device_exists = os.path.exists(self.__device)
        prev_state = await self.get_state()
        
        while True:
            try:
                # 检查设备是否存在
                current_device_exists = os.path.exists(self.__device)
                
                # 如果设备状态发生变化，或者设备存在时需要更新电源状态
                if current_device_exists != prev_device_exists or current_device_exists:
                    state = await self.get_state()
                    if self.__need_update or state != prev_state:
                        get_logger(0).info(f"ATX state changed: {state}")
                        yield state
                        prev_state = state
                        self.__need_update = False
                
                prev_device_exists = current_device_exists
            except Exception as e:
                get_logger(0).error(f"Error monitoring ATX device state: {e}")
                
            await asyncio.sleep(1)  # 每秒检查一次

    async def cleanup(self) -> None:
        pass

    # =====
    @aiotools.atomic_fg
    async def __run_cmd(self, action: str, wait: bool) -> None:
        if wait:
            async with self.__region:
                await self.__inner_run_cmd(action)
        else:
            await aiotools.run_region_task(
                f"Can't perform ATX {action} operation or operation was not completed",
                self.__region, self.__inner_run_cmd, action,
            )

    async def power_on(self, wait: bool) -> None:
        await self.__run_cmd("power_on", wait)

    async def power_off(self, wait: bool) -> None:
        await self.__run_cmd("power_off", wait)

    async def power_off_hard(self, wait: bool) -> None:
        await self.__run_cmd("power_off_hard", wait)

    async def power_reset_hard(self, wait: bool) -> None:
        await self.__run_cmd("power_reset", wait)

    # =====

    async def click_power(self, wait: bool) -> None:
        await self.__run_cmd("click_power_short", wait)

    async def click_power_long(self, wait: bool) -> None:
        await self.__run_cmd("click_power_long", wait)

    async def click_reset(self, wait: bool) -> None:
        await self.__run_cmd("click_reset", wait)

    # =====


    @aiotools.atomic_fg
    async def __inner_run_cmd(self, action: str) -> None:
        cmd = [self.__atxpower_bin, self.__device, action]
        try:
            # 使用run_async将subprocess.run放入线程池中执行，避免阻塞事件循环
            def run_command():
                return subprocess.run(cmd, capture_output=True, text=True, timeout=5)

            try:
                result = await aiotools.run_async(run_command)

                if result.returncode != 0:
                    error = result.stderr.strip() if result.stderr else "Unknown error"
                    get_logger(0).error(f"stdout: {result.stdout}")
                    raise AtxError(f"Failed to execute {' '.join(cmd)}: {error}")
                    
                get_logger(0).info("Executed ATX command %r", action)
                
            except subprocess.TimeoutExpired:
                get_logger(0).error("Timeout while executing ATX command %r", action)
                raise AtxError(f"Command timeout while executing {action}")
                
        except Exception as e:
            get_logger(0).error("Failed to execute ATX command %r: %s", action, str(e))
            raise

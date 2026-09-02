# Firmware diff

old: `/home/claude/fwdiff/old/site-packages`  
new: `/home/claude/bake/root/usr/lib/python3.12/site-packages`

## kvmd bytecode: 7 added, 0 removed, 50 changed, 172 identical

### Added modules

- `apps/kvmd/api/common.pyc` (8108 B)
- `apps/kvmd/api/custom_screen.pyc` (15756 B)
- `apps/kvmd/api/netbird.pyc` (22087 B)
- `apps/kvmd/api/recorder.pyc` (9490 B)
- `apps/kvmd/api/serial.pyc` (28311 B)
- `apps/otg/hid/touch.pyc` (721 B)
- `plugins/hid/otg/touch.pyc` (4360 B)

### Changed modules — what appeared (+) and vanished (-)

#### `apps/__init__.pyc`  (34376 → 35355 B)
  + names (1): 'valid_stream_venc_mode'
  + strings (14): ' must be a dict', '/proc/gl-hw-info/capability/usb_epin', '/run/kvmd/ocr-service.sock', '/var/log/kvmd.log', 'ConfigError: Cannot read config file ', 'ConfigError: The top level of file ', 'Dump current config (including all overrides)', 'Override config options list (format: sec/sub/opt=value)', 'Run service', 'Set config file path', 'normal', 'rknn_socket', 'rmq1', 'venc_mode'
  - strings (9): ' 的顶层必须是字典', 'ConfigError: 文件 ', 'ConfigError: 无法读取配置文件 ', 'pre_start_cmd_remove', '为防止意外启动，您必须指定 --run 选项来启动。\n尝试使用 --help 选项来了解此服务的功能。\n请确保您完全理解您正在做什么！', '查看当前配置（包括所有覆盖）', '覆盖配置选项列表（格式如 sec/sub/opt=value）', '设置配置文件路径', '运行服务'

#### `apps/janus/runner.pyc`  (16354 → 17477 B)
  + names (2): '_JanusRunner__disable_flag_path', 'done'
  + strings (4): '/tmp/kvmd_janus_disable', 'Janus disable flag removed, resuming restart ...', 'Janus restart suppressed by disable flag, waiting ...', 'Janus task completed unexpectedly, restarting ...'

#### `apps/janus/stun.pyc`  (13007 → 13703 B)
  + functions (1): '<lambda>'
  + names (2): 'get_running_loop', 'run_in_executor'

#### `apps/kvmd/__init__.pyc`  (7403 → 7741 B)
  + names (5): 'api.config_utils', 'backup_count', 'max_bytes', 'migrate_boot_config_sync', 'path'

#### `apps/kvmd/api/auth.pyc`  (20025 → 20245 B)
  - strings (1): 'token'

#### `apps/kvmd/api/cloudflare.pyc`  (11666 → 8152 B)
  + names (5): 'common', 'is_process_running', 'read_json_file', 'run_command', 'update_json_file'
  - names (18): 'PIPE', 'communicate', 'create_subprocess_exec', 'create_subprocess_shell', 'decode', 'dirname', 'dump', 'exists', 'json', 'load', 'makedirs', 'open', 'os', 'path', 'returncode', 'split', 'strip', 'subprocess'
  + strings (1): 'cloudflared process'
  - strings (14): '\n        执行系统命令\n        ', '\n        检查 cloudflared 进程是否存在\n        ', '\n        读取配置文件\n        ', 'Command failed: ', 'Error checking cloudflared process: ', 'Error executing command: ', 'Failed to create config directory ', 'Failed to create config directory: ', 'Failed to read config file ', 'Failed to write config file ', 'Failed to write config file: ', 'cloudflared', 'pgrep', 'sync'

#### `apps/kvmd/api/config_utils.pyc`  (3667 → 6567 B)
  + functions (2): 'delete_nested_key', 'migrate_boot_config_sync'
  + names (12): 'DEPRECATED_BOOT_KEYS', '__annotations__', 'append', 'bool', 'delete_nested_key', 'info', 'len', 'list', 'migrate_boot_config_sync', 'reversed', 'run', 'subprocess'
  + strings (7): 'DEPRECATED_BOOT_KEYS', 'deprecated_keys', 'kvmd/msd/type', 'migrate_boot_config: boot.yaml cleaned, removed %d key(s)', 'migrate_boot_config: failed: %s', 'migrate_boot_config: removed deprecated key %r', '同步版 boot.yaml 孤立 key 清理，用于 event loop 启动前调用。\n    删除 deprecated_keys 中指定的孤立 key，若有改动则写回并执行 sync 刷盘。\n    '

#### `apps/kvmd/api/export.pyc`  (4302 → 4182 B)
  - names (1): 'get_subs'
  + strings (2): 'pikvm_fan', 'pikvm_hw'

#### `apps/kvmd/api/hid.pyc`  (20735 → 27014 B)
  + functions (7): '__events_send_touch_handler', '__load_jiggler_schedule', '__save_jiggler_schedule', '__set_jiggler_schedule_handler', '__ws_bin_touch_handler', '__ws_touch_handler', '_wait_disconnect'
  + names (31): 'CancelledError', 'FileNotFoundError', '_HidApi__events_send_touch_handler', '_HidApi__load_jiggler_schedule', '_HidApi__save_jiggler_schedule', '_HidApi__set_jiggler_schedule_handler', '_HidApi__ws_bin_touch_handler', '_HidApi__ws_touch_handler', '_JIGGLER_SCHEDULE_PATH', 'asyncio', 'cancel', 'clear_events', 'config_utils', 'done', 'dump', 'ensure_future', 'is_closing', 'json', 'load', 'makedirs', 'open', 'pop', 'send_touch_event', 'set_jiggler_interval', 'set_jiggler_schedule', 'set_yaml_value', 'sleep', 'transport', 'trigger_state', 'valid_hid_jiggler_interval' ...
  + strings (8): '/etc/kvmd/user/jiggler_schedule.json', '/hid/events/send_touch', '/hid/set_jiggler_schedule', 'jiggler_interval', 'kvmd/hid/jiggler/interval', 'periods', 'touch', 'touching'

#### `apps/kvmd/api/init.pyc`  (3406 → 4167 B)
  + names (7): 'BadRequestError', 'InvalidOldPasswordError', 'ValidatorError', 'WeakPasswordError', '_WEAK_PASSWORD_MSG', 'valid_new_passwd', 'validators'
  + strings (2): 'Already initialized', 'Old password is incorrect'

#### `apps/kvmd/api/modem.pyc`  (13063 → 13097 B)
  + names (1): 'debug'

#### `apps/kvmd/api/msd.pyc`  (20122 → 20861 B)
  + functions (1): '__switch_partition_handler'
  + names (3): 'BadRequestError', '_MsdApi__switch_partition_handler', 'switch_partition'
  + strings (3): '/msd/switch_partition', 'device', 'device parameter is required'

#### `apps/kvmd/api/repeater.pyc`  (11420 → 14769 B)
  + functions (3): '__add_preset_ap_handler', '__del_preset_ap_handler', '__get_preset_ap_list_handler'
  + names (3): '_RepeaterApi__add_preset_ap_handler', '_RepeaterApi__del_preset_ap_handler', '_RepeaterApi__get_preset_ap_list_handler'
  + strings (14): '/repeater/add_preset_ap', '/repeater/del_preset_ap', '/repeater/get_preset_ap_list', 'Error executing repeater add_preset_ap: ', 'Error executing repeater connect: ', 'Error executing repeater del_preset_ap: ', 'Error executing repeater get_preset_ap_list: ', 'Failed to add preset ap:', 'Failed to delete preset ap:', 'Failed to get preset ap list:', 'add_preset_ap', 'del_preset_ap', 'encryption', 'get_preset_ap_list'
  - strings (1): 'Error executing repeater connect'

#### `apps/kvmd/api/streamer.pyc`  (5605 → 5692 B)
  - strings (1): 'text/plain'

#### `apps/kvmd/api/system.pyc`  (92423 → 129712 B)
  + functions (26): '__change_otg_functions', '__get_current_otg_functions', '__get_expected_otg_functions', '__get_managed_otg_functions', '__get_otg_udc_state', '__is_rkipc_running', '__otg_functions_to_payload', '__wait_otg_functions_synced', '_build_ntp_conf', '_build_timezone_list', '_get_current_timezone_name', '_get_utc_offset_minutes', '_is_valid_tz_name', '_parse_ntp_servers', '_read_cpu_model', '_read_privacy_state', '_reset_privacy_state_on_startup', '_write_privacy_state', 'get_ntp_handler', 'get_otg_functions_handler', 'get_timezone_list_handler', 'gui_get_param_handler', 'gui_set_param_handler', 'set_ntp_handler', 'set_otg_functions_handler', 'set_timezone_handler'
  + names (66): 'G_PROFILE', 'G_UDC', 'Lock', 'MULTILINE', 'Set', 'U_STATE', '_NTP_CONF_PATH', '_OTG_FUNC_MAP', '_SystemApi__change_otg_functions', '_SystemApi__get_current_otg_functions', '_SystemApi__get_expected_otg_functions', '_SystemApi__get_managed_otg_functions', '_SystemApi__get_otg_udc_state', '_SystemApi__is_rkipc_running', '_SystemApi__otg_apply_error', '_SystemApi__otg_applying', '_SystemApi__otg_functions_to_payload', '_SystemApi__otg_lock', '_SystemApi__wait_otg_functions_synced', '_TIMEZONE_REGIONS', '_ZONEINFO_BASE', '__annotations__', '_build_ntp_conf', '_build_timezone_list', '_get_current_timezone_name', '_get_utc_offset_minutes', '_is_valid_tz_name', '_parse_ntp_servers', '_privacy_path', '_read_cpu_model' ...
  - names (1): 'create_subprocess_shell'
  + strings (132): ' iburst', ' nomodify notrap noquery', ', current=', ', expected=', ', keep default', ', rkipc_running=', ', udc_state=', '. Valid regions: ', '.tmp', '/etc/init.d/S49ntp', '/etc/init.d/S99firewall', '/etc/init.d/S99rkipc full_start >/dev/null 2>&1', '/etc/init.d/S99rkipc full_stop', '/etc/kvmd/user/ntp.conf', '/etc/kvmd/user/privacy', '/etc/ntp.conf', '/proc', '/proc/cpuinfo', '/proc/device-tree/compatible', '/sys/kernel/config/usb_gadget', '/system/gui_get_param', '/system/gui_set_param', '/system/ntp', '/system/otg_functions', '/system/timezone', '/system/timezone/list', '/usr/share/zoneinfo', '/var/run/reset_uvc_udc.cooldown', '10000', 'Camera OTG functions not ready: rkipc_running=' ...
  - strings (13): '/etc/init.d/S99firewall restart', '/etc/init.d/S99firewall stop', 'Error getting ethernet service ID: ', 'Failed to get timezone: ', 'enable_mic', 'ethernet', 'kvmd/msd/type', 'msd_type', "msd_type param invalid, must be 'otg' or 'disabled'", 'otg/devices/audio/enabled', 'otg/devices/rndis/enabled', 'posix/Etc/GMT', '获取以太网服务ID'

#### `apps/kvmd/api/tailscale.pyc`  (32635 → 31363 B)
  + functions (9): '_get_interface_subnets', '_gui_config_handler', '_gui_get_config_handler', '_gui_get_status', '_gui_login_status_handler', '_gui_login_url_handler', '_gui_logout_handler', '_gui_start_handler', '_gui_stop_handler'
  - functions (1): '_get_eth0_subnet'
  + names (14): '_get_interface_subnets', '_gui_config_handler', '_gui_get_config_handler', '_gui_get_status', '_gui_login_status_handler', '_gui_login_url_handler', '_gui_logout_handler', '_gui_start_handler', '_gui_stop_handler', 'common', 'is_process_running', 'read_json_file', 'run_command', 'update_json_file'
  - names (11): '_get_eth0_subnet', 'communicate', 'create_subprocess_shell', 'dirname', 'dump', 'exists', 'load', 'makedirs', 'open', 'path', 'returncode'
  + strings (18): '\n        获取指定网络接口（eth0/wlan0/wwan0）的子网信息，格式为 CIDR（例如：192.168.1.0/24）\n        支持多网口，返回所有有效接口的子网列表\n        ', '/tailscale/gui_config', '/tailscale/gui_login_status', '/tailscale/gui_login_url', '/tailscale/gui_logout', '/tailscale/gui_start', '/tailscale/gui_status', '/tailscale/gui_stop', '/usr/sbin/gl_kvm_gui', 'Error getting network interface subnet information: ', 'Failed to automatically get subnet information from eth0/wlan0/wwan0', 'Got subnet from ', 'Network interface information not found', 'Network interface information: ', 'No IPv4 addresses found for target interfaces (eth0/wlan0/wwan0)', 'Total subnets found: ', 'ip -json addr show', 'tailscaled process'
  - strings (22): '\n        更新Tailscale配置文件\n        \n        Args:\n            enable: True表示启用Tailscale，False表示禁用\n        ', '\n        检查 tailscald 进程是否存在\n        ', '\n        获取Tailscale的状态信息\n        通过运行 tailscale status --json 获取\n        ', '\n        获取Tailscale的登录状态\n        使用tailscale status --json获取BackendState字段\n        ', '\n        获取eth0接口的子网信息，格式为CIDR（例如：192.168.1.0/24）\n        如果获取失败则返回None\n        ', '\n        读取Tailscale配置文件\n        ', 'Command failed: ', 'Error checking tailscald process: ', 'Error executing command: ', 'Error getting eth0 subnet information: ', 'Failed to automatically get eth0 subnet information', 'Failed to create config directory ', 'Failed to create config directory: ', 'Failed to read config file ', 'Failed to write config file ', 'Failed to write config file: ', 'No IPv4 address found for eth0 interface', 'eth0', 'eth0 interface information not found', 'eth0 interface information: ', 'ip -json addr show eth0', 'sync'

#### `apps/kvmd/api/turn.pyc`  (7891 → 8056 B)
  + names (1): '_default_turn_data'
  - strings (1): 'turnserver.json file not found'

#### `apps/kvmd/api/upgrade.pyc`  (51239 → 73928 B)
  + functions (19): '<lambda>', '__beta_download_handler', '__fetch_channel_version', '__get_edid_list_handler', '__gui_compare_handler', '__start_download_task', '_collect_one', '_find_ipv6_spans', '_is_global_ipv4', '_is_global_ipv6', '_mask_content', '_mask_public_ips', '_mask_public_ipv4', '_mask_sensitive_fields', '_subprocess_build_zip', '_try_copy', '_write_command_output', 'get_beta_base_url', 'get_beta_list_sha256_url'
  + names (65): 'BETA_BASE_URL', 'EDID_LIST_FILE', 'FileNotFoundError', 'ProcessPoolExecutor', 'Semaphore', 'ValueError', '_DIGIT_CHARS', '_HEX_CHARS', '_IPV4_TAIL_RE', '_IPV6_FULL_TAIL_RE', '_IPV6_RE', '_IPV6_TOKEN_CHARS', '_IPV6_WINDOW_CHARS', '_MASK_CHUNK_SIZE', '_SENSITIVE_RE', '_UpdateEngine__beta_base_url', '_UpdateEngine__beta_list_sha256_url', '_UpdateEngine__fetch_channel_version', '_UpgradeApi__beta_download_handler', '_UpgradeApi__get_edid_list_handler', '_UpgradeApi__gui_compare_handler', '_UpgradeApi__start_download_task', '_find_ipv6_spans', '_is_global_ipv4', '_is_global_ipv6', '_mask_content', '_mask_public_ips', '_mask_public_ipv4', '_mask_sensitive_fields', '_subprocess_build_zip' ...
  - names (16): 'BytesIO', 'SEEK_END', 'date_time', 'dump', 'getvalue', 'rmdir', 'seek', 'start_streaming', 'stream_json', 'stream_json_exception', 'tell', 'time', 'valid_bool', 'valid_url', 'validators.basic', 'validators.net'
  + strings (67): ' channel returned status code: ', ' list-sha256 format', ' list-sha256 response', ' request was cancelled', ' version information from metadata', ' version request was cancelled', ' version: ', '), falling back to thread pool', '.error', '.zip', '/etc/kvmd/edid.json', '/upgrade/beta/download', '/upgrade/edid_list', '/upgrade/gui_compare', '/usr/sbin/gl_kvm_gui', 'Beta', 'Copy error: ', 'Empty ', 'Error reading edid.json: ', 'Failed to fetch ', 'Failed to get list-sha256 from ', 'Failed to pack ', 'Invalid ', 'ProcessPool zip build failed (', 'Release', 'Unable to get ', 'application/json', 'ax_mem_cmm_info_{timestamp}.log', 'ax_pool_info_{timestamp}.log', 'ax_venc_{timestamp}.log' ...
  - strings (19): ' with original method: ', ', using fixed timestamp', 'Failed to add ', 'Failed to collect: ', 'Failed to fetch server version: ', 'Failed to get list-sha256: ', 'Log collected: ', 'Request was cancelled', 'Server returned status code: ', 'Unable to get server version information', 'Version comparison request was cancelled', '[ -f /sys/fs/pstore/console-ramoops-0 ] && cat /sys/fs/pstore/console-ramoops-0', '[ -f /sys/fs/pstore/dmesg-ramoops-0 ] && cat /sys/fs/pstore/dmesg-ramoops-0', '[ -f /sys/fs/pstore/dmesg-ramoops-1 ] && cat /sys/fs/pstore/dmesg-ramoops-1', '[ -f /tmp/channel_occupancy.json ] && cat /tmp/channel_occupancy.json', 'channel_occupancy_{timestamp}.json', 'connmanctl services 2>/dev/null | grep -oE "wifi_[^ ]+" | head -1 | xargs -I{} connmanctl services {}', '执行命令并保存结果（带故障处理）', '获取base_url'

#### `apps/kvmd/api/wol.pyc`  (14595 → 13170 B)
  - functions (1): '_valid_mac'
  + names (4): 'common', 'make_device_name_from_mac', 'run_process', 'valid_mac'
  - names (11): 'PIPE', '_MAC_RE', '_valid_mac', 'communicate', 'compile', 'create_subprocess_exec', 'decode', 'match', 're', 'returncode', 'subprocess'
  - strings (6): 'Command failed: ', 'Error executing command: ', 'Invalid MAC address format', 'Run command using exec (argument list) to avoid shell injection.', 'Validate and normalize a MAC address to prevent command injection.', '^([0-9A-Fa-f]{2}[:\\-]){5}[0-9A-Fa-f]{2}$'

#### `apps/kvmd/api/zerotier.pyc`  (19762 → 22206 B)
  + functions (8): '_auth_handler', '_gui_auth_handler', '_gui_leave_handler', '_gui_set_token_handler', '_gui_start_handler', '_gui_status_handler', '_gui_stop_handler', '_leave_handler'
  + names (15): '_auth_handler', '_gui_auth_handler', '_gui_leave_handler', '_gui_set_token_handler', '_gui_start_handler', '_gui_status_handler', '_gui_stop_handler', '_leave_handler', 'common', 'float', 'is_process_running', 'lower', 'read_json_file', 'run_command', 'update_json_file'
  - names (8): 'dirname', 'dump', 'exists', 'load', 'makedirs', 'open', 'path', 'split'
  + strings (23): '\n        获取 ZeroTier Central 首页 URL\n        ', '/usr/sbin/gl_kvm_gui', '/zerotier/auth', '/zerotier/gui_auth', '/zerotier/gui_leave', '/zerotier/gui_set_token', '/zerotier/gui_start', '/zerotier/gui_status', '/zerotier/gui_stop', '/zerotier/leave', 'All networks left and ZeroTier data reset', 'Error building zerotier auth url: ', 'Error leaving zerotier network: ', 'Invalid network ID format. Network ID must be a 16-character hexadecimal string.', 'Left network successfully', 'No network to leave', 'ZeroTier service is not running', '^[a-fA-F0-9]{16}$', 'https://central.zerotier.com/', 'reset', 'timeout', 'zerotier-cli leave ', 'zerotierd process'
  - strings (14): '\n        执行系统命令\n        ', '\n        检查 zerotierd 进程是否存在\n        ', '\n        读取配置文件\n        ', 'Command failed: ', 'Error checking zerotierd process: ', 'Error executing command: ', 'Failed to create config directory ', 'Failed to create config directory: ', 'Failed to read config file ', 'Failed to write config file ', 'Failed to write config file: ', 'pgrep', 'sync', 'zerotier-one'

#### `apps/kvmd/auth.pyc`  (33409 → 36715 B)
  + functions (2): '__consume_failed_since_last_success', 'refresh_token_expiry'
  + names (5): '_AuthManager__consume_failed_since_last_success', '_AuthManager__failed_since_last_success', 'refresh_token_expiry', 'run_command', 'tools'
  - names (2): 'create_subprocess_shell', 'threading'
  + strings (6): '-SIGUSR2', 'Logged in user %r; expire=%s, sessions_now=%d, failed_since_last_success=%d', 'Two-step login completed for user %r; expire=%s, sessions_now=%d, failed_since_last_success=%d', 'gl_kvm_gui', 'killall', '返回自上一次登录成功以来累计的全局登录失败次数，并清零计数。'
  - strings (3): 'Logged in user %r; expire=%s, sessions_now=%d', 'Two-step login completed for user %r; expire=%s, sessions_now=%d', 'killall -SIGUSR2 gl_kvm_gui'

#### `apps/kvmd/info/__init__.pyc`  (5165 → 5229 B)
  + names (1): '_unpack'
  - names (1): 'state_poll'

#### `apps/kvmd/info/extras.pyc`  (7285 → 7285 B)
  + strings (1): 'Failed to get info for service %r: %s'
  - strings (1): '无法获取服务 %r 的信息: %s'

#### `apps/kvmd/info/health.pyc`  (7210 → 7245 B)
  (bytes differ; no constant/name/function changes — line numbers or ordering only)

#### `apps/kvmd/init.pyc`  (8178 → 8872 B)
  + functions (2): 'InvalidOldPasswordError', 'WeakPasswordError'
  + names (5): 'InvalidOldPasswordError', 'ValidatorError', 'WeakPasswordError', 'valid_new_passwd', 'validators'
  + strings (5): 'InvalidOldPasswordError', 'New password does not meet complexity requirements', 'Old password does not match', 'Password does not meet complexity requirements', 'WeakPasswordError'
  - strings (3): 'Invalid old password', 'New password is invalid', 'Password is required'

#### `apps/kvmd/logreader.pyc`  (2769 → 2930 B)
  + names (1): 'log_file'
  + strings (3): 'backup_count', 'log_file', 'max_bytes'
  - strings (1): '/var/log/kvmd.log'

#### `apps/kvmd/ocr.pyc`  (10005 → 14501 B)
  + functions (6): '__rknn_recognize', '__tess_recognize', '_rknn_recognize_params', '_rknn_sock_available', '_sock_recv_all', '_use_rknn'
  - functions (1): '__inner_recognize'
  + names (26): 'AF_UNIX', 'ConnectionRefusedError', 'FileNotFoundError', 'OSError', 'SOCK_STREAM', 'S_ISSOCK', '_Ocr__rknn_recognize', '_Ocr__rknn_socket', '_Ocr__tess_recognize', '_RKNN_SOCK_TIMEOUT', '_STATIC_LIBTESSERACT_PATHS', '_rknn_recognize_params', '_rknn_sock_available', '_sock_recv_all', '_use_rknn', 'connect', 'dumps', 'isdir', 'json', 'pack', 'recv', 'sendall', 'settimeout', 'socket', 'struct', 'unpack'
  - names (3): '_Ocr__inner_recognize', 'contextmanager', 'static_libtesseract_path'
  + strings (14): 'TessBaseAPIDelete', 'ocr_service error: ', 'ocr_service socket unavailable (', 'ocr_service 自行从固定路径 /run/kvmd/ustreamer.sock 获取截图并 OCR。\n        ocr.py 只传递裁剪坐标。\n        ', 'ocr_service: connection closed unexpectedly', 'params', 'replace', 'rknn', 'rknn_socket', 'sock', 'sock_path', '将 JSON 参数发给 ocr_service，service 自行取图并识别，返回识别文本', '检查 ocr_service Unix socket 是否存在且可连接', '若 rknn_socket 已配置且 socket 文件存在则使用 RKNN 模式'
  - strings (2): '/usr/lib/libtesseract.so.3.0.5', "Can't find libtesseract"

#### `apps/kvmd/server.pyc`  (25852 → 43447 B)
  + functions (8): '__enter_adaptive_mode', '__exit_adaptive_mode', '__hid_ws_handler', '__kill_proc_graceful', '__refresh_token_from_ws', '__webrtc_client_log_pipe', '__webrtc_client_watchdog', '_write_and_log'
  + names (68): 'BaseException', 'CancelledError', 'CustomScreenApi', 'DEVNULL', 'LOG_INFO', 'LOG_NDELAY', 'LOG_PID', 'LOG_USER', 'NetbirdApi', 'PIPE', 'Path', 'RecorderApi', 'STDOUT', 'SerialApi', 'StreamReader', '_KvmdServer__EV_RECORDER_STATE', '_KvmdServer__EV_SERIAL_STATE', '_KvmdServer__adaptive_mode', '_KvmdServer__custom_screen_api', '_KvmdServer__enter_adaptive_mode', '_KvmdServer__exit_adaptive_mode', '_KvmdServer__hid_ws_handler', '_KvmdServer__kill_proc_graceful', '_KvmdServer__recorder_api', '_KvmdServer__refresh_token_from_ws', '_KvmdServer__serial_api', '_KvmdServer__webrtc_client_cmd', '_KvmdServer__webrtc_client_log_pipe', '_KvmdServer__webrtc_client_proc', '_KvmdServer__webrtc_client_task' ...
  - names (1): 'create_subprocess_shell'
  + strings (47): '%s already exited before SIGKILL (rc=%d)', '%s not running (killall -TERM rc=%d), skipping SIGKILL', '-SIGUSR1', '-TERM', '/hid/ws', '/tmp/kvmd_janus_disable', '/usr/bin/gl-pion', '/usr/bin/webrtc_client', '/var/log/kvmd.log', 'Adaptive mode activated', 'Adaptive mode deactivated', 'Entering adaptive mode: killing janus and ustreamer, starting webrtc_client ...', 'Exiting adaptive mode: stopping webrtc_client ...', 'Failed to enter adaptive mode, rolling back state ...', 'Failed to remove /tmp/kvmd_janus_disable: %s', 'Failed to send SIGKILL to %s: %s', 'Failed to send SIGTERM to %s: %s', 'Failed to write /tmp/kvmd_janus_disable: %s', 'Recorder', 'Refresh token expiry from WebSocket session (sliding expiration)', 'Removed /tmp/kvmd_janus_disable, JanusRunner may resume', 'Sent SIGKILL to %s', 'Sent SIGTERM to %s, waiting 500ms ...', 'Serial', 'Starting webrtc_client: %s (log: %s)', 'Wrote /tmp/kvmd_janus_disable to suppress JanusRunner auto-restart', 'gl-pion', 'gl_kvm_gui', 'gl_webrtc', 'janus' ...
  - strings (1): 'killall -SIGUSR1 gl_kvm_gui'

#### `apps/kvmd/streamer.pyc`  (29357 → 30229 B)
  + names (5): '_StreamerParams__VENC_MODE', 'exists', 'os', 'path', 'run_async'
  + strings (3): '/tmp/kvmd_janus_disable', 'need_ustreamer=1 ignored: webrtc_client adaptive mode is active', 'venc_mode'

#### `apps/kvmd/switch/__init__.pyc`  (25985 → 26550 B)
  + functions (1): '__maybe_await'
  + names (4): '_Switch__maybe_await', 'inspect', 'isawaitable', 'staticmethod'

#### `apps/kvmd/switch/sysfs_chain.pyc`  (7753 → 7928 B)
  + names (1): 'async_request_switch'
  - names (1): 'request_switch'

#### `apps/kvmd/switch/sysfs_device.pyc`  (11460 → 19083 B)
  + functions (8): '_async_set_channel', '_async_simple_switch_channel', '_async_sleep', '_async_wait_udc_device', '_find_usb_port', '_get_current_udc', '_udc_has_device', 'async_request_switch'
  - functions (2): 'request_switch', 'set_channel'
  + names (30): 'DWC3_BIND_FILE', 'DWC3_DEVICE_ID', 'DWC3_DRIVER_DIR', 'DWC3_UNBIND_FILE', 'GADGET_UDC_FILE', 'HDMIPATH', 'OSError', 'UDC_CLASS_DIR', 'USB_BIND_FILE', 'USB_DEVICES_DIR', 'USB_DRIVER_DIR', 'USB_HOST_CHANNEL_FILE', 'USB_HOST_POWER_FILE', 'USB_UNBIND_FILE', '_async_set_channel', '_async_simple_switch_channel', '_async_sleep', '_async_wait_udc_device', '_find_usb_port', '_get_current_udc', '_udc_has_device', 'async_request_switch', 'error', 'float', 'get_logger', 'info', 'lib', 'monotonic', 'time', 'warning'
  - names (3): 'get_usb_status', 'request_switch', 'set_channel'
  + strings (36): '\n        Async switch request for aiohttp/KVMD call chains.\n        ', ' 异步版本：供KVMD异步接口/协程使用，不阻塞事件循环 ', ' 异步睡眠：供协程调用链使用，不阻塞事件循环 ', '/channel', '/hdmi_status', '/sys/bus/i2c/devices/', '/sys/bus/platform/drivers/dwc3', '/sys/bus/usb/devices', '/sys/bus/usb/drivers/usb', '/sys/class/udc', '/sys/kernel/config/usb_gadget/rockchip/UDC', '/usb_host_channel', '/usb_host_power', '/usb_otg_status', '21500000.usb', '3-0058', 'bind', 'bind gadget UDC: ', 'device_id', 'interval', 'none', 'seconds', 'set_channel: DWC3 bind failed: %s', 'set_channel: DWC3 unbind failed (ignored): %s', 'set_channel: USB bind failed (ignored): %s', 'set_channel: USB unbind failed (ignored): %s', 'set_channel: async_simple_switch_channel path=%s value=0', 'set_channel: ch=%s udc_ready=%s', 'set_channel: ch=%s wait_udc_device', 'set_channel: full dwc3 switch finished, ch=%s' ...
  - strings (4): '\n        unit is ignored (single device).\n        ', '/sys/bus/i2c/devices/3-0058/channel', '/sys/bus/i2c/devices/3-0058/hdmi_status', '/sys/bus/i2c/devices/3-0058/usb_otg_status'

#### `apps/otg/__init__.pyc`  (26537 → 33197 B)
  + functions (3): '_cleanup_uvc_function', 'add_camera', 'add_touch'
  + names (19): 'OSError', '_GadgetConfig__func_order', '_cleanup_uvc_function', 'add_camera', 'add_touch', 'camera', 'exists', 'glob', 'hid.touch', 'isdir', 'islink', 'lower', 'make_touch_hid', 'path', 'read', 'start_cdrom', 'start_flash', 'strip', 'touch'
  + strings (36): '/proc/gl-hw-info/model', '333333\n666666\n1000000\n2000000', '576p', '===== Camera =====', '===== HID-Touch =====', '===== Microphone %s =====', 'Touch Screen', 'UVC_CLEAN - %s', 'UVC_CLEAN - [SKIPPED] %s: %s', 'Uvc Camera', '\\.gs\\d+$', 'bBitsPerPixel', 'bDeviceClass', 'bDeviceProtocol', 'bDeviceSubClass', 'configs/b.1', 'control/class/fs/h', 'control/class/ss/h', 'control/header/h', 'dwDefaultFrameInterval', 'dwFrameInterval', 'dwMaxBitRate', 'dwMaxVideoFrameBufferSize', 'dwMinBitRate', 'guidFormat', 'rmq1', 'streaming/class/fs/h', 'streaming/class/hs/h', 'streaming/class/ss/h', 'streaming/header/h' ...
  - strings (1): '===== Microphone ====='

#### `apps/otgconf/__init__.pyc`  (13414 → 19367 B)
  + functions (2): '<lambda>', '__find_dwc3'
  + names (13): 'EBUSY', 'OSError', '_GadgetControl__find_dwc3', 'any', 'basename', 'dirname', 'errno', 'get', 'get_udc_path', 'monotonic', 'order', 'realpath', 'tuple'
  + strings (7): '--   WARN -- Failed to link function ', 'Cannot find DWC3 driver for UDC ', 'bind', 'device', 'driver', 'order', 'unbind'

#### `apps/otgnet/__init__.pyc`  (11847 → 13448 B)
  + names (2): 'all', 'gather'

#### `apps/swctl/__init__.pyc`  (7845 → 7928 B)
  + names (3): 'async_request_switch', 'asyncio', 'run'
  - names (1): 'request_switch'

#### `htserver.pyc`  (29370 → 30046 B)
  + functions (2): 'FilteredAccessLogger', 'log'
  + names (3): 'FilteredAccessLogger', 'log', 'startswith'
  + strings (5): 'FilteredAccessLogger', 'exe:', 'request', 'response', 'time'

#### `keyboard/printer.pyc`  (3671 → 6244 B)
  + functions (2): '_ch_to_keysym_fallback', '_try_dead_key_decompose'
  + names (15): 'AttributeError', 'KEY_LEFTCTRL', 'OSError', 'ValueError', '_COMBINING_TO_DEAD_KEYSYM', '__annotations__', '_ch_to_keysym_fallback', '_try_dead_key_decompose', 'chr', 'decomposition', 'get', 'list', 'split', 'startswith', 'unicodedata'
  - names (1): 'RuntimeError'
  + strings (1): '_COMBINING_TO_DEAD_KEYSYM'
  - strings (2): 'Where is libc.', 'Where is libxkbcommon?'

#### `plugins/atx/glatx.pyc`  (9329 → 9305 B)
  + names (1): 'join'
  + strings (3): 'ATX state changed: ', 'Error monitoring ATX device state: ', 'power_state'
  - strings (3): ' power_state', 'ATX状态变化: ', '监测ATX设备状态时出错: '

#### `plugins/hid/__init__.pyc`  (12382 → 15824 B)
  + functions (6): '__is_in_schedule', '__update_jiggler_active', '_send_touch_event', 'send_touch_event', 'set_jiggler_interval', 'set_jiggler_schedule'
  + names (18): '_BaseHid__is_in_schedule', '_BaseHid__j_button_active', '_BaseHid__j_in_schedule', '_BaseHid__j_schedule', '_BaseHid__update_jiggler_active', '_send_touch_event', 'datetime', 'get_logger', 'hour', 'info', 'logging', 'map', 'minute', 'now', 'send_touch_event', 'set_jiggler_interval', 'set_jiggler_schedule', 'split'
  + strings (8): 'Mouse jiggler started', 'Mouse jiggler stopped', 'interval', 'periods', 'start', 'touching', '计算最终 jiggler 状态：OR 逻辑 - 任一方开启则开启', '设置按钮决定的 jiggler 状态'

#### `plugins/hid/otg/__init__.pyc`  (15193 → 25099 B)
  + functions (6): '__clear_mouse_state', '__clear_touch_state', '__get_hybrid_mouse_abs', '__get_hybrid_mouse_rel', '__get_mouse_outputs_available', '_send_touch_event'
  + names (25): 'BTN_LEFT', 'TouchProcess', '_Plugin__clear_mouse_state', '_Plugin__clear_touch_state', '_Plugin__get_hybrid_mouse_abs', '_Plugin__get_hybrid_mouse_rel', '_Plugin__get_mouse_outputs_available', '_Plugin__hybrid_mode', '_Plugin__mouse_abs', '_Plugin__mouse_device_paths', '_Plugin__mouse_rel', '_Plugin__touch_device_path', '_Plugin__touch_mode', '_Plugin__touch_proc', '_Plugin__touch_sim_down', '_Plugin__touch_sim_x', '_Plugin__touch_sim_y', '_send_touch_event', 'ecodes', 'evdev', 'get', 'keys', 'send_touch_event', 'touch', 'warning'
  + strings (19): '/dev/hidg3', 'HID mouse [relative]: dropped in hybrid mode (delta_x=%d delta_y=%d)', 'HID mouse: entered hybrid mode (move -> %s [%s], button/wheel -> %s [%s])', 'HID mouse: entered touch mode (events -> usb_touch [%s])', 'HID mouse: left hybrid mode', 'HID mouse: left touch mode', 'HID touch [button]: button=%d state=%s | device=%s', 'HID touch [button]: dropped button=%d state=%s in touch mode', 'HID touch [event]: dropped, no touch device', 'HID touch [event]: to_x=%d to_y=%d touching=%s | device=%s', 'HID touch [move]: to_x=%d to_y=%d touching=%s | device=%s', 'HID touch [relative]: dropped in touch mode (delta_x=%d delta_y=%d)', 'HID touch [wheel]: dropped in touch mode (delta_x=%d delta_y=%d)', 'Hybrid mouse mode requires mouse_alt device', 'Touch mouse mode requires touch device', 'touch', 'touching', 'usb_hybrid', 'usb_touch'

#### `plugins/hid/otg/device.pyc`  (14655 → 14911 B)
  + names (1): 'FileNotFoundError'

#### `plugins/hid/otg/events.pyc`  (7494 → 8949 B)
  + functions (2): 'TouchEvent', 'make_touch_report'
  + names (2): 'TouchEvent', 'make_touch_report'
  + strings (3): '<BHH', 'TouchEvent', 'touching'

#### `plugins/msd/__init__.pyc`  (18884 → 19045 B)
  + functions (1): 'get_storage_root'
  + names (1): 'get_storage_root'

#### `plugins/msd/otg/__init__.pyc`  (62499 → 72574 B)
  + functions (3): '__is_tf_card_device', 'get_storage_root', 'switch_partition'
  + names (13): 'MsdOperationError', '_Plugin__is_tf_card_device', '_Plugin__remount_cmd', '_emmc_base_dev', '_media_part_name', 'get_mount_points', 'get_storage_root', 'group', 'match', 'read', 'switch_partition', 'update', 'upper'
  + strings (38): ' (resolved: ', ' already mounted at ', ' also mounted at ', ' at ', ' does not exist', ' failed, rolling back to ', '(mmcblk\\d+)p(\\d+)$', ', skip umount/mount', ', umount before remount', '/dev/mmcblk\\d+p\\d+$', '/device/type', '/sys/block/', 'Detected removable storage change: %s/%s', 'Partition device %r (resolved: %r) does not exist, falling back to default %r', 'Triggering udev rescan after formatting ', '_emmc_base_dev', 'base_dev', 'device ', 'device parameter cannot be empty', 'failed to mount ', 'mmcblk', 'mmcblk0', 'mmcblk\\d+p\\d+$', 'mtdblock10', 'new_device', 'no known mount point for device ', 'switch_partition: ', 'switch_partition: boot.yaml updated, partition_device=', 'switch_partition: failed to persist to boot.yaml: ', 'switch_partition: mount ' ...
  - strings (2): 'Detected USB device change: %s', 'mmcblk0p16'

#### `utils.pyc`  (1807 → 2201 B)
  + names (3): '_DESKTOP_APP_UA', '_MOBILE_APP_UA', '_user_agents'
  + strings (4): 'AndroidMobileApp', 'IOSMobileApp', 'MacDesktopApp', 'WinDesktopApp'

#### `validators/auth.pyc`  (2316 → 3128 B)
  + functions (1): 'valid_new_passwd'
  + names (5): 'bool', 'raise_error', 're', 'search', 'valid_new_passwd'
  + strings (7): '[0-9]', '[A-Z]', '[^A-Za-z0-9]', '[a-z]', '^[\\x20-\\x7e]{10,63}\\Z$', '^[\\x20-\\x7e]{5,63}\\Z$', 'passwd complexity'
  - strings (1): '^[\\x20-\\x7e]*\\Z$'

#### `validators/hid.pyc`  (1910 → 3811 B)
  + functions (3): 'valid_hid_jiggler_interval', 'valid_hid_jiggler_schedule', 'valid_hid_jiggler_time'
  + names (14): 'Exception', 'ValueError', 'append', 'dict', 'get', 'isinstance', 'len', 'list', 'raise_error', 'split', 'strip', 'valid_hid_jiggler_interval', 'valid_hid_jiggler_schedule', 'valid_hid_jiggler_time'
  + strings (5): 'jiggler interval', 'jiggler period (object with start/end)', 'jiggler schedule (list of periods)', 'jiggler time (HH:MM)', 'start'

#### `validators/kvm.pyc`  (5175 → 5399 B)
  + functions (1): 'valid_stream_venc_mode'
  + names (1): 'valid_stream_venc_mode'
  + strings (3): 'normal', 'smart', 'stream venc mode'

#### `yamlconf/loader.pyc`  (4289 → 5059 B)
  + functions (1): '__safe_merge'
  + names (5): '_YamlLoader__safe_merge', 'dict', 'print', 'stderr', 'sys'
  + strings (3): ' due to parse error: ', 'WARNING: Skipping config file ', 'tree'

## /etc/kvmd: 1 added, 27 removed, 11 changed, 28 identical

### Added

- `edid.json` (10052 B)

### Removed (includes our own provisioning artefacts on the old side)

- `nginx-kvmd.conf.orig` (2720 B)
- `override.yaml.orig` (1327 B)
- `user/config.json` (1974 B)
- `user/connman/ethernet_9483c4caf26e_cable/settings` (178 B)
- `user/connman/settings` (196 B)
- `user/connman/wifi_9483c4caf26f_435942455244594e45_managed_psk.config` (130 B)
- `user/connman/wifi_9483c4caf26f_435942455244594e45_managed_psk/settings` (410 B)
- `user/edid.txt` (904 B)
- `user/edid_updated` (2 B)
- `user/init_state.json` (16 B)
- `user/ocr-installed.txt` (1308 B)
- `user/scripts/S99kvmd-ipmi` (3634 B)
- `user/scripts/S99kvmd-vnc` (3616 B)
- `user/ssl/server.crt` (696 B)
- `user/ssl/server.key` (302 B)
- `user/tailscale.json` (22 B)
- `user/tailscale/derpmap.cached.json` (15055 B)
- `user/tailscale/profile-data/6c82/netmap-cache/646572706d6170` (15067 B)
- `user/tailscale/profile-data/6c82/netmap-cache/646e73` (211 B)
- `user/tailscale/profile-data/6c82/netmap-cache/66696c746572` (178 B)
- `user/tailscale/profile-data/6c82/netmap-cache/6d736963` (274 B)
- `user/tailscale/profile-data/6c82/netmap-cache/73656c66` (1116 B)
- `user/tailscale/profile-data/6c82/netmap-cache/737368` (667 B)
- `user/tailscale/profile-data/6c82/service-client-prefs/736572766963652d636c69656e742d7072656673` (2 B)
- `user/tailscale/tailscaled.state` (2726 B)
- `user/vnc.enable` (0 B)
- `user/wol_list.json` (152 B)

### Vendor-to-vendor: old `.orig` vs new file

- `nginx-kvmd.conf`: vendor file changed:
```diff
--- 1.8.1 vendor
+++ 1.10.0 vendor
@@ -72,3 +72,3 @@
 #                include /usr/share/kvmd/extras/*/nginx.ctx-server.conf;
-                
+
 #                location /connect {
@@ -85,3 +85,3 @@
                 include /usr/share/kvmd/extras/*/nginx.ctx-server.conf;
-                
+
                 location /connect {
@@ -91,2 +91,32 @@
 
+        # Janus TURN REST API：直接由 nginx 提供 /tmp/turnserver.json，
+        # 取代原 janusRestAPIServer.py 常驻 Python 进程以节省内存。
+        # 文件不存在时返回合法的空 TURN 配置，使 Janus 立即跳过 TURN 候选收集，
+        # 避免 ICE gathering 因 "missing username" 超时等待 (~5s)。
+        server {
+                listen 127.0.0.1:8081;
+
+                location = /turnserver.json {
+                        root /tmp;
+                        default_type application/json;
+                        try_files $uri @empty_turn;
+                }
+
+                location = /turnserver {
+                        root /tmp;
+                        default_type application/json;
+                        try_files /turnserver.json @empty_turn;
+                }
+
+                location = /health {
+                        default_type application/json;
+                        return 200 '{"status":"ok","service":"nginx turn rest"}';
+                }
+
+                location @empty_turn {
+                        default_type application/json;
+                        return 200 '{"username":"","password":"","ttl":86400,"uris":[]}';
+                }
+        }
+
 }
```
- `override.yaml`: vendor file **unchanged** between firmwares

### Changed (old side may carry our provisioning)

- `ipmipasswd`:
```diff
--- old
+++ new
@@ -13,2 +13,2 @@
 
-admin:admin -> admin:<redacted>
+admin:admin -> admin:<redacted>
```
- `janus/janus.plugin.ustreamer.jcfg`:
```diff
--- old
+++ new
@@ -4,3 +4,3 @@
 acap: {
-	device = "hw:0,0"
+	device = "multi_hdmi_input"
 	tc358743 = "/dev/video0"
```
- `main.yaml`:
```diff
--- old
+++ new
@@ -26,3 +26,11 @@
         h264_bitrate:
-            default: 10000
+            default: 2000
+        pre_start_cmd:
+            - "/bin/sh"
+            - "-c"
+            - "pkill -USR1 -f /usr/sbin/lt86102sxe_setup 2>/dev/null || true"
+        post_stop_cmd:
+            - "/bin/sh"
+            - "-c"
+            - "pkill -USR2 -f /usr/sbin/lt86102sxe_setup 2>/dev/null || true"
         cmd:
@@ -53,2 +61,3 @@
             - "--zero-delay={zero_delay}"
+            - "--venc-mode={venc_mode}"
             # - "--rv1126-sink=kvmd::ustreamer::rv1126"
```
- `nginx/gl.ctx-server.conf`:
```diff
--- old
+++ new
@@ -21,2 +21,3 @@
 	proxy_pass http://kvmd$auth_check_uri;
+	client_max_body_size 0;
 	proxy_pass_request_body off;
@@ -135,2 +136,11 @@
 
+location /api/custom_screen/update_background {
+	rewrite ^/api/custom_screen/update_background$ /custom_screen/update_background break;
+	rewrite ^/api/custom_screen/update_background\?(.*)$ /custom_screen/update_background?$1 break;
+	proxy_pass http://kvmd;
+	include /etc/kvmd/nginx/loc-proxy.conf;
+	include /etc/kvmd/nginx/loc-bigpost.conf;
+	auth_request off;
+}
+
 location /api/log {
@@ -151,2 +161,11 @@
 	client_max_body_size 32k;
+	auth_request off;
+}
+
+location /api/serial/ws {
+	rewrite ^/api/serial/ws$ /serial/ws break;
+	rewrite ^/api/serial/ws\?(.*)$ /serial/ws?$1 break;
+	proxy_pass http://kvmd;
+	include /etc/kvmd/nginx/loc-proxy.conf;
+	include /etc/kvmd/nginx/loc-websocket.conf;
 	auth_request off;
```
- `nginx/kvmd.ctx-server.conf`:
```diff
--- old
+++ new
@@ -141,2 +141,11 @@
 
+location /api/serial/ws {
+	rewrite ^/api/serial/ws$ /serial/ws break;
+	rewrite ^/api/serial/ws\?(.*)$ /serial/ws?$1 break;
+	proxy_pass http://kvmd;
+	include /etc/kvmd/nginx/loc-proxy.conf;
+	include /etc/kvmd/nginx/loc-websocket.conf;
+	auth_request off;
+}
+
 location /api {
```
- `nginx/loc-webdav-cors.conf`:
```diff
--- old
+++ new
@@ -8,2 +8,4 @@
     add_header 'Content-Length' 0;
+    add_header 'DAV' '1, 2';
+    add_header 'Allow' 'OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK';
     return 204;
```
- `nginx/webdav.conf`:
```diff
--- old
+++ new
@@ -10,2 +10,9 @@
 
+    client_max_body_size 0;
+    proxy_request_buffering off;
+
+    proxy_set_header Destination $http_destination;
+    proxy_set_header Depth $http_depth;
+    proxy_set_header Overwrite $http_overwrite;
+
     proxy_pass http://127.0.0.1:8080/;
```
- `user/boot.yaml`:
```diff
--- old
+++ new
@@ -1,9 +0,0 @@
-kvmd:
-  msd:
-    partition_device: /dev/disk/by-uuid/95B2-489F
-otg:
-  manufacturer: Glinet
-  product: Glinet Composite Device
-  product_id: 260
-  serial: CAFEBABE
-  vendor_id: 7531
```
- `user/htpasswd`:
```diff
--- old
+++ new
@@ -1 +1 @@
-admin:<redacted-hash>
+admin:<redacted-hash>
```


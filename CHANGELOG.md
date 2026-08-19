# Changelog

All notable changes to this project are documented in this file.

## v0.2.15 - 2026-08-19

Hardening（中优先级）：状态原子性与互斥、运维参数严格校验。

- 状态互斥：新增 `gps_with_state_lock`（flock 优先，无 flock 环境 mkdir 自旋回退），CLI 与 traffic timer 的所有 state/timer 变更串行化；同进程重入直接执行，防自死锁。
- 原子写：state.env 经同目录临时文件 + `mv -f` 原子替换，读端不再可能看到半写文件。
- IPv4 严格校验：四段且每段 0-255（`999.0.0.1` 等被拒绝），install/change ip 全部收口。
- IPv6 严格校验：python3 `ipaddress` 校验；用户显式输入在缺 python3 时给出可操作安装提示，自动探测值降级为告警。
- 流量阈值配对校验：warn/stop 均需 1-100 且 warn < stop，任一变更前先校验配对，不再允许写入 95/80 这类倒挂配置。

## v0.2.14 - 2026-08-19

Hardening（高优先级）：输入校验、JSON/state 注入防护、下载完整性校验。

- Install: `--prefix` 无条件强制 `GPS_NO_SYSTEMD=1`，不再继承外部环境值。
- 输入校验：install 与 change 的 port（1-65535）/UUID（v1-v5 格式）/passwd/name/kiwivm 均拒绝换行回车，ip/ip6 落盘前校验。
- JSON 注入防护：config.json 中 UUID/密码/证书路径/日志路径经 `gps_json_escape` 转义（反斜杠/引号/控制字符）。
- State 注入防护：state.env 与 KiwiVM 凭证改用 `printf %q` 序列化 + 同目录 mktemp 原子写入（600）；`$(...)`、引号等元字符严格按数据往返，不再被 source 解释执行。
- State 加载防护：拒绝 source 符号链接；生产模式要求文件属主为当前用户且无组/其他写权限。
- TUIC URL：UUID 与密码经百分号编码后再生成分享链接。
- 下载完整性：sing-box 归档解压前用 GitHub Release API 的 sha256 digest 做校验（清单条目缺失/重复/不匹配一律拒绝）；上游未发布 checksum 文件，digest 由 GitHub 计算。
- 静态检查：补齐 shellcheck SC2034 抑制（跨 source 变量）、shfmt 全仓格式化。

## v0.2.2 - 2026-07-20

- CI: added GitHub Actions workflow running shfmt, shellcheck and bats tests; CI now runs bats with TAP output.
- Code style: applied shfmt across the repo and suppressed intentional shellcheck SC2034 for sourced variables.
- Tests: added bats tests covering config generation, state handling, and KiwiVM traffic guard (warn/stop/resume).
- TUIC: include users.name in inbound (uses machine hostname), add auth_timeout; TUIC URL generation now includes name parameter.
- URL/QR: ensure qrencode is an optional dependency in ensure_deps and gps_cmd_url prints URLs with hostname name param.
- Version bumped to v0.2.2 and added this changelog entry.

(See git history for detailed commits.)

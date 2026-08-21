# Changelog

All notable changes to this project are documented in this file.

## v0.2.31 - 2026-08-21

功能：Node 自动发现列表 + 心跳在线状态。

- 登记/upsert 写入 `last_seen`；Master 提供 `POST /v1/heartbeat`；成员周期 `sync-master` 即心跳。
- `mesh show`（菜单 25）显示节点列表：`在线` / `离线` / `在线(本机)`，并统计心跳活动可用数。
- WireGuard 默认只纳入心跳窗口内（`MESH_PEER_STALE_SEC`，默认 180s）的在线节点（`MESH_WG_LIVE_ONLY=1`）。

## v0.2.30 - 2026-08-21

功能：菜单填写 Master / Node，相互发现。

- 菜单 **26) Mesh 角色**：选本机为 Master，或选 Node 并填写 Master 公网地址（域名/IPv4/IPv6）+ TOKEN。
- CLI：`mesh role master`、`mesh role member <地址> <TOKEN>` / `mesh join ...`
- Node 加入后向 Master 注册并拉 peers，双方自动出现在 `peers.json`。

## v0.2.29 - 2026-08-21

体验：分清公网地址与 WG overlay；NODE_ID 域名自动作 Master host。

- `mesh show` 标明 overlay 为「WG 内部虚拟网，非公网」，并单独列出公网 IPv4/IPv6。
- `MESH_MASTER_HOST` 未设置时，除 TUIC_NAME 外也可沿用像域名的 `NODE_ID`（如 tile3.zeromaps.cn）。

## v0.2.28 - 2026-08-21

功能：Master 加入地址双栈 + 域名。

- 对外 join 同时给出 IPv4 / IPv6 / 域名（任选可通即可）；`10.66.0.0/16` 仍为内部 WG overlay，不手填。
- `MESH_MASTER_HOST`：`change mesh-master-host <域名>`；若未设置且节点名（`change name`）含点，自动沿用为域名。
- `mesh show` / 安装 / 菜单升级后打印全部加入命令。

## v0.2.27 - 2026-08-21

修复：菜单「升级管理脚本」后组网立刻就绪。

- `upgrade self`（菜单 20）在换新脚本后，用**磁盘上的新入口**执行 `mesh ensure`，避免菜单进程仍持有升级前的旧函数而跳过初始化。
- 升级结束打印 Master join URL（若本机为 master）。

## v0.2.26 - 2026-08-21

修复：组网必须在启动时自动初始化，无需手工 `mesh ensure`。

- `gps_svc_boot` / 无 systemd 前台启动：启动前强制 `mesh ensure` 并落盘（密钥、overlay、peers、config）。
- `geoproxy-tuic` 的 `ExecStartPre` 改为硬依赖 ensure（去掉 `-` 忽略失败）。
- `mesh show`：展示前自动 ensure；Master 显示公网 join URL + TOKEN 加入命令（不再显示无意义的 `local`）。

## v0.2.25 - 2026-08-21

功能：组网随主服务开机 + Master 发现（零菜单）。

- 每台机器安装后配置始终含 WireGuard `endpoints` + overlay `route`（不再依赖 `change profile`）。
- **Master**：无 `GPS_MESH_MASTER` 时自动升主；`geoproxy-mesh-master.service` 提供 `POST /v1/register`、`GET /v1/peers`、`GET /v1/health`（Bearer `MESH_CLUSTER_TOKEN`，端口 19527）。
- **Member**：`GPS_MESH_MASTER=http://IP:19527 GPS_MESH_TOKEN=...` 安装；开机 `ExecStartPre: mesh ensure` 注册并拉 peers；`geoproxy-mesh-sync.timer` 周期同步。
- CLI：`mesh ensure` / `mesh sync-master`；`mesh show|export` 保留排障；PROFILE 切换废弃。
- 文档：更新 mesh 规格与 `docs/design.md`。

## v0.2.24 - 2026-08-21

功能：WireGuard mesh 组网（计划 Phase A–D 一次性落地）。

- `PROFILE=edge|mesh-member`：默认 edge 与既有「入站→direct」兼容；mesh-member 启用 `endpoints.wireguard` + overlay `route`。
- Mesh CLI：`mesh init|show|peer add/rm|export|import|sync|hop`；`change profile` / `change mesh-exit`。
- 节点互知：`/etc/geoproxy-server/mesh/peers.json`（schema=1）；sync 支持本地文件或 HTTP(S) URL。
- L3 跳板：`MESH_EXIT_NODE_ID` 仅给该 peer 注入 `0.0.0.0/0`（防环，禁止指向自己）。
- L7：`mesh hop <json-file>` 注入额外 outbound（可含 `detour`）。
- doctor：mesh-member 下检查 peers/WG/overlay/exit 环路。
- 文档：[`docs/superpowers/specs/2026-08-21-mesh-design.md`](./docs/superpowers/specs/2026-08-21-mesh-design.md)。

## v0.2.23 - 2026-08-21

功能：Phase 2 扩展入站协议 + Phase 3 非目标文档固化。

- 启用协议：`vmess`、`anytls`、`hysteria`（v1）、`naive`、`snell`、`shadowtls`（外层 v3 + 本机 `ss-inner` detour）。
- 文档：`docs/design.md` 协议矩阵与明确非目标（tun/tproxy/redirect/cloudflared/direct inbound、公网 mixed/socks/http、多出站路由）。
- 测试：扩展协议列表、各 type 渲染、ShadowTLS 双 inbound JSON。

## v0.2.22 - 2026-08-21

功能：Phase 1 多协议入站（在 v0.2.21 插件框架之上）。

- 新增协议模块：`hysteria2`、`vless`（Reality）、`trojan`、`shadowsocks`（默认 2022-blake3-aes-128-gcm）。
- CLI / 菜单：`change protocol <id>`、`install --protocol <id>`、`protocols`；分享 URL / 二维码按当前协议分发。
- 共享助手 `lib/protocols/_common.sh`（TLS 片段、公网 host 迭代、Reality / SS2022 凭证生成）。
- state 持久化 Reality / SS / Hysteria 等相关字段；旧安装仍默认 `PROTOCOL=tuic`。
- 文档：[`docs/superpowers/specs/2026-08-21-multi-protocol-design.md`](./docs/superpowers/specs/2026-08-21-multi-protocol-design.md)。

## v0.2.21 - 2026-08-21

架构：入站协议插件框架（Phase 0），运行时行为与 v0.2.20 的 TUIC 单协议安装兼容。

- 新增 `lib/protocols/_registry.sh` 与 `lib/protocols/tuic.sh`：配置生成与分享链接经协议注册表分发；当前白名单仅 `tuic`。
- `state.env` 增加 `PROTOCOL`（缺省 / 旧安装无字段 → `tuic`）；未知协议在写配置前失败关闭。
- `lib/config.sh` 只负责日志、双栈监听与拼装 `config.json`，不再内嵌 TUIC JSON。
- 文档：`docs/design.md` 补充产品模型；规格与计划见 `docs/superpowers/specs/2026-08-21-protocol-plugin-design.md`、`docs/superpowers/plans/2026-08-21-protocol-plugin-phase0.md`。
- 测试：新增 `tests/test_protocol.bats`（遗留 state 默认、拒绝未知协议、TUIC 渲染）。
- 明确非目标：本版本不增加第二协议、不提供 `change protocol`、不改名 `geoproxy-tuic.service`。

## v0.2.20 - 2026-08-20

修复：logrotate 缺失时自动安装，不再跳过日志轮转。

- 生产模式检测到未安装 logrotate 时，自动经 apt-get / yum / dnf 安装（新增 `ensure_logrotate`），安装后照常部署轮转配置。
- logrotate 同时纳入 `ensure_deps` 通用依赖清单：全新安装时与 curl / openssl / tar 一起自动装齐。
- 极端情况（无包管理器或安装失败）不再"跳过"，而是照写 `/etc/logrotate.d/geoproxy-server` 配置并给出告警——logrotate 装好后配置即自动生效。

## v0.2.19 - 2026-08-19

修复：显式日志级别被启动逻辑静默覆盖。

- `change log`（菜单 13）设置 `info/warn/error/fatal/panic` 后，`gps_svc_boot` 里的 `gps_bump_log_level_if_quiet` 会把级别静默抬回 `debug`，导致用户的显式选择永远不生效（进程其实重启了，但配置被翻转）。现在 `change log` 在 state.env 记录 `LOG_LEVEL_EXPLICIT=1`，boot 时检测到显式标记则不再动日志级别；从未显式设置过的旧安装仍保持自动抬 debug 的行为。
- 测试基建：`tests/_setup.bash` 补齐 `lib/tls.sh` 的加载（此前 `gps_write_config` 在测试环境因缺失 `gps_ensure_tls` 而被 `run` 机制掩盖为"假通过"）。

## v0.2.18 - 2026-08-19

供应链：自升级完整性校验 + 发布自动化。

- 自升级校验：`upgrade self` 优先从 GitHub Release 下载打包资产 `geoproxy-server-<tag>.tar.gz`，用 GitHub API 的 sha256 digest 强制校验后才安装（与 sing-box 核心同一机制）。旧版本 Release 无资产时回退 tag archive，退化为 VERSION-tag 一致性校验并明确告警；解包后一律校验脚本树 `VERSION` 与目标 tag 一致（防串包/缓存/半包）。
- 发布自动化：新增 release workflow——推送 `v*` tag 自动校验 `VERSION == tag`、`git archive` 打包资产并生成 `.sha256`、从 CHANGELOG 提取对应版本段落作为 Release notes、创建带资产附件的 GitHub Release。今后发版无需手工 `gh release create`，`upgrade self` 的校验链路随发布天然成立。

## v0.2.17 - 2026-08-19

运维韧性：升级失败自动恢复 + 日志轮转。

- 升级回滚：`upgrade core` 安装新核心前保留 `sing-box.prev`；新核心通过 `sing-box check` 失败时自动回滚旧核心并恢复服务。下载/校验失败（网络、digest 拿不到）时服务不再停留在停机状态，先拉回旧核心再报错。
- 脚本升级恢复：`upgrade self` 拉取脚本失败时先用旧脚本恢复服务再报错，不再停服。
- 日志轮转：安装/升级时部署 `/etc/logrotate.d/geoproxy-server`（weekly + maxsize 10M/5M，copytruncate——sing-box 以 append fd 持有日志），解决 debug 级别下日志无限增长写满小盘 VPS 的问题。
- doctor：新增日志分区磁盘使用率检查（≥90% 告警，≥95% 判 FAIL）。
- CI：去掉 apt 依赖（runner 的 apt 源偶发挂起会吊死 job），shellcheck/shfmt/bats 全部改为下载固定版本二进制；job 增加 `timeout-minutes: 10`。

## v0.2.16 - 2026-08-19

Hardening（低优先级）：测试卫生与项目可维护性。

- 测试卫生：bats teardown 只清理 `GPS_TEST_PREFIX`；新增 hygiene 测试断言 bats 运行后 `tests/tmp` 无 tracked/脏文件、README 仓库相对链接全部可解析。
- `.gitignore` 增加 `tests/tmp/`，并移除误提交的假 sing-box 二进制（`tests/tmp/usr/local/lib/geoproxy-server/sing-box`）；假核心只在 `tests/_setup.bash` 生成。
- README 设计文档链接改为仓库内实际路径（原 monorepo 相对路径已失效）。
- CI 修复：`mvdan/shfmt` action 已不存在导致 CI 常年红——改为直接下载 shfmt 发布二进制；shellcheck 补齐 SC2034 抑制后 CI 恢复绿。
- CHANGELOG 依据 git 历史重建 v0.2.3–v0.2.13 条目。

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

## v0.2.13 - 2026-08-18

- fix(qr): IPv4 与 IPv6 各生成一张二维码。

## v0.2.12 - 2026-08-18

- fix(install): 安装成功后立即拉取一次流量百分比，避免 `last=?%`。

## v0.2.11 - 2026-08-18

- feat(kiwivm): 凭证长期保存（`/etc/geoproxy-kiwivm.env`），卸载不丢失，重装自动恢复。

## v0.2.10 - 2026-08-18

- fix(upgrade): 升级先停干净旧进程再启动新版本，不再沿用旧进程 restart。

## v0.2.9 - 2026-08-18

- fix(uninstall): 卸载成功后强制 `exit 0`。

## v0.2.8 - 2026-08-18

- fix(menu): 卸载成功后退出菜单。

## v0.2.7 - 2026-08-18

- fix: README/install 不再写死版本号，始终解析最新 Release tag。

## v0.2.6 - 2026-08-18

- fix(url): TUIC 节点名写入 URL `#fragment`。

## v0.2.5 - 2026-08-18

- fix(install): 重装不再删除正在运行的脚本树。

## v0.2.4 - 2026-08-18

- fix(upgrade): self 升级不再把下载日志当成脚本路径。

## v0.2.3 - 2026-08-18

- feat(traffic): 月流量重置后自动恢复熔断服务。

## v0.2.2 - 2026-07-20

- CI: added GitHub Actions workflow running shfmt, shellcheck and bats tests; CI now runs bats with TAP output.
- Code style: applied shfmt across the repo and suppressed intentional shellcheck SC2034 for sourced variables.
- Tests: added bats tests covering config generation, state handling, and KiwiVM traffic guard (warn/stop/resume).
- TUIC: include users.name in inbound (uses machine hostname), add auth_timeout; TUIC URL generation now includes name parameter.
- URL/QR: ensure qrencode is an optional dependency in ensure_deps and gps_cmd_url prints URLs with hostname name param.
- Version bumped to v0.2.2 and added this changelog entry.

(See git history for detailed commits.)

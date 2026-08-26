# Changelog

All notable changes to this project are documented in this file.

## v0.2.47 - 2026-08-26

修复：旧版升级后 `geoproxy-server agent token` 报 `GPS_AGENT_TOKEN 未设置`；菜单 29 查看 Token 不便；agent 用法提示误导填 https。

- `gps_cmd_agent`（status/token）在 agent.env 缺失时自动 ensure（幂等，不覆盖已有 Token），从任意旧版升级后首次查询即自愈，无需手动 `agent ensure`。
- 菜单 29 直接展示完整 Token（此前先显示打码再交互询问），复制到 v2rayA 节点池即可。
- `agent status` 用法提示改为 `http://IP:19528`（agent 是明文 HTTP，非 TLS；填 https 会握手失败显示离线）。

## v0.2.46 - 2026-08-26

功能：交互菜单新增 Agent 查看入口（菜单 29）—— 无需再手动运行 `geoproxy-server agent token`。

- `lib/menu.sh` 新增 `29) Agent 状态 / Token（v2rayA 节点池）`：显示监听地址 / 打码 Token / 服务状态，并询问是否展示完整 Token（复制到 v2rayA 节点池成员配置）。

## v0.2.45 - 2026-08-26

修复：`save_state` 未把流量字节字段写入 `state.env`，导致 agent 上报 `usedBytes`/`quotaBytes` 恒为 0（v2rayA 节点池只显示百分比，字节显示 `0 B / 0 B`）。

- `lib/common.sh` `gps_save_state_unlocked` 补充持久化 `TRAFFIC_USED_BYTES` / `TRAFFIC_LIMIT_BYTES` / `TRAFFIC_MULT` / `TRAFFIC_RESET`（与 `TRAFFIC_LAST_PCT` 同步写入）。
- 升级到 v0.2.45 后下一次流量检查（默认每 300s）即写入字节字段，agent `/v1/status` 自动带上绝对值，无需重启 agent。

## v0.2.44 - 2026-08-26

修复：从旧版（< v0.2.43）升级时不会创建 agent 凭证与单元，`geoproxy-server agent token` 报 `GPS_AGENT_TOKEN 未设置`。

- 新增 `geoproxy-server agent ensure`：幂等创建 `/etc/geoproxy-server/agent.env`（0600，Token 已存在则不覆盖）与 `geoproxy-agent.service` 单元并启用（镜像 `mesh ensure` 模式）。
- `upgrade self` 流程在换新脚本后显式调用新入口的 `agent ensure`（与 `mesh ensure` 并列），旧版升级后 agent 自动就绪，无需重跑 `install`。

## v0.2.43 - 2026-08-25

新增：上报 Agent（`geoproxy-agent.service`，`:19528`，Bearer Token）—— v2rayA 节点池的流量状态上报与远程控制面。

- `GET /v1/status`：节点标识/系统负载/活跃连接数/流量用量配额熔断状态/mesh 角色（只读 state.env 与 /proc/ss，无副作用）。
- `POST /v1/control`：`trip`（新增 `geoproxy-server traffic trip` 立即熔断）/ `resume` / `set-thresholds` / `set-check-interval`，经既有 CLI 落地。
- Token 存 `/etc/geoproxy-server/agent.env`（0600，EnvironmentFile 注入，不进 argv）；`geoproxy-server agent [status|token]` 查看。
- 契约文档：`docs/geoproxy-agent-api.md`；v2rayA 客户端（节点池功能）按此对接。

## v0.2.42 - 2026-08-25

修复：mesh-failover 出站类型改用 `urltest`（v0.2.41 渲染的 `loadbalance` 类型与 sing-box ≥1.12 不兼容，`sing-box check` 会报 `unknown outbound type: loadbalance`，导致开启 failover 失败）。

- 出口探测组由 `loadbalance`（`destinations` 嵌套对象）改为 `urltest`（`outbounds` 标签列表），字段 `url` / `interval` / `tolerance` 语义不变；仍为本机直连优先 + 故障自动切对端。
- 已升级到 v0.2.41 且开启 failover 失败（或 config.json 残留坏配置）的机器：升级到 v0.2.42 后重新执行 `change mesh-failover on` 即可（会重新渲染配置并通过 `sing-box check`）。

## v0.2.41 - 2026-08-25

功能：mesh 出口自动故障切换（`change mesh-failover on|off`）——本机直连优先、本机出口故障时自动切到对端出口兜底、恢复后自动回切，平时零隧道流量开销。

- 出口改为 sing-box 原生 `loadbalance`（`strategy: url-test`）探测组 { direct, wg-ep }：本机直连优先，故障自动切对端，恢复自动回切；平时零隧道流量开销。
- 防环：来自 WG 隧道（overlay 网段）的流量强制走本机直连（`source_ip_cidr` 规则恒渲染且置顶），杜绝 A↔B 兜底/探活循环。
- 探测地址可配（`change mesh-failover-probe <url>`，默认 `https://www.gstatic.com/generate_204`）；与 `mesh-exit` 互斥（双向校验）；默认关闭，需显式开启。
- `mesh show` / `doctor` 展示 failover 状态；无在线对端时自动降级为本机直连（等价现状）。

## v0.2.40 - 2026-08-25

体验：Master 自检明确打印本机 `https://127.0.0.1:<port>/v1/health`，两端都失败改为 FAIL。

- 抽出 `gps_mesh_print_local_health`：有证书时优先 `curl -k` 探 https；成功打完整 URL + OK；仅 HTTP → FAIL；两端不通 → FAIL（不再 WARN）。
- 菜单 23 doctor 与 `mesh show` / 升主后的加入提示共用该自检行，运维无需再手敲 curl。
- 补充 bats：完整 URL、两端失败 FAIL、`mesh show` 含 health 行。

## v0.2.39 - 2026-08-25

修复：同版本/旧进程升级路径漏 restart mesh-master，控制面仍占明文 19527。

- `gps_cmd_upgrade_self` 在 mesh ensure 之后强制 `gps_upgrade_restart_mesh_master`（不依赖升级前内存里的 `gps_install_mesh_units`），避免旧明文进程继续占端口。
- `gps_install_mesh_units`：mesh-master restart 失败改为 warn + 手动提示，不再静默吞掉。
- 补充 bats：master 角色会 `systemctl restart`；member 角色跳过。

## v0.2.38 - 2026-08-25

修复：Master 升级后控制面证书在磁盘、进程仍明文时，doctor / 加入命令会误导成 https+PIN。

- `gps_mesh_ensure_master_tls` 默认硬失败（缺 openssl / 生成失败 / 写指纹失败不再静默退回明文）；仅调试可设 `GPS_MESH_MASTER_TLS=0`。
- `gps_install_mesh_units` 对 Master 改为 `enable` + **`restart`**（不只 `enable --now`），避免旧明文进程不换新代码/TLS；`master.env` 写入 `GPS_MESH_MASTER_TLS=1`。
- doctor：有证书时优先探测 https；证书在但只有 HTTP → FAIL，并提示 `systemctl restart geoproxy-mesh-master`。
- `mesh show` / 加入命令按本机实测 scheme 打印：仍明文时打 `http://`、不带 PIN，并 warn 需 restart；升主时先安装/重启 mesh-master 再 ensure。
- `mesh_master.py`：TLS 启用失败时明确退出（不再半启动）。

## v0.2.37 - 2026-08-24

修复：Member 连不上 Master 时启动探测 2–3s 快速降级，不把 tuic 拖死。

- 启动路径 `gps_mesh_ensure_boot` 默认 curl `--connect-timeout 2 --max-time 3`（周期 sync 仍 15s）；连不上 Master 时写 peers 失败改为 warn，不让 ExecStartPre 把 unit 拖成 failed。
- `mesh sync-master` 只在 `config.json`（WG 配置）真变时重启代理，不再因 peers.json 的 `last_seen` 每次 upsert 都变而重启。
- mesh-sync unit：`ExecStart=+`、`ProtectSystem=strict`、`ReadWritePaths` 含 etc/log，避免沙箱只读导致写 peers 失败。

## v0.2.36 - 2026-08-24

工程：新增 Cloud Agent 开发环境（`.cursor/`），随分支/PR 生效。

- 新增 `.cursor/environment.json` 与幂等的 `.cursor/install.sh`：按官方 sha256 digest 安装开发三件套 `shfmt v3.13.1` / `shellcheck v0.11.0` / `bats v1.14.0`，版本与校验和与 `.github/workflows/ci.yml` 完全一致（同一信任模型）。
- 新增 `tests/test_env.bats`：断言 `.cursor/install.sh` 固定的工具版本与 sha256 与 CI 保持一致，`environment.json` 合法且经 `.cursor/install.sh` 安装，防止开发环境与 CI 漂移。

## v0.2.35 - 2026-08-24

修复：v0.2.33 沙箱过紧导致 Master 上 `sing-box check` 过但 `run` 立刻 exit 1（mesh WG/netlink）。

- `geoproxy-tuic` unit 补 `AF_NETLINK`、`CAP_NET_ADMIN`、`DeviceAllow=/dev/net/tun`、`ReadWritePaths` 含 `/run`。
- sing-box 运行日志改走 journal（不再只写文件导致 journal 看不到原文）。
- 启动失败 dump 同时打 journal 和 `sing-box.log` 文件尾。

## v0.2.34 - 2026-08-24

体验：Master 自动放行组网控制面；TUIC 启动失败打印 journal。

- Master 升主 / 安装 / `mesh ensure` 时自动放行本机防火墙 TCP 19527（活动的 ufw → firewalld → iptables → nft）；`mesh show` / doctor / 加入命令写明监听地址与防火墙状态。云安全组脚本改不了，需在控制台同样放行。
- Member 的 `mesh show` 显示真实 `MESH_MASTER_URL`，不再把本机域名误显示成 Master；连不上时提示检查 Master 的 19527（本机防火墙 + 云安全组）。
- `geoproxy-tuic` 启动失败：菜单 12 / systemctl 失败时自动打印 `status` 与 `journalctl -n 40`；`ExecStartPre mesh ensure` 不再套主进程过严沙箱；`ReadWritePaths` 加上日志目录；菜单 12 restart 先在菜单进程做 mesh ensure 再 start。

## v0.2.33 - 2026-08-24

安全加固（含 **破坏性变更**：mesh 控制面默认 TLS）。

**破坏性变更 / 迁移**

- mesh Master 现默认以**自签 TLS** 提供 19527 登记 API；加入命令升级为
  `GPS_MESH_MASTER=https://... GPS_MESH_TLS_PIN=sha256//... GPS_MESH_TOKEN=... bash install.sh`。
- 旧成员节点升级后，若其 `MESH_MASTER_URL` 仍是 `http://<公网IP>:19527`，注册将被拒绝（仅放行 loopback 明文）。
  迁移：在 Master 上执行 `geoproxy-server mesh show`，用新打印的 **https + GPS_MESH_TLS_PIN** 整行在成员上重新
  `mesh join`（或菜单 26）。

**安全修复**

- 密钥生成不再有占位回退：`GPS_CORE_BIN` 缺失或 `generate wg-keypair/reality-keypair` 失败时**硬失败**，
  绝不把公开已知的占位私钥写进 `state.env`（WireGuard 与 Reality 同步修复）。
- `mesh_master.py` 全面加固：`overlay_ip` 必须位于 `MESH_OVERLAY_PREFIX` 内且避开网络/广播/Master 保留地址（越界请求改派）；
  请求体上限（默认 64KiB → 413）；`keepalive`/`Content-Length` 畸形值返回 400 而非 500；roles 白名单校验；
  token 比较改常数时间（`hmac.compare_digest`）；空 `MESH_CLUSTER_TOKEN` 拒绝启动（除非显式 `GPS_MESH_ALLOW_OPEN=1`）。
- mesh-master 服务改用专用 `/etc/geoproxy-server/mesh/master.env`（仅含 token），不再加载整个 `state.env`；
  三个 mesh/traffic systemd 单元补齐沙箱指令（`ProtectSystem=strict` + `ReadWritePaths`、`ProtectHome`、`PrivateTmp`、
  `MemoryDenyWriteExecute` 等），`geoproxy-tuic` 同步收紧。
- `install.sh` 引导：release asset 路径增加 GitHub API sha256 摘要校验；未校验的 tag archive 回退需显式
  `GPS_INSTALL_ALLOW_UNVERIFIED=1`；`GPS_VERSION` 增加格式校验（防路径注入）。
- 凭证不进进程 argv：KiwiVM API_KEY 改 POST 表单；mesh TOKEN 经 `curl -H @file` 传递。
- `uninstall` 改用与其它路径一致的加固 `gps_source_env`（拒绝符号链接/宽松权限）；`/usr/local/bin` wrapper
  以 `printf %q` 序列化前缀变量（消除单引号注入）。
- 非本机 Master 的明文 `http://` 请求在交互路径（`mesh join` / 安装）直接拒绝；后台注册拒绝并告警，
  不再阻断代理服务本身；`mesh sync <url>` 同样禁止明文非 loopback 远端。

**修复**

- SS2022 密钥长度按方法推导：`2022-blake3-aes-256-gcm` / `chacha20-poly1305` 生成 32 字节（原先固定 16 字节导致 `sing-box check` 失败）。
- hy2 分享 URL 在启用 obfs 时补上 `obfs=salamander&obfs-password=...`（原先缺参数客户端连不上）。
- `alloc_overlay` 遵循 `MESH_OVERLAY_PREFIX`（原先硬编码 `10.66.0.x`）。
- `uninstall` 同时清理 `/etc/logrotate.d/geoproxy-server`。
- 修复 CI：`shfmt -l` 不再静默放过格式漂移（改 `shfmt -d`）；补 `permissions: contents: read` 与
  `concurrency` 取消旧运行；`actions/checkout` 钉 commit SHA；CI 工具下载按官方 digest 校验。
- 测试：修复 join 测试 token 长度（13→≥16）及后台 master 进程泄漏（stdin 重定向 + 日志入前缀）；
  新增 TLS 钉扎端到端、明文拒绝、密钥硬失败、SS2022 长度、hy2 obfs、引导校验、卸载等测试。

## v0.2.32 - 2026-08-21

修复：菜单加入 Node 时误粘贴整行命令导致 Master URL 被污染。

- 支持直接粘贴 Master 打印的整行 `GPS_MESH_MASTER=... GPS_MESH_TOKEN=...`，自动拆分。
- 拒绝把整段命令 / 垃圾串当成 IPv6 包进 `http://[...]`。
- 菜单 26 若检测到已损坏的 Master URL，提示重新填写。

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

# GeoProxy Server Code Wiki

> 当前版本：v0.2.71  
> 生成日期：2026-09-15

---

## 目录

1. [项目概览](#1-项目概览)
2. [整体架构](#2-整体架构)
3. [目录结构](#3-目录结构)
4. [核心模块详解](#4-核心模块详解)
5. [协议插件系统](#5-协议插件系统)
6. [Mesh 组网系统](#6-mesh-组网系统)
7. [关键数据结构](#7-关键数据结构)
8. [系统服务与定时器](#8-系统服务与定时器)
9. [安全设计](#9-安全设计)
10. [配置与状态管理](#10-配置与状态管理)
11. [部署与运行](#11-部署与运行)
12. [测试体系](#12-测试体系)
13. [CI/CD 与发布](#13-cicd-与发布)
14. [开发规范](#14-开发规范)

---

## 1. 项目概览

### 1.1 项目简介

GeoProxy Server 是面向 GeoProxy 生态的 VPS 端一键部署与管理脚本。每台机器只运行 **一个 sing-box 实例**，默认采用 **TUIC → direct** 架构，支持通过 **WireGuard mesh** 实现多机互连与节点发现。

### 1.2 核心特性

- **菜单优先，CLI 为辅**：交互友好，同时支持脚本自动化
- **自升级能力**：管理脚本（`upgrade self`）与 sing-box 核心（`upgrade core`）均可独立升级
- **自动下载最新稳定版 sing-box**：不锁定 sing-box 版本号
- **IPv4 / IPv6 自适应**：监听与分享 URL 自动适配双栈
- **自签 TLS**：按协议生成，TUIC 默认 UUID=密码、BBR 拥塞控制
- **入站协议可切换**：支持 10+ 种协议（TUIC、Hysteria2、VLESS、Trojan、Shadowsocks 等）
- **Mesh 组网**：开机自动启用，首台为 Master，成员通过 Token 加入
- **流量熔断**：KiwiVM 流量监控，超阈值自动停服
- **上报 Agent**：v2rayA 节点池远程访问接口（HTTP + Bearer Token）

### 1.3 技术栈

| 层次 | 技术 | 说明 |
|------|------|------|
| 核心代理 | sing-box | 通用代理内核，支持多协议 |
| 管理脚本 | Bash 脚本 | 菜单 + CLI 双模，模块化设计 |
| 控制面服务 | Python 3 | mesh-master、geoagent 基于 http.server |
| 服务管理 | systemd | 生产环境默认 |
| 组网隧道 | WireGuard | sing-box 用户态 WG endpoint |
| 证书 | OpenSSL | 自签 TLS 证书 |
| 测试框架 | BATS | Bash 自动化测试 |

---

## 2. 整体架构

### 2.1 架构分层

```
┌─────────────────────────────────────────────────────────┐
│                   用户交互层                              │
│  ┌──────────┐  ┌─────────────┐  ┌──────────────────┐   │
│  │  交互菜单  │  │   CLI 命令   │  │  v2rayA Agent API │   │
│  └──────────┘  └─────────────┘  └──────────────────┘   │
├─────────────────────────────────────────────────────────┤
│                   业务逻辑层 (lib/*.sh)                  │
│  ┌──────┐ ┌──────┐ ┌───────┐ ┌────────┐ ┌──────────┐  │
│  │config│ │ cmd  │ │systemd│ │download│ │ traffic  │  │
│  └──────┘ └──────┘ └───────┘ └────────┘ └──────────┘  │
│  ┌──────┐ ┌──────┐ ┌───────┐ ┌────────┐ ┌──────────┐  │
│  │ tls  │ │ url  │ │ bbr   │ │ doctor │ │ firewall │  │
│  └──────┘ └──────┘ └───────┘ └────────┘ └──────────┘  │
├─────────────────────────────────────────────────────────┤
│                   协议插件层 (lib/protocols/)            │
│  tuic / hysteria2 / vless / trojan / shadowsocks ...   │
├─────────────────────────────────────────────────────────┤
│                   Mesh 组网层 (lib/mesh/)                │
│  ┌──────────┐ ┌───────┐ ┌──────────┐ ┌──────────────┐ │
│  │ wireguard│ │ peers │ │discovery │ │  cli / _common│ │
│  └──────────┘ └───────┘ └──────────┘ └──────────────┘ │
├─────────────────────────────────────────────────────────┤
│                   核心执行层                              │
│  ┌──────────────────────────────────────────────────┐   │
│  │              sing-box (用户态代理内核)             │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 2.2 核心数据流

1. **安装流程**：`install.sh` → 解析版本 → 拉取仓库 → `geoproxy-server.sh install` → 下载 sing-box → 生成配置 → 安装 systemd 服务 → 启动
2. **配置生成**：`state.env` → `gps_write_config()` → 协议插件渲染 inbound → Mesh 模块渲染 endpoints/outbounds/route → `config.json`
3. **Mesh 注册**：Member → `gps_mesh_register_and_pull()` → HTTPS POST `/v1/register` → Master → 写入 `peers.json` → 返回集群信息
4. **流量熔断**：timer → `traffic check` → KiwiVM API → 用量计算 → ≥阈值 → 停服 + 写 `TRAFFIC_TRIPPED=1`

---

## 3. 目录结构

```
geoproxy-server/
├── geoproxy-server.sh      # 主入口脚本（菜单 + CLI 双模）
├── install.sh              # 一键安装引导脚本
├── VERSION                 # 版本号（vX.Y.Z）
├── AGENTS.md               # 开发与发布规则书
├── CHANGELOG.md            # 变更日志
├── README.md               # 项目说明
├── LICENSE                 # 许可证
│
├── lib/                    # 核心库（bash 模块）
│   ├── paths.sh            # 路径与常量定义
│   ├── common.sh           # 通用工具函数
│   ├── config.sh           # sing-box 配置生成与校验
│   ├── cmd.sh              # CLI 子命令实现
│   ├── systemd.sh          # systemd 服务管理
│   ├── download.sh         # sing-box 下载与脚本自升级
│   ├── tls.sh              # 自签 TLS 证书
│   ├── traffic.sh          # KiwiVM 流量检测与熔断
│   ├── url.sh              # 分享 URL / 二维码 / 信息展示
│   ├── firewall.sh         # 本机防火墙管理
│   ├── doctor.sh           # 健康检查
│   ├── bbr.sh              # BBR 拥塞控制启用
│   ├── menu.sh             # 交互菜单
│   │
│   ├── protocols/          # 协议插件（每个协议一个 .sh 文件）
│   │   ├── _registry.sh    # 协议注册表与调度器
│   │   ├── _common.sh      # 协议共享工具
│   │   ├── tuic.sh
│   │   ├── hysteria2.sh
│   │   ├── vless.sh
│   │   ├── trojan.sh
│   │   ├── shadowsocks.sh
│   │   ├── vmess.sh
│   │   ├── anytls.sh
│   │   ├── hysteria.sh
│   │   ├── naive.sh
│   │   ├── snell.sh
│   │   └── shadowtls.sh
│   │
│   └── mesh/               # Mesh 组网模块
│       ├── _registry.sh    # Mesh 模块入口
│       ├── _common.sh      # 公共：角色、TLS、连通性
│       ├── wireguard.sh    # WireGuard 密钥与 JSON 渲染
│       ├── peers.sh        # peers.json 读写
│       ├── discovery.sh    # Master 发现与注册
│       └── cli.sh          # mesh 子命令
│
├── scripts/                # Python 后台服务
│   ├── geoagent.py         # v2rayA 节点池 Agent (:19528)
│   ├── mesh_master.py      # Mesh Master 注册服务 (:19527)
│   └── extract_release_notes.py
│
├── templates/              # systemd unit 模板与配置模板
│   ├── config.json.tpl
│   ├── geoproxy-tuic.service
│   ├── geoproxy-mesh-master.service
│   ├── geoproxy-mesh-sync.service
│   ├── geoproxy-mesh-sync.timer
│   ├── geoproxy-mesh-upgrade.service
│   ├── geoproxy-agent.service
│   ├── geoproxy-traffic.service
│   ├── geoproxy-traffic.timer
│   └── logrotate.conf
│
├── tests/                  # BATS 测试套件
│   ├── _setup.bash
│   ├── test_bootstrap.bats
│   ├── test_install.bats
│   ├── test_config.bats
│   ├── test_protocol.bats
│   ├── test_mesh.bats
│   ├── test_mesh_failover.bats
│   ├── test_mesh_route.bats
│   ├── test_mesh_tls.bats
│   ├── test_mesh_webhook.bats
│   ├── test_mesh_cluster_upgrade.bats
│   ├── test_traffic.bats
│   ├── test_traffic_trip.bats
│   ├── test_agent.bats
│   ├── test_agent_deploy.bats
│   ├── test_doctor.bats
│   ├── test_download.bats
│   ├── test_firewall.bats
│   ├── test_state.bats
│   ├── test_systemd.bats
│   ├── test_release.bats
│   ├── test_stability.bats
│   ├── test_hygiene.bats
│   └── test_env.bats
│
├── docs/                   # 设计文档
│   ├── design.md
│   ├── RELEASING.md
│   ├── geoproxy-agent-api.md
│   └── superpowers/        # 详细规格文档
│       ├── specs/
│       ├── plans/
│       └── briefs/
│
└── .github/
    └── workflows/
        ├── ci.yml          # CI 流水线
        └── release.yml     # 发布流水线
```

---

## 4. 核心模块详解

### 4.1 入口脚本 (geoproxy-server.sh)

**文件**：[geoproxy-server.sh](file:///c:/Users/stone/geoproxy-server/geoproxy-server.sh)

**职责**：
- 项目主入口，支持菜单模式（无参数）和 CLI 模式
- 加载所有 `lib/` 下的模块
- 根据子命令分发到对应处理函数

**核心函数**：

| 函数 | 说明 |
|------|------|
| `main()` | 主入口，解析命令行参数并分发 |

**支持的 CLI 命令**：

```
install / uninstall
start / stop / restart
info / url / qr / log / doctor
protocols
mesh [子命令]
agent [子命令]
change [项] [值]
traffic [status|check|resume]
upgrade [self|core|all]
bbr
version
menu
help
```

### 4.2 路径与常量 (lib/paths.sh)

**文件**：[lib/paths.sh](file:///c:/Users/stone/geoproxy-server/lib/paths.sh)

**职责**：定义所有全局路径常量和服务名称。

**核心常量**：

| 常量 | 默认值 | 说明 |
|------|--------|------|
| `GPS_NAME` | `geoproxy-server` | 项目名称 |
| `GPS_SERVICE` | `geoproxy-tuic` | 主代理服务名 |
| `GPS_MESH_MASTER_SERVICE` | `geoproxy-mesh-master` | Mesh Master 服务 |
| `GPS_MESH_SYNC_TIMER` | `geoproxy-mesh-sync.timer` | Mesh 同步定时器 |
| `GPS_MESH_MASTER_PORT` | `19527` | Mesh 控制面端口 |
| `GPS_AGENT_PORT` | `19528` | Agent 服务端口 |
| `GPS_ETC` | `/etc/geoproxy-server` | 配置目录 |
| `GPS_STATE` | `/etc/geoproxy-server/state.env` | 状态文件 |
| `GPS_CONFIG` | `/etc/geoproxy-server/config.json` | sing-box 配置 |
| `GPS_CORE_BIN` | `/usr/local/lib/geoproxy-server/sing-box` | sing-box 二进制 |
| `GPS_BIN_LINK` | `/usr/local/bin/geoproxy-server` | 入口软链 |
| `GPS_LOG` | `/var/log/geoproxy-server/sing-box.log` | 代理日志 |
| `GPS_KIWI_PERSIST` | `/etc/geoproxy-kiwivm.env` | KiwiVM 长期凭证 |

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_apply_paths()` | 根据 `GPS_TEST_PREFIX` 应用路径前缀（测试模式） |

### 4.3 通用工具 (lib/common.sh)

**文件**：[lib/common.sh](file:///c:/Users/stone/geoproxy-server/lib/common.sh)

**职责**：提供全项目通用的工具函数。

**核心功能分类**：

#### 输出与交互
- `msg()` / `warn()` / `err()`：彩色输出
- `confirm_yes()`：交互式确认
- `need_root()`：检查 root 权限

#### 系统检测
- `detect_arch()`：检测 CPU 架构（amd64/arm64）
- `detect_local_stack()`：检测本机 IPv4/IPv6 栈
- `detect_public_ipv4()` / `detect_public_ipv6()`：探测公网 IP
- `detect_public_ips()`：双栈自适应探测
- `ensure_deps()`：自动安装依赖（curl/openssl/tar/iproute2/logrotate）

#### 输入校验
- `gps_validate_port()`：端口号校验（1-65535）
- `gps_validate_uuid()`：UUID 格式校验
- `gps_validate_ipv4()` / `gps_validate_ipv6()`：IP 地址校验
- `gps_validate_single_line()`：单行文本校验（防换行注入）
- `gps_validate_traffic_thresholds()`：流量阈值校验

#### 状态文件安全
- `gps_state_lock_acquire()` / `gps_state_lock_release()`：状态文件互斥锁（flock 优先，mkdir 自旋回退）
- `gps_with_state_lock()`：持锁执行函数
- `gps_atomic_write_env()`：临时文件 + mv 原子写入
- `gps_source_env()`：安全 source 环境文件（拒绝符号链接、宽松权限、异属主）
- `gps_env_assign()`：%q 序列化 KEY=VALUE（防注入）
- `gps_json_escape()`：JSON 字符串转义

#### 状态管理
- `load_state()`：加载 `state.env`
- `save_state()`：持锁保存状态
- `gps_save_state_unlocked()`：无锁写入（内部使用）

#### 凭证生成
- `gen_uuid()`：生成 UUID
- `rand_port()`：生成随机端口（20000-59999）

### 4.4 配置生成 (lib/config.sh)

**文件**：[lib/config.sh](file:///c:/Users/stone/geoproxy-server/lib/config.sh)

**职责**：生成 sing-box 的 `config.json` 配置文件。

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_write_config()` | 主配置生成函数 |
| `gps_check_config()` | 调用 `sing-box check` 校验配置 |
| `gps_set_log_level()` | 修改日志级别 |
| `gps_config_log_level()` | 从 config.json 读取当前日志级别 |
| `gps_bump_log_level_if_quiet()` | 若日志过低则提升为 debug |

**配置生成逻辑**：
1. 调用协议插件规范化与默认值设置
2. 确保 TLS 证书存在
3. 检测本机协议栈模式（dual/v4only/v6only）
4. 根据协议栈模式生成对应 inbound（单/双栈）
5. 调用协议插件生成 inbound JSON
6. 调用 Mesh 模块生成 endpoints / outbounds / route
7. 组装完整 JSON 并写入
8. 调用 `sing-box check` 校验

### 4.5 CLI 命令 (lib/cmd.sh)

**文件**：[lib/cmd.sh](file:///c:/Users/stone/geoproxy-server/lib/cmd.sh)

**职责**：实现所有 CLI 子命令的业务逻辑。

**主要命令函数**：

| 函数 | 对应命令 | 说明 |
|------|----------|------|
| `gps_cmd_install()` | `install` | 安装主流程 |
| `gps_cmd_uninstall()` | `uninstall` | 卸载 |
| `gps_cmd_upgrade()` | `upgrade` | 升级分发（self/core/all） |
| `gps_cmd_upgrade_self()` | `upgrade self` | 管理脚本自升级 |
| `gps_cmd_upgrade_core()` | `upgrade core` | sing-box 核心升级 |
| `gps_cmd_change()` | `change` | 修改配置项 |
| `gps_cmd_info()` | `info` | 显示节点信息 |
| `gps_cmd_url()` | `url` | 显示分享 URL |
| `gps_cmd_qr()` | `qr` | 显示二维码 |
| `gps_cmd_protocols()` | `protocols` | 列出可用协议 |
| `gps_cmd_agent()` | `agent` | Agent 管理 |
| `gps_cmd_log()` | `log` | 查看日志 |
| `gps_help()` | `help` | 帮助信息 |

### 4.6 下载与升级 (lib/download.sh)

**文件**：[lib/download.sh](file:///c:/Users/stone/geoproxy-server/lib/download.sh)

**职责**：sing-box 核心下载、校验和管理脚本自升级。

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_download_core()` | 下载 sing-box 核心 |
| `gps_core_ver_installed()` | 获取已安装核心版本 |
| `gps_resolve_core_ver()` | 解析目标版本号 |
| `gps_core_asset_digest()` | 从 GitHub API 获取资产 sha256 |
| `gps_verify_core_archive()` | 校验归档完整性 |
| `gps_install_core_from()` | 安装核心（旧版备份为 .prev） |
| `gps_rollback_core()` | 回滚到上一版核心 |
| `gps_self_fetch_tree()` | 拉取管理脚本树 |
| `gps_self_install_tree()` | 安装脚本树（原子替换） |
| `gps_self_resolve_ver()` | 解析脚本版本 |

**升级安全机制**：
1. 先下载并校验新版本
2. 校验通过后才停止旧服务
3. 核心升级：新核心先过 `sing-box check`，失败则回滚
4. 脚本升级：原子替换（staging → scripts.prev → scripts）
5. 升级后强制重启 mesh-master（应用新 TLS/代码）

### 4.7 服务管理 (lib/systemd.sh)

**文件**：[lib/systemd.sh](file:///c:/Users/stone/geoproxy-server/lib/systemd.sh)

**职责**：systemd 单元安装、服务启停、无 systemd 模式兼容。

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_install_unit()` | 安装主服务 unit |
| `gps_install_mesh_units()` | 安装 Mesh 相关 unit |
| `gps_install_agent_units()` | 安装 Agent unit |
| `gps_install_traffic_timer()` | 安装流量定时器 |
| `gps_install_logrotate()` | 配置日志轮转 |
| `gps_svc()` | 统一服务操作入口（systemd / no-systemd） |
| `gps_svc_halt()` | 彻底停止服务（清旧进程） |
| `gps_svc_boot()` | 全新启动服务（daemon-reload + start） |
| `gps_restart_svc()` | 重启 = halt + boot |
| `gps_start_foreground_bg()` | no-systemd 模式后台启动 |
| `gps_stop_bg()` | no-systemd 模式停止 |
| `gps_svc_dump_failure()` | 启动失败时 dump 诊断信息 |

**设计要点**：
- 避免使用 `systemctl restart`，改为 stop + start，防止沿用旧进程
- 支持 `GPS_NO_SYSTEMD=1` 或 `--prefix` 的无 systemd 模式
- 启动前强制 mesh ensure 和配置检查

### 4.8 流量熔断 (lib/traffic.sh)

**文件**：[lib/traffic.sh](file:///c:/Users/stone/geoproxy-server/lib/traffic.sh)

**职责**：KiwiVM 流量监控、告警与自动停服。

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_kiwi_fetch_info()` | 调用 KiwiVM API 获取服务信息 |
| `gps_kiwi_parse_info()` | 解析 API 返回 JSON |
| `gps_cmd_traffic_status()` | 显示流量状态 |
| `gps_cmd_traffic_check()` | 执行一次流量检查（告警/停服/恢复） |
| `gps_cmd_traffic_resume()` | 手动恢复熔断 |
| `gps_cmd_traffic_trip()` | 立即熔断 |
| `gps_traffic_try_auto_resume()` | 启动前自动检查并恢复 |
| `gps_assert_not_tripped()` | 启动前断言未熔断 |
| `gps_traffic_defaults()` | 流量相关默认值 |

**熔断逻辑**：
1. 每 `TRAFFIC_CHECK_SEC` 秒（默认 300s）执行 `traffic check`
2. 调用 KiwiVM `getServiceInfo` API
3. 计算用量百分比：`data_counter / (plan_monthly_data × monthly_data_multiplier)`
4. ≥ `TRAFFIC_WARN_PCT`（默认 80%）：写日志告警
5. ≥ `TRAFFIC_STOP_PCT`（默认 95%）：停服务 + 置 `TRAFFIC_TRIPPED=1`
6. 用量低于停服线后：自动清除熔断并恢复服务

### 4.9 防火墙管理 (lib/firewall.sh)

**文件**：[lib/firewall.sh](file:///c:/Users/stone/geoproxy-server/lib/firewall.sh)

**职责**：统一管理本机防火墙端口放行。

**支持的后端**（按优先级探测）：
1. **ufw**：Uncomplicated Firewall
2. **firewalld**：Firewalld（runtime + permanent）
3. **iptables**：iptables（含 ip6tables）
4. **nft**：nftables
5. **none**：无活动防火墙

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_fw_backend()` | 探测当前活动防火墙后端 |
| `gps_fw_allow_tcp()` | 放行 TCP 端口 |
| `gps_fw_allow_udp()` | 放行 UDP 端口 |
| `gps_fw_tcp_allowed()` | 查询 TCP 端口是否已放行 |
| `gps_fw_udp_allowed()` | 查询 UDP 端口是否已放行 |

### 4.10 健康检查 (lib/doctor.sh)

**文件**：[lib/doctor.sh](file:///c:/Users/stone/geoproxy-server/lib/doctor.sh)

**职责**：全面的系统健康检查。

**检查项**：
- 磁盘使用率（日志分区）
- systemd 可用性
- sing-box 二进制与配置文件
- TLS 证书与密钥
- `sing-box check` 配置校验
- 服务 active 状态
- 端口监听状态（IPv4/IPv6）
- 公网 IP 设置
- KiwiVM 配置与流量状态
- Mesh 状态（peers、WG 密钥、overlay IP）
- Master 控制面健康 / Member 连通性
- WG 数据面监听与连通性
- Agent 监听安全

### 4.11 TLS 证书 (lib/tls.sh)

**文件**：[lib/tls.sh](file:///c:/Users/stone/geoproxy-server/lib/tls.sh)

**职责**：生成和管理代理入站用自签 TLS 证书。

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_ensure_tls()` | 确保 TLS 证书存在（不存在则生成） |
| `gps_rotate_tls()` | 轮换 TLS 证书 |

**证书特性**：
- 优先使用 prime256v1 椭圆曲线（EC）
- 回退到 RSA 2048
- 有效期 3650 天（约 10 年）
- CN=geoproxy-tuic

### 4.12 URL 与信息展示 (lib/url.sh)

**文件**：[lib/url.sh](file:///c:/Users/stone/geoproxy-server/lib/url.sh)

**职责**：分享 URL 生成、二维码、节点信息展示。

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_cmd_url()` | 显示所有可用分享 URL |
| `gps_cmd_qr()` | 显示二维码（需 qrencode） |
| `gps_cmd_info()` | 显示完整节点信息 |

---

## 5. 协议插件系统

### 5.1 设计理念

协议插件系统采用**注册表模式**，每个协议作为独立模块，通过约定的函数接口与主框架交互。新增协议只需在 `lib/protocols/` 下添加 `.sh` 文件并在 `_registry.sh` 的 `GPS_PROTOCOL_IDS` 数组中注册。

### 5.2 协议注册表 (lib/protocols/_registry.sh)

**文件**：[lib/protocols/_registry.sh](file:///c:/Users/stone/geoproxy-server/lib/protocols/_registry.sh)

**已注册协议**（按优先级）：

| ID | 协议名 | 别名 | 说明 |
|----|--------|------|------|
| `tuic` | TUIC | - | 默认协议，QUIC 基 |
| `hysteria2` | Hysteria 2 | `hy2`, `hy` | QUIC 基 |
| `vless` | VLESS | - | 可带 Reality/TLS |
| `trojan` | Trojan | - | TLS 基 |
| `shadowsocks` | Shadowsocks | `ss` | 含 2022 系列 |
| `vmess` | VMess | - | - |
| `anytls` | AnyTLS | - | - |
| `hysteria` | Hysteria 1 | - | 旧版 |
| `naive` | NaiveProxy | - | HTTP/2 基 |
| `snell` | Snell | - | - |
| `shadowtls` | ShadowTLS | `st` | TLS 伪装 |

**调度函数**：

| 函数 | 说明 |
|------|------|
| `gps_protocol_normalize()` | 规范化协议 ID（别名转换、小写） |
| `gps_protocol_defaults()` | 调用 `gps_proto_{id}_defaults` |
| `gps_protocol_validate()` | 调用 `gps_proto_{id}_validate` |
| `gps_proto_inbound_json()` | 调用 `gps_proto_{id}_inbound_json` |
| `gps_proto_extra_inbounds()` | 可选：额外 inbound（如 ShadowTLS 内层） |
| `gps_proto_share_urls()` | 调用 `gps_proto_{id}_share_urls` |

### 5.3 协议共享工具 (lib/protocols/_common.sh)

**文件**：[lib/protocols/_common.sh](file:///c:/Users/stone/geoproxy-server/lib/protocols/_common.sh)

**核心工具函数**：

| 函数 | 说明 |
|------|------|
| `gps_proto_node_name()` | 获取节点名 |
| `gps_proto_tls_cert_fields()` | 标准 TLS 证书 JSON 字段 |
| `gps_proto_each_public_host()` | 迭代公网地址（v4/v6） |
| `gps_proto_require_port_password()` | 端口+密码校验 |
| `gps_proto_require_port_uuid()` | 端口+UUID 校验 |
| `gps_proto_ensure_password()` | 确保密码存在 |
| `gps_proto_ensure_uuid()` | 确保 UUID 存在 |
| `gps_proto_ensure_ss_password()` | 确保 Shadowsocks 密码 |
| `gps_proto_gen_ss2022_password()` | 生成 SS2022 密码 |
| `gps_proto_ensure_reality()` | 确保 Reality 密钥对 |
| `gps_proto_gen_reality_keypair()` | 生成 Reality 密钥对 |

### 5.4 插件接口规范

每个协议模块必须实现以下函数：

| 函数名 | 必需 | 说明 |
|--------|------|------|
| `gps_proto_{id}_defaults()` | 是 | 设置该协议的默认参数值 |
| `gps_proto_{id}_validate()` | 是 | 校验协议参数合法性 |
| `gps_proto_{id}_inbound_json(tag, listen)` | 是 | 生成单个 inbound JSON 片段 |
| `gps_proto_{id}_share_urls()` | 是 | 输出所有可用分享 URL（每行一个） |
| `gps_proto_{id}_extra_inbounds()` | 否 | 输出额外 inbound（如 ShadowTLS 内层协议） |

**以 TUIC 为例**（[lib/protocols/tuic.sh](file:///c:/Users/stone/geoproxy-server/lib/protocols/tuic.sh)）：
- `defaults`：确保 UUID 存在，密码默认等于 UUID
- `validate`：校验端口、UUID、密码、节点名
- `inbound_json`：渲染 TUIC 类型 inbound，含 BBR 拥塞控制、h3 ALPN、zero_rtt
- `share_urls`：生成 `tuic://` 格式 URL，节点名在 #fragment

---

## 6. Mesh 组网系统

### 6.1 架构概述

Mesh 系统实现多台 GeoProxy Server 节点的自动发现与互连。采用 **Master-Member** 架构：
- **Master**：运行注册服务（`mesh_master.py`，TCP 19527），维护全局 peers 列表
- **Member**：定期向 Master 注册并拉取 peers，更新本地配置

**关键设计原则**：
- WireGuard **仅做节点互联**（overlay /32），**不承载代理流量转发**
- 代理出口恒为本机 `direct`
- 控制面使用自签 TLS + 公钥指纹钉扎
- TOKEN 通过 header 文件传递，不进 argv

### 6.2 Mesh 模块入口 (lib/mesh/_registry.sh)

加载顺序：
1. `firewall.sh`（依赖）
2. `_common.sh`（公共函数）
3. `wireguard.sh`（WG 密钥与配置渲染）
4. `peers.sh`（peers.json 读写）
5. `discovery.sh`（Master 发现与注册）
6. `cli.sh`（mesh 子命令）

### 6.3 Mesh 公共 (lib/mesh/_common.sh)

**文件**：[lib/mesh/_common.sh](file:///c:/Users/stone/geoproxy-server/lib/mesh/_common.sh)

**核心功能**：

#### 角色管理
- `gps_profile_normalize()`：PROFILE 规范化（已废弃，统一 mesh-member）
- `gps_mesh_role_normalize()`：MESH_ROLE 规范化（master/member）

#### Master TLS 控制面
- `gps_mesh_ensure_master_tls()`：确保 Master 自签 TLS 证书存在
- `gps_mesh_write_tls_fp()`：计算并写入公钥指纹（`sha256//BASE64` 格式）
- `gps_mesh_master_tls_on()`：检查 TLS 是否已启用

#### 安全策略
- `gps_mesh_require_https_or_loopback()`：强制公网 Master 必须 https
- `gps_mesh_curl()`：统一 curl 封装（TLS 钉扎 + TOKEN header 文件）
- `gps_mesh_url_is_loopback()`：判断是否为回环地址

#### 节点标识
- `gps_mesh_ensure_node_id()`：确保节点 ID 存在
- `gps_mesh_defaults()`：Mesh 默认参数

#### 连通性诊断
- `gps_mesh_print_local_health()`：Master 本机控制面健康检查
- `gps_mesh_print_member_health()`：Member 到 Master 连通性检查
- `gps_mesh_print_connectivity_summary()`：组网连通性摘要
- `gps_mesh_wg_handshake_stats()`：WG 握手统计（日志解析）
- `gps_mesh_remediate_local_wg()`：修复本地 WG 监听

#### Master URL 管理
- `gps_mesh_join_urls()`：输出所有可用 join URL
- `gps_mesh_primary_join_url()`：主 join URL
- `gps_mesh_resolve_master_host()`：解析 Master 域名

#### 集群 TOKEN
- `gps_mesh_ensure_cluster_token()`：确保集群 TOKEN 存在
- `gps_mesh_token_rotate()`：轮换集群 TOKEN
- `gps_mesh_mask_token()`：脱敏显示 TOKEN

#### 角色切换
- `gps_mesh_become_master()`：升级为 Master
- `gps_mesh_become_member()`：加入为 Member
- `gps_mesh_bootstrap_from_env()`：安装时从环境变量初始化角色

#### 集群自动升级
- `gps_mesh_cluster_schedule_upgrade()`：调度集群升级
- `gps_mesh_cmd_upgrade_cluster()`：执行集群升级
- `gps_mesh_cluster_upgrade_cooling()`：升级失败冷却

#### GitHub Webhook
- `gps_mesh_webhook_set_secret()`：设置 webhook secret
- `gps_mesh_webhook_show()`：显示 webhook 配置
- `gps_mesh_webhook_url()`：生成 webhook URL

### 6.4 WireGuard (lib/mesh/wireguard.sh)

**文件**：[lib/mesh/wireguard.sh](file:///c:/Users/stone/geoproxy-server/lib/mesh/wireguard.sh)

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_mesh_gen_wg_keypair()` | 生成 WG 密钥对（调用 sing-box） |
| `gps_mesh_ensure_wg_keys()` | 确保 WG 密钥存在 |
| `gps_mesh_ensure_overlay_ip()` | 确保 overlay IP 分配 |
| `gps_mesh_endpoints_json()` | 渲染 endpoints 中的 WG endpoint |
| `gps_mesh_peers_endpoint_json()` | 从 peers.json 渲染 WG peers 列表 |
| `gps_mesh_outbounds_json()` | 渲染 outbounds（默认 direct） |
| `gps_mesh_route_json()` | 渲染 route 规则 |

**Overlay 网络**：
- 默认前缀：`10.66.0.0/16`
- Master 固定：`10.66.0.1`
- Member：根据 NODE_ID 哈希分配 `10.66.0.2-254`
- 每个 peer 仅分配 `/32`（单主机路由），不整段劫持

### 6.5 Peers 管理 (lib/mesh/peers.sh)

**文件**：[lib/mesh/peers.sh](file:///c:/Users/stone/geoproxy-server/lib/mesh/peers.sh)

**peers.json 结构**：
```json
{
  "schema": 1,
  "updated_at": "2026-01-01T00:00:00Z",
  "nodes": [
    {
      "node_id": "node1",
      "public_key": "...",
      "endpoint": "1.2.3.4:51820",
      "overlay_ip": "10.66.0.2",
      "roles": ["edge"],
      "keepalive": 25,
      "tripped": 0,
      "last_seen": "2026-01-01T00:00:00Z"
    }
  ]
}
```

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_mesh_peers_empty_doc()` | 生成空 peers 文档 |
| `gps_mesh_peers_load_or_init()` | 加载或初始化 peers 文件 |
| `gps_mesh_peers_upsert_self()` | 更新本机节点信息 |
| `gps_mesh_peer_add()` | 手动添加 peer |
| `gps_mesh_peer_rm()` | 手动移除 peer |
| `gps_mesh_export()` | 导出 peers |
| `gps_mesh_import()` | 导入 peers |

### 6.6 发现与注册 (lib/mesh/discovery.sh)

**文件**：[lib/mesh/discovery.sh](file:///c:/Users/stone/geoproxy-server/lib/mesh/discovery.sh)

**核心函数**：

| 函数 | 说明 |
|------|------|
| `gps_mesh_register_and_pull()` | 向 Master 注册并拉取 peers |
| `gps_mesh_sync_master()` | 同步 Master（注册 + 合并 peers） |
| `gps_mesh_ensure_boot()` | 开机确保组网就绪 |
| `gps_mesh_sync()` | 同步 peers |

**注册流程**：
1. Member 构造节点信息（node_id、public_key、endpoint、overlay_ip 等）
2. POST 到 `https://master:19527/v1/register`（Bearer Token）
3. Master 验证 TOKEN，分配/确认 overlay IP
4. Master 返回完整 peers 列表 + 集群目标版本
5. Member 合并 peers，更新本地配置

### 6.7 Mesh CLI (lib/mesh/cli.sh)

**文件**：[lib/mesh/cli.sh](file:///c:/Users/stone/geoproxy-server/lib/mesh/cli.sh)

**子命令清单**：

| 子命令 | 说明 |
|--------|------|
| `mesh ensure` | 确保组网就绪 |
| `mesh show` / `mesh status` | 显示组网状态 |
| `mesh join` | 加入 Master |
| `mesh join-export` | 导出 join 命令 |
| `mesh role master/member` | 设置角色 |
| `mesh sync-master` | 立即同步 Master |
| `mesh connectivity` | 连通性诊断 |
| `mesh remediate` | 修复本地 WG |
| `mesh port-checklist` | 防火墙端口清单 |
| `mesh migrate-tls` | Member 修复 TLS/连通性 |
| `mesh token rotate` | Master 轮换 TOKEN |
| `mesh webhook set-secret/show` | GitHub webhook 管理 |
| `mesh peer add/rm` | 手动管理 peer |
| `mesh export/import` | 导入导出 peers |
| `mesh upgrade-cluster` | 执行集群升级 |
| `mesh menu-role` | 角色选择菜单 |

### 6.8 Master 注册服务 (scripts/mesh_master.py)

**文件**：[scripts/mesh_master.py](file:///c:/Users/stone/geoproxy-server/scripts/mesh_master.py)

**技术实现**：
- 基于 Python 标准库 `http.server.ThreadingHTTPServer`
- 自签 TLS（可禁用）
- 线程锁保护 peers 文件读写

**API 端点**：

| 方法 | 路径 | 说明 | 鉴权 |
|------|------|------|------|
| GET | `/v1/health` | 健康检查 | 否 |
| POST | `/v1/register` | 节点注册 + 拉 peers | Bearer Token |
| POST | `/v1/heartbeat` | 心跳上报 | Bearer Token |
| GET | `/v1/peers` | 获取 peers 列表 | Bearer Token |
| POST | `/v1/hook/github` | GitHub Release webhook | HMAC SHA256 |
| GET | `/v1/hook/github` | Webhook 端点说明 | 否 |

---

## 7. 关键数据结构

### 7.1 state.env 状态文件

**位置**：`/etc/geoproxy-server/state.env`（权限 600）

**格式**：bash `KEY=VALUE`，使用 `%q` 序列化防注入

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PROTOCOL` | 入站协议 | `tuic` |
| `PORT` | 代理端口 | 随机 |
| `UUID` | UUID | 自动生成 |
| `PASSWORD` | 密码 | =UUID |
| `PUBLIC_IP` | 公网 IPv4 | 自动探测 |
| `PUBLIC_IP6` | 公网 IPv6 | 自动探测 |
| `STACK_MODE` | 协议栈模式 | `dual` |
| `LOG_LEVEL` | 日志级别 | `debug` |
| `CORE_VER` | sing-box 版本 | - |
| `TUIC_NAME` | 节点名 | hostname |
| `KIWI_VEID` | KiwiVM VEID | - |
| `KIWI_API_KEY` | KiwiVM API Key | - |
| `TRAFFIC_WARN_PCT` | 流量告警阈值 | `80` |
| `TRAFFIC_STOP_PCT` | 流量停服阈值 | `95` |
| `TRAFFIC_CHECK_SEC` | 流量检查间隔 | `300` |
| `TRAFFIC_TRIPPED` | 熔断标记 | `0` |
| `MESH_ROLE` | Mesh 角色 | `master` |
| `MESH_MASTER_URL` | Master URL | - |
| `MESH_TLS_PIN` | Master TLS 指纹 | - |
| `MESH_CLUSTER_TOKEN` | 集群 TOKEN | 自动生成 |
| `NODE_ID` | 节点 ID | 主机名派生 |
| `WG_PUBLIC_KEY` | WG 公钥 | 自动生成 |
| `MESH_OVERLAY_IP` | Overlay IP | 哈希分配 |
| `INSTALLED_AT` | 安装时间 | - |

### 7.2 config.json 配置文件

**位置**：`/etc/geoproxy-server/config.json`（权限 600）

**结构**：
```json
{
  "log": { "level": "debug", "timestamp": true },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wg-ep",
      "system": false,
      "mtu": 1408,
      "address": ["10.66.0.x/32"],
      "private_key": "...",
      "listen_port": 51820,
      "peers": [ ... ]
    }
  ],
  "inbounds": [
    { "type": "tuic", "tag": "tuic-in-v4", "listen": "0.0.0.0", ... },
    { "type": "tuic", "tag": "tuic-in-v6", "listen": "::", ... }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": { ... }
}
```

### 7.3 peers.json 节点列表

**位置**：`/etc/geoproxy-server/mesh/peers.json`（权限 600）

详见 [6.5 Peers 管理](#65-peers-管理libmeshpeerssh)

---

## 8. 系统服务与定时器

### 8.1 服务清单

| 服务名 | 类型 | 监听端口 | 说明 |
|--------|------|----------|------|
| `geoproxy-tuic.service` | 主服务 | 代理端口（动态） | sing-box 主代理进程 |
| `geoproxy-mesh-master.service` | Master 控制面 | TCP 19527 | 节点注册 API（仅 Master） |
| `geoproxy-mesh-sync.timer` | 定时器 | - | 周期同步 Master（默认 60s） |
| `geoproxy-mesh-upgrade.service` | 一次性服务 | - | 集群自动升级 |
| `geoproxy-agent.service` | Agent 服务 | TCP 19528 | v2rayA 节点池 API |
| `geoproxy-traffic.timer` | 定时器 | - | 流量检查（默认 300s） |
| `geoproxy-traffic.service` | 一次性服务 | - | 单次流量检查 |

### 8.2 主服务 (geoproxy-tuic.service)

- **Type**：simple
- **ExecStartPre**：`geoproxy-server mesh ensure`（确保组网配置最新）
- **ExecStart**：`sing-box run -c /etc/geoproxy-server/config.json`
- **Restart**：on-failure

### 8.3 Mesh Master 服务 (geoproxy-mesh-master.service)

- **Type**：simple
- **ExecStart**：`python3 /path/to/mesh_master.py`
- **EnvironmentFile**：`/etc/geoproxy-server/mesh/master.env`（仅含最小凭证）
- **Restart**：always

### 8.4 Mesh Sync 定时器 (geoproxy-mesh-sync.timer)

- **OnBootSec**：10s
- **OnUnitActiveSec**：`MESH_SYNC_SEC`（默认 60s）
- **Unit**：`geoproxy-mesh-sync.service`
- **服务内容**：`geoproxy-server mesh sync-master`

### 8.5 Agent 服务 (geoproxy-agent.service)

- **Type**：simple
- **ExecStart**：`python3 /path/to/geoagent.py`
- **EnvironmentFile**：`/etc/geoproxy-server/agent.env`
- **Restart**：always

---

## 9. 安全设计

### 9.1 状态文件安全

- 所有状态文件权限 600
- `gps_source_env()` 拒绝加载符号链接、宽松权限、异属主文件
- 使用 `%q` 序列化变量防止注入
- 原子写入：临时文件 + `mv` 替换

### 9.2 并发安全

- 状态文件操作使用 flock（或 mkdir 自旋回退）互斥
- `gps_with_state_lock()` 确保串行化状态变更
- Python 服务使用 threading.Lock

### 9.3 Mesh 控制面安全

- 公网 Master 强制 HTTPS（自签 TLS）
- 节点端使用 `curl --pinnedpubkey` 公钥指纹钉扎
- TOKEN 通过 `curl -H @file` 传递，不进 argv（ps 不可见）
- 明文 HTTP 仅允许 loopback

### 9.4 Webhook 安全

- GitHub webhook 使用 HMAC SHA256 签名校验（`X-Hub-Signature-256`）
- Secret 仅存于 master.env（600 权限），不进 argv

### 9.5 Agent 安全

- Bearer Token 鉴权
- 明文 HTTP，建议绑定 127.0.0.1 或通过云安全组限制来源
- TOKEN 存储于 agent.env（600 权限）

### 9.6 密钥安全

- WG 密钥、Reality 密钥必须由 sing-box 真实生成，禁止回退到占位密钥
- 所有私钥文件 600 权限
- TLS 目录 700 权限

### 9.7 输入校验

- 所有用户输入严格校验：端口、UUID、IP、单行文本、流量阈值
- JSON 输出使用 `gps_json_escape()` 转义
- URL 使用百分号编码

### 9.8 升级安全

- 下载的归档使用 GitHub API 返回的 sha256 摘要校验
- 核心升级：新版本先过 `sing-box check`，失败自动回滚
- 脚本升级：先下载校验，通过后才停服务替换

---

## 10. 配置与状态管理

### 10.1 配置项修改

使用 `geoproxy-server change <项> <值>` 修改配置，修改后自动：
1. 更新 `state.env`
2. 重新生成 `config.json`
3. 重启 sing-box 服务
4. 输出新的分享 URL

**可修改项**：

| 项 | 说明 |
|----|------|
| `port` | 代理端口（auto = 随机） |
| `uuid` | UUID |
| `passwd` / `password` | 密码 |
| `protocol` / `proto` | 入站协议 |
| `ip` / `ipv4` | 公网 IPv4 |
| `ip6` / `ipv6` | 公网 IPv6 |
| `ips` | 自动重探双栈 |
| `name` / `remark` | 节点名 |
| `log` / `level` | 日志级别 |
| `kiwivm` | KiwiVM 凭证 |
| `traffic-warn` | 流量告警阈值 |
| `traffic-stop` | 流量停服阈值 |
| `traffic-interval` | 流量检查间隔 |
| `mesh-mtu` | WG MTU |
| `mesh-master-host` | Master 域名 |
| `cluster-auto-upgrade` | 集群自动升级开关 |
| `agent-bind` | Agent 绑定地址 |

### 10.2 状态持久化

- **state.env**：主要状态（重启保留）
- **peers.json**：Mesh 节点列表
- **master.env**：Master 专用最小凭证
- **agent.env**：Agent 凭证与配置
- **master-tls.\***：Master 控制面 TLS 证书
- **join.cmd**：join 命令（600 权限）

---

## 11. 部署与运行

### 11.1 系统要求

| 项目 | 要求 |
|------|------|
| 权限 | root |
| 初始化系统 | systemd（生产环境） |
| 架构 | amd64 / arm64 |
| 网络 | 可访问 GitHub Releases + api.64clouds.com |
| 工具 | curl ≥ 7.55, python3, openssl |

### 11.2 快速安装

```bash
# 方式一：管道安装（推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/main/install.sh)

# 方式二：clone 后安装
git clone --depth 1 https://github.com/vistone/geoproxy-server.git /tmp/geoproxy-server
sudo bash /tmp/geoproxy-server/install.sh
rm -rf /tmp/geoproxy-server

# 指定版本（仅排障）
GPS_VERSION=v0.2.71 sudo -E bash install.sh
```

### 11.3 Mesh 部署

**首台（Master）**：
```bash
bash install.sh
# 安装结束打印加入命令
```

**其它节点（Member）**：
```bash
GPS_MESH_MASTER=https://MASTER_IP:19527 \
GPS_MESH_TLS_PIN=sha256//... \
GPS_MESH_TOKEN=... \
bash install.sh
```

### 11.4 常用操作

```bash
# 查看状态
geoproxy-server info
geoproxy-server status

# 查看分享链接
geoproxy-server url

# 切换协议
geoproxy-server change protocol hysteria2

# 查看日志
geoproxy-server log

# 健康检查
geoproxy-server doctor

# 升级
geoproxy-server upgrade all

# 配置 KiwiVM 流量熔断
geoproxy-server change kiwivm <VEID> <API_KEY>

# 查看组网状态
geoproxy-server mesh show

# 查看防火墙端口清单
geoproxy-server mesh port-checklist
```

### 11.5 路径速查

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/geoproxy-server` | 入口命令 |
| `/usr/local/lib/geoproxy-server/scripts/` | 管理脚本树 |
| `/usr/local/lib/geoproxy-server/sing-box` | sing-box 二进制 |
| `/etc/geoproxy-server/state.env` | 状态文件 |
| `/etc/geoproxy-server/config.json` | sing-box 配置 |
| `/etc/geoproxy-server/tls/` | TLS 证书 |
| `/etc/geoproxy-server/mesh/` | Mesh 相关 |
| `/var/log/geoproxy-server/` | 日志目录 |
| `/etc/geoproxy-kiwivm.env` | KiwiVM 长期凭证 |

---

## 12. 测试体系

### 12.1 测试框架

- **框架**：BATS (Bash Automated Testing System)
- **运行方式**：`bats --tap tests/`
- **测试数量**：20+ 测试文件，覆盖安装、配置、协议、Mesh、流量、Agent 等

### 12.2 测试分类

| 测试文件 | 覆盖范围 |
|----------|----------|
| `test_bootstrap.bats` | 安装引导 |
| `test_install.bats` | 安装流程 |
| `test_config.bats` | 配置生成 |
| `test_protocol.bats` | 协议插件 |
| `test_mesh.bats` | Mesh 基础功能 |
| `test_mesh_failover.bats` | Mesh 故障转移（旧版功能残留测试） |
| `test_mesh_route.bats` | Mesh 路由 |
| `test_mesh_tls.bats` | Mesh TLS |
| `test_mesh_webhook.bats` | Mesh Webhook |
| `test_mesh_cluster_upgrade.bats` | 集群升级 |
| `test_traffic.bats` | 流量监控 |
| `test_traffic_trip.bats` | 流量熔断 |
| `test_agent.bats` | Agent API |
| `test_agent_deploy.bats` | Agent 部署 |
| `test_doctor.bats` | 健康检查 |
| `test_download.bats` | 下载与升级 |
| `test_firewall.bats` | 防火墙 |
| `test_state.bats` | 状态管理 |
| `test_systemd.bats` | systemd 集成 |
| `test_release.bats` | 发布流程 |
| `test_stability.bats` | 稳定性 |
| `test_hygiene.bats` | 代码卫生 |
| `test_env.bats` | 环境变量 |

### 12.3 测试约定

- 使用 `GPS_TEST_PREFIX` 前缀隔离测试环境
- 修复 bug 先写失败用例再修复
- 新增功能必须同步补充测试用例

---

## 13. CI/CD 与发布

### 13.1 CI 流水线 (.github/workflows/ci.yml)

- **触发**：push / PR
- **检查项**：
  - shellcheck（无 error）
  - shfmt（无漂移）
  - bats 全量测试通过

### 13.2 发布流水线 (.github/workflows/release.yml)

- **触发**：推送 tag `v*.*.*`
- **产物**：
  - `geoproxy-server-<tag>.tar.gz`（源码包）
  - `.sha256` 校验文件
- **校验**：强制校验 `VERSION` 文件与 tag 一致

### 13.3 版本号规则

- 严格语义化版本：`vX.Y.Z`
- 每次发布 **patch+1**
- 禁止随意跳版本
- `VERSION` 与 `CHANGELOG.md` 最新标题必须一致

### 13.4 发布步骤

1. 修改 `VERSION` 为 patch+1
2. `CHANGELOG.md` 顶部追加新版本节
3. 更新 `README.md` 中的版本引用（如有）
4. 提交并推送：`git add -A && git commit && git push origin main`
5. 打 tag 并推送：`git tag vX.Y.Z && git push origin vX.Y.Z`
6. GitHub Actions 自动创建 Release

### 13.5 集群自动升级

- **Master**：配置 GitHub webhook，Release 后自动 `upgrade self`
- **Member**：每 `mesh-sync` 读取 `cluster.target_version`，不一致则自动升级
- **冷却机制**：升级失败后 600s 内不再重试，防止反复停服

---

## 14. 开发规范

### 14.1 代码风格

- **shellcheck**：无 error
- **shfmt**：格式统一
- 函数命名：`gps_` 前缀（公共）/ `_gps_` 前缀（私有）
- 变量命名：`GPS_` 前缀（全局常量）
- 使用 `set -euo pipefail`

### 14.2 模块约定

- 每个 `.sh` 文件顶部有功能说明
- 新增模块在 `geoproxy-server.sh` 中 source
- 协议插件遵循 [5.4 插件接口规范](#54-插件接口规范)

### 14.3 安全编码

- 所有外部输入必须校验
- 密钥/凭证绝不回退到占位值
- 凭证不进 argv，不写日志
- 文件操作注意权限（600 敏感文件）

### 14.4 文档位置

- 设计文档：`docs/superpowers/specs/`
- 计划文档：`docs/superpowers/plans/`
- 任务简报：`docs/superpowers/briefs/`
- API 文档：`docs/geoproxy-agent-api.md`
- 发布规则：`docs/RELEASING.md`
- 开发规则：`AGENTS.md`

---

*本文档基于 GeoProxy Server v0.2.71 生成*

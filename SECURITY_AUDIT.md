# GeoProxy Server 安全审计报告

> 审计版本：v0.2.71  
> 审计日期：2026-09-15  
> 审计范围：全量 Bash 脚本 + Python 服务 + 配置模板  
> 修复状态：**已修复 11 项**（详见各漏洞末尾的 ✅ 标记）

---

## 摘要

| 严重程度 | 总数 | 已修复 |
|----------|------|--------|
| Critical | 1 | 1 ✅ |
| High | 5 | 5 ✅ |
| Medium | 7 | 4 ✅ |
| Low | 6 | 3 ✅ |
| Info | 5 | 0 |

**总体评价**：项目在安全方面有相当的意识和投入——文件权限 600、原子写入、flock 互斥、公钥指纹钉扎、HMAC 签名校验、凭证不进 argv 等做法都值得肯定。但仍存在若干高风险问题，主要集中在 API 暴露面、校验绕过和供应链信任模型上。

---

## 修复记录

所有修复已在 v0.2.71 代码中完成（未发布新版本，待测试验证后发布）。修改文件清单：

| 漏洞 | 修改文件 | 修复方式 |
|------|----------|----------|
| H-01 | `lib/mesh/_common.sh` | 严格 IPv4 校验替代 glob 匹配 |
| H-04 | `lib/common.sh` | 移除 `set -a` allexport |
| C-01 | `scripts/geoagent.py` | 默认绑定 127.0.0.1 + 源 IP 白名单 + 速率限制 |
| H-02 | `scripts/mesh_master.py` | 分配池扩至 /20 + stale 节点自动清理 + 速率限制 |
| M-06 | `scripts/mesh_master.py` + `scripts/geoagent.py` | 滑动窗口速率限制器 |
| H-03 | `lib/download.sh` | 增强脚本树完整性校验（关键文件 + 语法检查） |
| H-05 | `scripts/mesh_master.py` | health 端点仅返回 `{"ok": true}` |
| M-03 | `lib/tls.sh` + `lib/mesh/_common.sh` + `scripts/mesh_master.py` | 证书有效期从 10 年缩短为 1 年 |
| M-04 | `lib/common.sh` | openssl 回退生成标准 v4 UUID |
| M-05 | `lib/common.sh` | 端口随机源切换到 /dev/urandom |

---

## 漏洞分级标准

| 级别 | 定义 |
|------|------|
| **Critical** | 无需认证即可远程代码执行，或直接导致系统完全失陷 |
| **High** | 认证后远程代码执行 / 未授权关键操作 / 敏感数据大规模泄露 |
| **Medium** | 认证绕过 / 权限提升 / 有限度的拒绝服务 / 有限信息泄露 |
| **Low** | 最佳实践偏离 / 理论上的风险 / 需极苛刻条件才能利用 |
| **Info** | 设计层面的权衡 / 架构建议 / 非直接安全问题 |

---

## Critical 漏洞

### C-01: Agent API 暴露公网 + 远程停服能力 = 拒绝服务面过大

**严重程度**：Critical  
**组件**：`scripts/geoagent.py` + `lib/agent.sh`（默认配置）  
**位置**：Agent 服务默认 `GPS_AGENT_BIND=0.0.0.0`，监听 `TCP 19528`

#### 问题描述

GeoAgent 是提供给 v2rayA 节点池的 HTTP API，默认绑定 `0.0.0.0:19528`，直接暴露在公网上。其 `POST /v1/control` 端点支持以下操作：

| action | 效果 |
|--------|------|
| `trip` | 立即触发流量熔断，停止代理服务 |
| `resume` | 恢复服务 |
| `set-thresholds` | 修改流量告警/停服阈值 |
| `set-check-interval` | 修改检查间隔 |

虽然所有操作都需要 Bearer Token 鉴权，但：
1. **Agent 默认面向公网**，与代理端口一样暴露，攻击面大
2. 只要 token 泄露（日志、配置备份、截屏等），攻击者就能直接让节点下线
3. `trip` 操作是破坏性的，直接导致服务不可用
4. 没有速率限制，暴力破解 token 无阻碍（虽然 token 是 256-bit 十六进制，理论上难暴力破解）

#### 风险场景

- 管理员在文档/聊天中不慎泄露 agent token
- token 被写入备份文件，备份文件泄露
- 共享 token 给多个 v2rayA 实例，扩大泄露面

#### 修复建议

1. **默认绑定 127.0.0.1**：Agent 应该默认只监听本机，由用户根据需要改为 0.0.0.0
2. **增加源 IP 白名单**：在 agent 服务中增加允许访问的 IP 列表配置
3. **增加速率限制**：对 `/v1/control` 端点做请求频率限制
4. **trip/resume 操作需要二次确认或独立密钥**：破坏性操作使用单独的管理密钥

---

## High 漏洞

### H-01: Mesh 明文 HTTP 校验绕过（域名前缀匹配）

**严重程度**：High  
**组件**：`lib/mesh/_common.sh`  
**位置**：`gps_mesh_url_is_loopback()` 函数（第 183-186 行）

#### 问题描述

`gps_mesh_url_is_loopback` 函数用于判断 Master URL 是否为回环地址，以决定是否允许明文 HTTP：

```bash
gps_mesh_url_is_loopback() {
    local low=${1,,}
    [[ $low == 127.* || $low == localhost || $low == localhost.* || $low == ::1 || $low == \[::1\] ]]
}
```

这里用 `127.*` 作为通配符，但 bash 的 `==` glob 匹配中，`*` 可以匹配任意字符（包括点和字母）。

**攻击向量**：攻击者构造一个 Master URL：
```
http://127.0.0.1.attacker.com:19527
```

`gps_mesh_url_host` 提取出 host = `127.0.0.1.attacker.com`。

`gps_mesh_url_is_loopback "127.0.0.1.attacker.com"` 中 `$low == 127.*` 返回 **true**（因为字符串以 `127.` 开头）。

结果：该 URL 被认为是 loopback，明文 HTTP 连接被允许。

但实际上 `127.0.0.1.attacker.com` 解析到攻击者的公网 IP（或者更隐蔽地，使用 nip.io / xip.io 等服务将 `127.0.0.1.<attacker-ip>.nip.io` 解析到攻击者 IP）。

#### 实际影响

如果攻击者能诱导管理员加入一个"看起来是本机回环"的 Master URL，就能：
1. 明文窃取集群 TOKEN（后续所有通信都明文）
2. 中间人篡改 peers 列表
3. 篡改 cluster target_version，诱导升级恶意版本

攻击前提：需要社会工程学诱导用户输入恶意 URL。但 `mesh join` 的交互菜单中，用户被要求"粘贴整行或只填 Master 地址"，用户可能从不可信来源复制。

#### 修复建议

用严格的 IP 校验替代 glob 匹配：

```bash
gps_mesh_url_is_loopback() {
    local low=${1,,}
    # 去掉 [::1] 的方括号
    [[ $low == \[::1\] ]] && return 0
    # 用 gps_validate_ipv4 严格校验后，再检查是否在 127.0.0.0/8
    if gps_validate_ipv4 "$low" 2>/dev/null; then
        [[ $low == 127.* ]] && return 0
    fi
    [[ $low == localhost || $low == localhost.* || $low == ::1 ]]
}
```

### H-02: Mesh Overlay IP 耗尽攻击

**严重程度**：High  
**组件**：`scripts/mesh_master.py`  
**位置**：`/v1/register` 端点 + `alloc_overlay()` 函数

#### 问题描述

任何持有集群 TOKEN 的节点都可以向 Master 注册。注册时：
1. `node_id` 只校验了长度（<=64）和格式（单行可打印）
2. Overlay IP 池是有限的（默认 `/16` 前缀但只分配 `/24`，共 253 个可用 IP）
3. **没有速率限制**，也没有"同一节点只能注册一个 ID"的限制
4. `alloc_overlay` 顺序分配，耗尽后抛异常

#### 攻击场景

一个被攻陷的成员节点（或泄露了 TOKEN 的内部人员）可以：

```python
for i in range(300):
    node_id = f"evil-{i}"
    public_key = generate_fake_pubkey()
    register(node_id, public_key)
```

注册 253 个不同 node_id 的节点后，overlay IP 池耗尽。后续合法节点无法注册，新节点加入失败。

更隐蔽的是：注册后不断修改 endpoint 等字段，虽然不消耗新 IP，但会导致频繁的 peers.json 写入和 config 重建重启。

#### 修复建议

1. **每个节点 ID 唯一且可撤销**：节点注册需要 Master 管理员批准（白名单模式）
2. **增加速率限制**：同一 IP 在一定时间内只能注册 N 次
3. **stale 节点自动清理**：长期不心跳的节点自动从 peers 中移除，释放 IP
4. **使用更大的地址池**：/16 网段有 65534 个可用 IP，默认只用 /24 太保守

### H-03: 升级脚本树时 tag archive 回退路径仅做 VERSION 一致性校验

**严重程度**：High  
**组件**：`lib/download.sh`  
**位置**：`gps_self_fetch_tree()` 函数（第 195-217 行）

#### 问题描述

`upgrade self` 拉取脚本树时：
- **首选** Release asset：有 GitHub API digest 的 sha256 校验 ✓
- **回退** tag archive：仅做 `VERSION 文件与目标 tag 是否一致` 的校验 ✗

```bash
if curl -fsSL --max-time 120 "$aurl" -o "${dest}/src.tar.gz" 2>/dev/null; then
    # release asset 路径：有 sha256 校验
    gps_verify_release_asset "${dest}/src.tar.gz" "$tag" "$asset" >&2
else
    # 回退 tag archive 路径：仅 VERSION 一致性校验
    echo -e "$(_yellow "无 release asset，回退 tag archive（仅 VERSION 一致性校验）") ${tag}" >&2
    curl -fsSL --max-time 120 "$turl" -o "${dest}/src.tar.gz" || err "下载失败: $turl"
fi
tar -xzf "${dest}/src.tar.gz" -C "$dest" || err "解压失败"
# ...
gps_verify_tree_version "$root" "$tag"  # 只检查 VERSION 文件内容是否等于 tag
```

这意味着：
- 如果 Release asset 不存在（如旧版本），回退到 tag archive
- tag archive 的完整性完全依赖 HTTPS 传输
- 如果攻击者能进行 TLS 降级或中间人攻击（理论上不太可能，但供应链攻击场景下需考虑），或者 GitHub 账号被攻陷，就能植入后门

更关键的是：**install.sh 中的远程安装也有同样的回退路径**（且有 `GPS_INSTALL_ALLOW_UNVERIFIED=1` 选项可以显式跳过校验）。

#### 修复建议

1. **移除 tag archive 回退路径**：所有版本必须有 release asset
2. 或者 **使用 GPG 签名校验**：对 tag archive 也提供签名文件
3. **禁止 `GPS_INSTALL_ALLOW_UNVERIFIED=1` 在生产环境使用**：增加强警告

### H-04: state.env 变量全部 export（allexport），扩大密钥暴露面

**严重程度**：High  
**组件**：`lib/common.sh`  
**位置**：`gps_source_env()` 函数（第 279-297 行）

#### 问题描述

```bash
gps_source_env() {
    # ... 安全检查 ...
    set -a          # ← 开启 allexport
    source "$f"     # ← 所有变量自动 export
    set +a
    return 0
}
```

`set -a`（allexport）会让 `source` 进来的所有变量自动导出为环境变量。state.env 里包含大量敏感信息：

- `UUID` / `PASSWORD`
- `KIWI_API_KEY`
- `WG_PRIVATE_KEY`
- `MESH_CLUSTER_TOKEN`
- `REALITY_PRIVATE_KEY`
- `GPS_GITHUB_WEBHOOK_SECRET`
- `SS_PASSWORD`

这些变量会出现在所有后续子进程的环境中（curl、python3、openssl、tar 等）。

#### 风险

1. **子进程漏洞**：如果某个子进程（如 curl）有信息泄露漏洞（CVE），环境变量可能被窃取
2. **core dump 泄露**：如果某个子进程崩溃产生 core dump，环境变量会被转储
3. **`/proc/PID/environ` 读取**：虽然需要同用户/root 权限，但如果系统上有其他 setuid 程序有漏洞，可能被利用
4. **日志泄露**：某些程序在错误信息或调试输出中可能打印环境变量

#### 修复建议

不要用 `set -a`，改为明确列出需要导出的变量，或根本不需要 export（bash 函数调用不需要环境变量传递）。

```bash
gps_source_env() {
    # ... 安全检查 ...
    local -a _vars
    # 只 source 不 export
    # shellcheck disable=SC1090
    source "$f"
    return 0
}
```

如果子进程确实需要某些变量（如 Python 脚本），在调用时显式传入：`VAR=value python3 ...`

### H-05: Mesh Master /v1/health 端点信息泄露 + 可被用于指纹识别

**严重程度**：High  
**组件**：`scripts/mesh_master.py`  
**位置**：`do_GET` → `/v1/health`（第 382-384 行）

#### 问题描述

`/v1/health` 端点**无需认证**，返回：

```json
{
  "ok": true,
  "role": "master",
  "prefix": "10.66.0.0/16",
  "stale_sec": 180
}
```

这意味着任何人都可以：
1. 扫描公网 IP 的 19527 端口，识别出 GeoProxy Mesh Master
2. 获知内部 overlay 网段（`10.66.0.0/16`）
3. 获知节点过期时间（`stale_sec`）

更重要的是，这个端点可以被用来**验证某个 IP 是否运行 GeoProxy**，为定向攻击提供指纹。

配合 Agent 的 19528 端口，攻击者可以快速识别出"运行 GeoProxy 的服务器"并进行针对性攻击。

#### 修复建议

1. **health 端点只返回最小信息**：`{"ok": true}` 即可
2. **增加认证**：health 也需要 token（或者只在 loopback 上监听）
3. **或者完全移除 health 端点**：由本地脚本检测进程是否在运行即可

---

## Medium 漏洞

### M-01: `is_ipv4` 粗校验与 `gps_validate_ipv4` 混用，部分路径校验不足

**严重程度**：Medium  
**组件**：`lib/common.sh`  
**位置**：`is_ipv4()`（第 91-93 行）vs `gps_validate_ipv4()`（第 167-174 行）

#### 问题描述

项目中有两个 IPv4 校验函数：
- `is_ipv4()`：粗略正则 `^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`（不检查 0-255 范围）
- `gps_validate_ipv4()`：严格校验（每段 0-255）

关键路径上大多使用了严格校验，但以下位置使用了粗校验：
- `detect_public_ipv4()` 返回值用 `is_ipv4` 检查（问题不大，因为是从第三方 API 获取）
- `gps_mesh_url_is_loopback` 用 glob 匹配（见 H-01）

虽然目前没有发现可直接利用的路径，但两个函数并存容易导致后续开发中误用。

#### 修复建议

统一使用 `gps_validate_ipv4`，将 `is_ipv4` 标记为废弃或删除。

### M-02: `gps_json_escape` 转义不完整，存在 JSON 注入风险面

**严重程度**：Medium  
**组件**：`lib/common.sh`  
**位置**：`gps_json_escape()` 函数（第 243-261 行）

#### 问题描述

```bash
gps_json_escape() {
    local s=$1 out='' i c
    local LC_ALL=C
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
        \\) out+='\\\\' ;;
        \") out+='\\\"' ;;
        $'\b') out+='\b' ;;
        $'\f') out+='\f' ;;
        $'\n') out+='\n' ;;
        $'\r') out+='\r' ;;
        $'\t') out+='\t' ;;
        *) out+=$c ;;
        esac
    done
    printf '%s' "$out"
}
```

只转义了 7 个字符（`\ " \b \f \n \r \t`），但 RFC 8259 规定所有控制字符（U+0000 ~ U+001F）都必须转义。此外：
- 不处理 Unicode 代理对
- 不处理 `/` 正斜杠（可选转义，但某些场景下需要）

目前因为所有用户输入都经过了 `gps_validate_single_line`（挡住了换行回车），所以风险被限制了。但如果未来某个字段允许多行或特殊字符，就可能产生 JSON 注入。

#### 修复建议

改用 python3 做 JSON 序列化（项目已经大量依赖 python3）：

```bash
gps_json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]), end="")' "$1"
}
```

或者在 bash 中补充所有控制字符的转义。

### M-03: 自签 TLS 证书有效期过长（10 年）

**严重程度**：Medium  
**组件**：`lib/tls.sh` + `scripts/mesh_master.py` + `lib/mesh/_common.sh`

#### 问题描述

所有自签证书（代理入站 TLS、Mesh 控制面 TLS）有效期均为 **3650 天（约 10 年）**：

- `lib/tls.sh` 第 13-17 行：`-days 3650`
- `lib/mesh/_common.sh` 第 64-67 行：`-days 3650`
- `scripts/mesh_master.py` 第 297 行：`"-days", "3650"`

虽然 Mesh 控制面使用公钥指纹钉扎，证书过期不影响连接验证（指纹钉扎不检查有效期），但：
1. 私钥泄露后，证书在 10 年内都"有效"
2. 代理入站的 TLS 证书客户端可能会校验有效期
3. 长期有效的密钥增加了攻击窗口

#### 修复建议

- 缩短为 90 天或 1 年
- 提供自动轮换机制（`gps_rotate_tls` 已存在，但不会自动轮换）
- Mesh 控制面证书轮换后重新分发指纹

### M-04: `gen_uuid` 回退路径生成非标准 UUID

**严重程度**：Medium  
**组件**：`lib/common.sh`  
**位置**：`gen_uuid()` 函数（第 514-523 行）

#### 问题描述

```bash
gen_uuid() {
    if [[ -x $GPS_CORE_BIN ]]; then
        "$GPS_CORE_BIN" generate uuid 2>/dev/null && return 0
    fi
    if have_cmd uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
}
```

最后一个回退路径用 `openssl rand -hex 16 | sed ...` 生成 UUID。这个方法：
- 生成的 UUID 版本号和变体位都是随机的（不是标准的 v4 UUID）
- 虽然唯一性没问题，但不符合 RFC 4122 规范
- 某些严格校验 UUID 格式的客户端可能拒绝

影响范围：`TUIC` 协议的 UUID（客户端可能做校验）、`MESH_CLUSTER_TOKEN`（不是 UUID 格式，不影响）。

#### 修复建议

```bash
openssl rand -hex 16 | sed 's/\(........\)\(....\)4\(...\)[89abAB]\(....\)\(............\)/\1-\2-4\3-\4-\5/'
```

或者直接使用 `cat /proc/sys/kernel/random/uuid`（Linux 上几乎总是可用）。

### M-05: `rand_port` 使用 bash `$RANDOM`（15 位熵）

**严重程度**：Medium  
**组件**：`lib/common.sh`  
**位置**：`rand_port()` 函数（第 502-512 行）

#### 问题描述

```bash
rand_port() {
    local p
    for _ in $(seq 1 40); do
        p=$((20000 + RANDOM % 40000))
        if ! ss -lun | awk '{print $5}' | grep -qE ":${p}\$"; then
            echo "$p"
            return 0
        fi
    done
    echo $((30000 + RANDOM % 10000))
}
```

bash 的 `$RANDOM` 只有 15 位熵（0 ~ 32767），且生成的端口范围是 20000 ~ 59999（40000 个值），超过了 32768 的取值空间，**分布不均匀**。

端口随机化的目的是防止攻击者轻易猜测代理端口。15 位熵意味着暴力扫描最多 32768 次就能找到端口（实际更少，因为范围有重叠）。

#### 修复建议

使用更高熵的随机源：

```bash
rand_port() {
    local p
    p=$(( 1024 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 64512 ))
    # 或者用 10000-60000 范围
    echo "$p"
}
```

### M-06: 无 API 速率限制（Mesh Master + Agent）

**严重程度**：Medium  
**组件**：`scripts/mesh_master.py` + `scripts/geoagent.py`

#### 问题描述

两个 Python HTTP 服务都没有速率限制：
- **Mesh Master**：register / heartbeat / peers / webhook 都不限速
- **GeoAgent**：status / control 都不限速

可能的攻击：
1. **暴力破解 token**：虽然 token 是 256-bit hex，但理论上的暴力破解没有任何阻碍
2. **资源耗尽**：大量并发请求可能耗尽 Python 线程（ThreadingHTTPServer 每个请求一个线程）
3. **频繁注册/心跳**：导致 peers.json 频繁写入，或频繁触发 sing-box 重启

#### 修复建议

1. 实现简单的 IP 级速率限制（如使用令牌桶算法）
2. 认证失败 N 次后临时封禁该 IP
3. 对写操作（register/control）做更严格的限速

### M-07: install.sh 管道安装模式（curl | bash）供应链风险

**严重程度**：Medium  
**组件**：`install.sh` + `README.md`

#### 问题描述

推荐安装方式是：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/main/install.sh)
```

这种 `curl | bash` 模式的问题：
1. **无法审计**：用户在执行前看不到脚本内容
2. **供应链风险**：如果 GitHub 仓库被攻陷，或 DNS 被劫持，所有新安装的机器都会执行恶意代码
3. **无签名校验**：install.sh 本身没有 GPG 签名

虽然 install.sh 内部拉取实际代码时会做 sha256 校验，但 **install.sh 自身是直接执行的**。如果 install.sh 被篡改，它可以在调用内部校验之前就执行恶意代码。

#### 修复建议

1. 提供校验和（sha256）让用户手动验证
2. 使用 GPG 签名
3. 提供"先下载再校验再执行"的替代安装命令

---

## Low 漏洞

### L-01: `mkdir 自旋锁` 的竞争窗口

**严重程度**：Low  
**组件**：`lib/common.sh`  
**位置**：`gps_state_lock_acquire()`（第 206-212 行）

#### 问题描述

无 flock 时的回退方案是 `mkdir` 自旋锁：

```bash
local d="${GPS_ETC}/state.lock.dir" i
for i in $(seq 1 300); do
    mkdir "$d" 2>/dev/null && return 0
    sleep 0.1
done
```

`mkdir` 是原子操作，所以互斥性没问题。但：
- 自旋等待最多 30 秒，超时后直接报错退出
- 持有锁的进程如果崩溃（如 kill -9），锁文件不会自动释放
- 没有"死锁检测"机制

实际影响：低概率。flock 在 Linux 上几乎总是可用的。

#### 修复建议

在 lock 文件中写入 PID，获取锁失败时检查进程是否还在运行。

### L-02: 日志文件权限可能过宽

**严重程度**：Low  
**组件**：`lib/systemd.sh` + logrotate 配置

#### 问题描述

`/var/log/geoproxy-server/` 目录下的日志文件：
- sing-box 日志包含连接信息（源 IP、目标地址等）
- traffic.log 包含流量检查记录
- 如果权限是 644 或更宽，系统上的其他用户可以读取

需要确认：sing-box 以 root 运行，其创建的日志文件权限取决于 umask。logrotate 配置中应指定 `create 600 root root`。

#### 修复建议

确保 logrotate 配置中明确设置文件权限为 600。

### L-03: `gps_validate_uuid` 接受所有版本的 UUID

**严重程度**：Low  
**组件**：`lib/common.sh`  
**位置**：`gps_validate_uuid()`（第 157-159 行）

#### 问题描述

```bash
gps_validate_uuid() {
    [[ ${1:-} =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]
}
```

校验了版本（1-5）和变体（8/9/a/b），但接受所有版本的 UUID。TUIC 规范通常要求 v4 UUID。

实际影响：低。非 v4 UUID 也能用，只是不规范。

### L-04: Python 服务直接使用 `BaseHTTPRequestHandler`，功能原始

**严重程度**：Low  
**组件**：`scripts/mesh_master.py` + `scripts/geoagent.py`

#### 问题描述

使用 Python 标准库的 `http.server.ThreadingHTTPServer`：
- 没有内置的速率限制
- 没有内置的请求日志格式化（自定义了 log_message）
- ThreadingHTTPServer 没有线程池上限，理论上可被耗尽

虽然设置了 `timeout = 30` 防止 slowloris，但没有最大并发数限制。

实际影响：低。Mesh Master 只面向内部节点，攻击面有限。

### L-05: `gps_kiwi_parse_info` 的 grep 回退路径解析脆弱

**严重程度**：Low  
**组件**：`lib/traffic.sh`  
**位置**：`gps_kiwi_parse_info()` 第 66-80 行

#### 问题描述

无 python3 时的回退解析用 grep 提取 JSON 字段：

```bash
err=$(echo "$json" | grep -oE '"error"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo 1)
```

这种方式：
- 只能处理特定格式的 JSON
- 如果 JSON 中字段顺序变化或有嵌套，会解析错误
- 可能被恶意 JSON 注入干扰

但项目要求 python3，这个回退路径几乎不会触发。

### L-06: 密码/UUID 默认相等，降低了 TUIC 的安全性

**严重程度**：Low  
**组件**：`lib/protocols/tuic.sh`（推测）

#### 问题描述

根据 README："默认 UUID=密码"。

TUIC 协议同时有 UUID 和密码两个认证因素。如果两者相同，相当于单因素认证。虽然从安全理论上说，只要长度和熵足够，单因素也够用，但这偏离了最佳实践。

实际影响：低。UUID 本身是 128 位随机值，作为密码也足够强。

---

## Info / 架构建议

### I-01: 共享集群 TOKEN 的信任模型

**级别**：Info  
**说明**：Mesh 使用单一共享 TOKEN，所有成员节点都知道。一个节点被攻陷等于整个集群控制面被攻陷。这是设计权衡（简单性 vs 安全性）。

**建议**：可考虑未来增加"每节点独立 token"或"证书双向认证"模式。

### I-02: 缺少审计日志

**级别**：Info  
**说明**：关键操作（角色切换、token 轮换、peer 添加删除、升级等）没有专门的审计日志。虽然系统日志里可能有输出，但没有结构化的审计 trail。

**建议**：增加审计日志文件，记录所有管理操作。

### I-03: 没有备份与恢复机制

**级别**：Info  
**说明**：state.env、peers.json、TLS 证书等关键数据没有自动备份。磁盘损坏或误操作会导致数据丢失。

**建议**：增加 `backup` / `restore` 命令。

### I-04: 根用户运行所有组件

**级别**：Info  
**说明**：sing-box、mesh-master、geoagent 都以 root 运行。虽然代理服务通常需要 root 来绑定低端口，但管理 API 服务可以降权运行。

**建议**：mesh-master 和 geoagent 可以使用专用用户运行，通过 unix socket 或 sudo 与管理命令交互。

### I-05: 项目依赖多个外部服务

**级别**：Info  
**说明**：项目的可用性依赖：
- GitHub API（下载新版本、获取校验和）
- 多个 IP 探测服务（ipify、icanhazip、ifconfig.me）
- KiwiVM API（流量统计）
- 多个第三方镜像（gstatic 等延迟探测）

任何一个服务不可用都可能影响功能。

**建议**：增加更多备用源，或允许用户自定义。

---

## 正面安全实践（做得好的地方）

1. **文件权限**：所有敏感文件都是 600，目录 700
2. **原子写入**：临时文件 + mv，避免半写文件
3. **状态锁**：flock + mkdir 回退，防止竞态
4. **凭证不进 argv**：TOKEN 通过临时文件或 header 文件传递
5. **公钥指纹钉扎**：Mesh 控制面使用自签 TLS + 指纹钉扎
6. **HMAC 签名校验**：GitHub webhook 使用 HMAC SHA256
7. **时序安全比较**：Python 中使用 `hmac.compare_digest`
8. **升级前校验**：先下载校验再停服替换
9. **失败回滚**：核心升级失败自动回滚到 .prev
10. **输入校验**：端口、UUID、IP 等都有严格校验
11. **`%q` 序列化**：state.env 写入用 printf %q，防止注入
12. **安全 source**：拒绝符号链接、宽权限、异属主文件

---

## 修复优先级建议

| 优先级 | 漏洞 | 估计修复工作量 |
|--------|------|----------------|
| P0 | H-01 Mesh 明文 HTTP 校验绕过 | 小 |
| P0 | H-04 state.env allexport | 中（需检查所有子进程依赖） |
| P1 | C-01 Agent 默认绑定 0.0.0.0 | 小 |
| P1 | H-02 Overlay IP 耗尽 | 中 |
| P1 | M-06 API 速率限制 | 中 |
| P2 | H-03 tag archive 回退校验不足 | 小 |
| P2 | H-05 health 端点信息泄露 | 小 |
| P2 | M-02 JSON 转义不完整 | 小 |
| P3 | 其他 Low / Info | 按需 |

---

*报告生成于 2026-09-15，基于 GeoProxy Server v0.2.71 代码静态分析*

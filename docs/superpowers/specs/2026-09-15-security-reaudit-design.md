# 安全全量重审与修复设计（方案 D）

> 日期：2026-09-15  
> 基线版本：v0.2.72  
> 审计深度：C（静态 + 既有验证脚本意图 + 高风险面动态路径走读）

## 目标

在 v0.2.72 已修 Critical/High 的基础上，重新全量审计；产出含**回归**与**新洞**的清单；按 P0→P2 修复；Info 仅记文档。

## 方法

1. 对照 `SECURITY_AUDIT.md` 逐项复核代码是否仍成立  
2. 分攻击面走读：Agent/Mesh API、凭证/argv、供应链、注入/校验  
3. 修复时 TDD（先失败用例再改）；不发版除非用户明确要求  

## 范围

| 纳入本轮修复 | 不纳入（仅文档） |
|--------------|------------------|
| 回归 + High/Medium 新洞 | I-01~I-05 架构建议 |
| 可落地 Low（logrotate/UMask、auth 限流生效、localhost.*、eval 去壳等） | 大规模改 ASGI / 每节点独立 token |

## Phase1 发现汇总

### P0 — 回归 / 高危残留

| ID | 严重度 | 摘要 | 证据 |
|----|--------|------|------|
| R-01 | High | C-01 部署层回归：`agent.env` 默认仍写 `0.0.0.0`，覆盖 Python `127.0.0.1`；`ALLOW_IPS` 不持久化 | `lib/systemd.sh:147-163`；`tests/test_agent_deploy.bats` 断言 `0.0.0.0` |
| N-01 | High | H-01 残留：`localhost.*` glob 仍可把 `localhost.attacker.com` 当 loopback | `lib/mesh/_common.sh:189` |

### P1 — Medium

| ID | 严重度 | 摘要 |
|----|--------|------|
| N-02 | Medium | `gps_agent_write_env_file` 整文件覆写丢失手工 `GPS_AGENT_ALLOW_IPS` |
| N-03 | Medium | webhook 无限速；GET 暴露 `configured` |
| N-04 | Medium | webhook 无重放/新鲜度防护 |
| N-07 | Medium | `upgrade self` 默认可回退 tag archive（与 install 的 opt-in 不对称） |
| N-08 | Medium | install 优先 git clone 无内容摘要 |
| N-09 | Medium | Kiwi `api_key` 经 `--data-urlencode` 进 curl argv（与注释矛盾） |
| N-10 | Medium | mesh Bearer 头 `mktemp` 前未 `umask 077` |
| M-06b | Medium | `_AUTH_FAIL_LIMIT.check()` 返回值被忽略，认证失败限流未生效 |
| M-01 | Medium | `is_ipv4` 与 `gps_validate_ipv4` 并存 |
| M-07 | Medium | README `curl\|bash` 供应链（文档侧缓解） |

### P2 — Low（可落地）

| ID | 摘要 |
|----|------|
| L-02 | logrotate/`UMask`：首建日志 0600、目录 0700 |
| L-01 | mkdir 锁写 PID + 死锁检测 |
| L-03 | UUID 校验收紧为 v4（可选，注意兼容） |
| L-06 | TUIC 默认 UUID≠PASSWORD |
| N-05/N-06 | status CPU sleep DoS；RateLimiter 桶无界 |
| N-11 | discovery `eval` 改为直接赋值；WG overlay 渲染前校验 |
| L-QR | QR mktemp 失败勿回退 argv；info 掩码 UUID |

### 已确认仍安全 / 报告过时

- H-03/H-04/H-05、M-03/M-04/M-05、M-02（`gps_json_escape` 已转义控制字符）代码侧仍成立  
- Agent 空 Token 拒启、compare_digest、body 上限、peers 原子写 600  

### Info（本轮不修）

I-01 共享 TOKEN · I-02 审计日志 · I-03 备份恢复 · I-04 降权 · I-05 外部依赖

## 修复原则

1. **先测后改**：每个 P0/P1 先补失败 BATS/静态断言  
2. **默认安全**：新装 agent bind=`127.0.0.1`；公网须显式 `change agent-bind`  
3. **凭证不进 argv**：Kiwi / Bearer 头文件一律 umask 077 + 文件传参  
4. **版本**：修复合入后按 AGENTS.md patch+1；**仅在用户要求时**提交/推送/打 tag  

## 成功标准

- 新审计清单中 P0/P1 全部关闭或降级并有测试  
- `bats --tap tests` 通过；shellcheck 无 error  
- `SECURITY_AUDIT.md` 更新为重审结论  

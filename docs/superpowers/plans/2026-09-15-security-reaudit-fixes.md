# 安全重审修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/superpowers/specs/2026-09-15-security-reaudit-design.md` 关闭 P0→P2 漏洞（本轮不发版）。

**Architecture:** TDD 分任务修复；Agent 默认绑定与 Mesh loopback 策略对齐「默认安全」；凭证经文件+umask 传递。

**Tech Stack:** Bash 4+ / Python 3 / BATS

## Global Constraints

- 版本号：本轮不改 VERSION（用户未要求发版）
- `bats --tap tests` 全通过；shellcheck 无 error
- 禁止占位密钥回退；禁止凭证进 argv
- 不 commit / push，除非用户明确要求

---

### Task 1: P0 R-01 — Agent 默认 bind 127.0.0.1 + 持久化 ALLOW_IPS

**Files:** `lib/systemd.sh`, `tests/test_agent_deploy.bats`, 相关默认文案

- [ ] 改测试：默认 env 断言 `127.0.0.1`；保留 ALLOW_IPS 读写
- [ ] `gps_agent_write_env_file` 默认 bind=`127.0.0.1`；读写 `GPS_AGENT_ALLOW_IPS`
- [ ] 跑 `tests/test_agent_deploy.bats`

### Task 2: P0 N-01 — 去掉 `localhost.*` glob

**Files:** `lib/mesh/_common.sh`, `tests/test_mesh_tls.bats`

- [ ] 测试：拒绝 `localhost.attacker.com`；接受精确 `localhost`
- [ ] 实现：仅 `localhost` / `::1` / `[::1]` / 严格 127/8
- [ ] 跑 `tests/test_mesh_tls.bats`

### Task 3: P1 — auth 限流生效 + webhook + 凭证卫生

- [ ] geoagent `_AUTH_FAIL_LIMIT` 失败时 429
- [ ] webhook 限速；GET 不暴露 configured；可选 delivery 去重
- [ ] Kiwi api_key 不进 argv；mesh curl header 文件 umask 077
- [ ] upgrade tag archive 需 opt-in（对齐 install）

### Task 4: P1 — M-01 / M-07 文档与 is_ipv4

- [ ] 统一严格 IPv4；README 提供先下载再校验安装命令

### Task 5: P2 — Low 可落地项

- [ ] logrotate/UMask、mkdir 锁 PID、去掉 discovery eval、WG overlay 校验、QR 无 argv 回退等

### Task 6: 文档与验证

- [ ] 更新 `SECURITY_AUDIT.md`
- [ ] 全量 bats + shellcheck

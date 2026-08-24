# 发布流程（版本号与 GitHub Releases 规则）

本文件是项目发布的**唯一规范**。所有发布必须遵循，规则与 [`AGENTS.md`](../AGENTS.md) 一致。

## 1. 版本号规则

版本号 `vX.Y.Z` 存放在仓库根 [`VERSION`](../VERSION)。

- **每次发布只 patch+1**：`v0.2.32 → v0.2.33`。
- 不因改动大小跳版本；破坏性变更只反映在 `CHANGELOG.md` 说明，不反映在版本位。
- 提升 minor/major 必须由维护者显式决定，否则一律 patch+1。

## 2. 发布前置检查（本地）

```bash
# 1) VERSION 已 patch+1，且与 CHANGELOG 最新标题一致
cat VERSION                                   # v0.2.33
head -3 CHANGELOG.md                          # ## v0.2.33 - 2026-08-24

# 2) 质量门槛
bats --tap tests                              # 全部通过
git ls-files '*.sh' | xargs shellcheck -x     # 无 error
shfmt -d .                                    # 无输出
```

## 3. 发布步骤（必须全部推送到 GitHub）

```bash
# 3.1 提交改动并推送
git add -A
git commit -m "chore(release): v0.2.33"
git push origin main

# 3.2 打 tag 并推送（tag 名必须 == VERSION 内容）
git tag v0.2.33
git push origin v0.2.33
```

## 4. GitHub 侧规则（CI 强制，不可绕过）

- `.github/workflows/release.yml` 在 tag 推送时执行：
  - 校验 `VERSION == GITHUB_REF_NAME`（tag），不一致 → 构建失败。
  - `git archive` 打包 `geoproxy-server-<tag>.tar.gz` 并生成 `.sha256`。
  - 自动创建 GitHub Release（资产 + 校验和）。
- **不要**手动 `gh release create` 或编辑 Release——一律由 CI 生成，保证资产与 tag 一致。
- Release 资产由 `install.sh` / `upgrade self` 下载并做 sha256 校验（GitHub API digest）。

## 5. 故障处理

| 现象 | 处理 |
|------|------|
| tag 与 VERSION 不一致导致 CI 失败 | 删除远端 tag（`git push origin :refs/tags/vX.Y.Z`），修正后重新 push |
| 忘记 push tag | 本地 `git tag` 未上远端即无效，必须 `git push origin vX.Y.Z` |
| 发布后发现问题 | 用下一个 patch 版本修复（vX.Y.(Z+1)），不覆盖已发布的 tag |

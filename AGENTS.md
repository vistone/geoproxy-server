# GeoProxy Server — 开发与发布规则书

本文件是项目对一切参与方（人类开发者、AI 代理）的强制规则。修改代码前必须阅读。

## 版本号规则（强制）

- 版本号严格为 **`vX.Y.Z`**（语义化版本三段式），存放在仓库根 `VERSION` 文件。
- 每次发布，版本号必须**只把最小版本位（patch，`Z`）+1**：

  ```
  v0.2.32 → v0.2.33 → v0.2.34 → …
  ```

- **禁止**随意跳版本（例如把 `v0.2.32` 直接改成 `v0.3.0` 或 `v1.0.0`）。
- 只有当用户**显式明确指示**提升 minor（`Y`）或 major（`X`）时，才允许越级；否则一律 patch+1。
- 即使改动包含破坏性变更（如 mesh 控制面默认启用 TLS），版本号仍只 patch+1，破坏性说明写入 `CHANGELOG.md` 与 `README.md`。
- `VERSION` 与 `CHANGELOG.md` 的最新标题必须一致（`## vX.Y.Z - YYYY-MM-DD`）。

## 发布规则（强制）

- **每次发布都必须实际提交并推送到 GitHub**，不允许只在本地改版本号。
- 发布步骤（严格按序）：
  1. `VERSION` 改为 patch+1 的新版本号。
  2. `CHANGELOG.md` 顶部追加 `## vX.Y.Z - YYYY-MM-DD` 一节，记录本次改动。
  3. 更新 `README.md` 中引用的版本号。
  4. 提交并推送：`git add -A && git commit && git push origin main`。
  5. 打 tag：`git tag vX.Y.Z && git push origin vX.Y.Z`。
- **严格遵循 GitHub 规则**：
  - tag 名必须与 `VERSION` 内容完全一致（`vX.Y.Z`），GitHub Actions `release.yml` 会强制校验 `VERSION == tag`，不一致则构建失败。
  - Release 由 GitHub Actions 自动创建（含 `geoproxy-server-<tag>.tar.gz` 与 `.sha256` 资产），**不要**手动创建 Release、不要绕过 CI。
  - 版本号引用一律使用仓库内 `VERSION` 与 GitHub Releases，README 不写死版本号。
- `VERSION` 未按上述规则修改（非 patch+1 / 与 CHANGELOG 不一致）时，任何发布操作应被拒绝。

## 代码质量门槛（强制）

- 全量测试必须通过：`bats --tap tests`（含新增用例），shellcheck 无 error、shfmt 无漂移。
- 新增/修改行为必须同步补充 `tests/*.bats` 用例；修 bug 先写失败用例再修复。
- 密钥/凭证相关代码：禁止占位密钥回退、禁止把凭证写进进程 argv。

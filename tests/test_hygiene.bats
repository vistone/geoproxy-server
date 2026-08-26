#!/usr/bin/env bats

# 仓库卫生：测试残留 / README 链接有效性 / 交互提示风格统一

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "bats run leaves tests/tmp free of tracked or dirty artifacts" {
	# 此前每个测试的 teardown 已清理 GPS_TEST_PREFIX；
	# tests/tmp 若仍有 tracked/修改内容说明有测试产物被提交或残留
	run git -C "$REPO_ROOT" status --porcelain -- tests/tmp
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "README markdown links resolve to repository files" {
	# 提取 README 中仓库相对链接（跳过 http/#/mailto）
	links=$(grep -oE '\]\([^)]+\)' "$REPO_ROOT/README.md" |
		sed -E 's/^\]\(//; s/\)$//' |
		grep -vE '^([a-z]+://|#|mailto:)' || true)
	[ -n "$links" ]
	while IFS= read -r l; do
		target="${REPO_ROOT}/${l}"
		[ -e "$target" ]
	done <<EOF
$links
EOF
}

@test "所有交互 read 提示统一以冒号结尾（等待输入风格）" {
	# 不再依赖 read -p（提示走 stderr、要求 stdin 为 TTY，部分终端/环境不显示导致空白等待）
	# 统一为显式 printf 提示 + read
	! grep -rnE 'read[[:space:]]+-r[[:space:]]+-p' "$REPO_ROOT/lib" || true
	# confirm_yes 必须用 printf 显式输出 "[y/N]: " 提示
	grep -qE 'printf .*\[y/N\]: ' "$REPO_ROOT/lib/common.sh"
	# 交互 read 前必须有提示输出（printf 或 msg），不得裸 read
	grep -rnE 'read[[:space:]]+-r[[:space:]]+[a-zA-Z_]+' "$REPO_ROOT/lib" | grep -v 'IFS=' | grep -v 'read -r u' | grep -v 'read -r line' | grep -v 'read -r l' | while IFS= read -r hit; do
		echo "裸 read 无提示: $hit" >&2
		exit 1
	done || true
}

#!/usr/bin/env bats

# 仓库卫生：测试残留 / README 链接有效性

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

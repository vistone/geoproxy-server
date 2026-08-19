#!/usr/bin/env bats

# 发布脚本：CHANGELOG → Release notes 提取

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "release notes are extracted from CHANGELOG for a tag" {
	run python3 "$REPO_ROOT/scripts/extract_release_notes.py" v0.2.17
	[ "$status" -eq 0 ]
	# v0.2.17 段落关键词（见 CHANGELOG.md）
	[[ "$output" == *"升级回滚"* ]]
	[[ "$output" != *"v0.2.18"* ]]
}

@test "release notes fall back to a stub for unknown tag" {
	run python3 "$REPO_ROOT/scripts/extract_release_notes.py" v0.0.0
	[ "$status" -eq 0 ]
	[[ "$output" == *"v0.0.0"* ]]
}

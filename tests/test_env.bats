#!/usr/bin/env bats

# Cloud Agent 开发环境（.cursor/）卫生：
# install 脚本固定的工具版本 / sha256 必须与 CI（同一信任模型）保持一致，防漂移。

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	ENV_JSON="$REPO_ROOT/.cursor/environment.json"
	ENV_INSTALL="$REPO_ROOT/.cursor/install.sh"
	CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
}

@test ".cursor/environment.json is valid JSON and installs via .cursor/install.sh" {
	[ -f "$ENV_JSON" ]
	run python3 -m json.tool "$ENV_JSON"
	[ "$status" -eq 0 ]
	run python3 -c "import json,sys;d=json.load(open('$ENV_JSON'));print(d['install'])"
	[ "$status" -eq 0 ]
	[[ "$output" == *".cursor/install.sh"* ]]
}

@test ".cursor/install.sh is present and executable" {
	[ -f "$ENV_INSTALL" ]
	[ -x "$ENV_INSTALL" ]
}

@test "install script tool versions match CI" {
	for ver in v3.13.1 v0.11.0 v1.14.0; do
		grep -q -- "$ver" "$ENV_INSTALL"
		grep -q -- "$ver" "$CI_YML"
	done
}

@test "install script binary sha256 match CI (same trust model)" {
	local shfmt_sha=fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1
	local sc_sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
	for sha in "$shfmt_sha" "$sc_sha"; do
		grep -qi -- "$sha" "$ENV_INSTALL"
		grep -qi -- "$sha" "$CI_YML"
	done
}

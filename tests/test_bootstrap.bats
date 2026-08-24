#!/usr/bin/env bats
# install.sh 引导路径：tag 校验、release asset 摘要校验、未校验回退需显式 opt-in

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../install.sh
	source "$REPO_ROOT/install.sh"
	# 摘要 fixture 均按 v9.9.9 资产名构造
	GPS_VERSION=v9.9.9
}

@test "valid tag charset enforced" {
	_gps_valid_tag v1.2.3
	_gps_valid_tag v0.2.32-rc.1
	run _gps_valid_tag "../evil"
	[ "$status" -ne 0 ]
	run _gps_valid_tag "v1/../../etc"
	[ "$status" -ne 0 ]
	run _gps_valid_tag ""
	[ "$status" -ne 0 ]
}

@test "asset digest parsed from GitHub API response" {
	curl() {
		printf '{"assets":[{"name":"geoproxy-server-v9.9.9.tar.gz","digest":"sha256:%s"}]}' "abc123"
	}
	run _gps_asset_digest v9.9.9 geoproxy-server-v9.9.9.tar.gz
	[ "$status" -eq 0 ]
	[ "$output" = "abc123" ]
}

@test "fetch repo verifies release asset digest before extract" {
	mkdir -p "$BATS_TEST_TMPDIR/pkgtree"
	touch "$BATS_TEST_TMPDIR/pkgtree/geoproxy-server.sh"
	tar -czf "$BATS_TEST_TMPDIR/pkg.tar.gz" -C "$BATS_TEST_TMPDIR/pkgtree" .
	local sha
	sha=$(sha256sum "$BATS_TEST_TMPDIR/pkg.tar.gz" | awk '{print $1}')
	git() { return 1; }
	curl() {
		local out="" url="" prev="" a=""
		for a in "$@"; do
			if [[ $prev == -o ]]; then
				out=$a
			fi
			case $a in
			http*) url=$a ;;
			esac
			prev=$a
		done
		if [[ $url == *api.github.com* ]]; then
			printf '{"assets":[{"name":"geoproxy-server-v9.9.9.tar.gz","digest":"sha256:%s"}]}' "$SHA_VALUE"
			return 0
		fi
		[[ -n $out ]] || return 1
		cp "$BATS_TEST_TMPDIR/pkg.tar.gz" "$out"
	}
	SHA_VALUE=$sha
	run _gps_fetch_repo "$BATS_TEST_TMPDIR/dest-ok"
	[ "$status" -eq 0 ]
	# run 合并了 stderr，最后一行才是脚本树根（stdout 数据通道）
	local root
	root=${lines[${#lines[@]} - 1]}
	[ -f "$root/geoproxy-server.sh" ]

	# 摘要不匹配 → 拒绝解压执行
	SHA_VALUE=0000000000000000000000000000000000000000000000000000000000000000
	run _gps_fetch_repo "$BATS_TEST_TMPDIR/dest-bad"
	[ "$status" -ne 0 ]
	[[ "$output" == *"sha256 校验失败"* ]]
}

@test "unverified tag archive fallback requires explicit opt-in" {
	git() { return 1; }
	curl() { return 22; }
	# 默认：无 asset 可用时直接失败，并提示显式开关
	GPS_INSTALL_ALLOW_UNVERIFIED=0
	run _gps_fetch_repo "$BATS_TEST_TMPDIR/dest-nover"
	[ "$status" -ne 0 ]
	[[ "$output" == *"GPS_INSTALL_ALLOW_UNVERIFIED=1"* ]]
}

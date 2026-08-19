#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/download.sh
	source "$REPO_ROOT/lib/download.sh"
}

@test "archive verification rejects checksum mismatch" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	printf '%064d  sing-box-test-linux-amd64.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -ne 0 ]
}

@test "archive verification accepts exact checksum" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	sum=$(sha256sum "$BATS_TEST_TMPDIR/sb.tar.gz" | awk '{print $1}')
	printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum" >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -eq 0 ]
}

@test "archive verification rejects missing manifest entry" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	printf '%064d  other-asset.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -ne 0 ]
}

@test "archive verification rejects duplicate manifest entries" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	sum=$(sha256sum "$BATS_TEST_TMPDIR/sb.tar.gz" | awk '{print $1}')
	{
		printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum"
		printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum"
	} >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -ne 0 ]
}

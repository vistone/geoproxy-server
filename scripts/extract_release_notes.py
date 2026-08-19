#!/usr/bin/env python3
"""从 CHANGELOG.md 提取指定 tag 的段落作为 GitHub Release notes。

用法: extract_release_notes.py <tag> [changelog 路径]
段落格式: "## <tag> - <date>" 到下一个 "## " 之间。
"""
import re
import sys


def extract(text: str, tag: str) -> str:
    m = re.search(
        rf"^## {re.escape(tag)} - [^\n]*\n(.*?)(?=^## |\Z)",
        text,
        re.M | re.S,
    )
    return m.group(1).strip() if m else f"{tag} release"


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: extract_release_notes.py <tag> [changelog]", file=sys.stderr)
        sys.exit(2)
    tag = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) > 2 else "CHANGELOG.md"
    with open(path, encoding="utf-8") as f:
        print(extract(f.read(), tag))


if __name__ == "__main__":
    main()

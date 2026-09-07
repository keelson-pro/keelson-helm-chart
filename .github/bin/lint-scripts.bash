#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# The preTaggingTests hook: shellcheck the chart scripts before a tag is cut.
# Nothing version-aware belongs here; it runs before $VERSION exists.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck not found on PATH (brew install shellcheck / apt install shellcheck)\n' >&2
    exit 1
fi

shopt -s nullglob
SCRIPTS=(.github/bin/*.bash)
if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    printf 'no .bash scripts found under .github/bin\n' >&2
    exit 1
fi

printf '== shellcheck (%s scripts) ==\n' "${#SCRIPTS[@]}"
# SC2016 excluded: the sed and awk programs rewrite literal ${Token} text, so
# single quotes are the point.
shellcheck --shell=bash --exclude=SC2016 "${SCRIPTS[@]}"
printf 'All scripts pass.\n'

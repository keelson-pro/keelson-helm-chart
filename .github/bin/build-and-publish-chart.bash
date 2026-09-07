#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# The postVersionsAndNaming hook, and the only chart-side entry. Each phase below
# is separately runnable and documents itself.
#
# The publish phases run their whole path every build and gate only the push, so
# a PR exercises everything a release does bar the publish.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for phase in \
    regenerate-chart \
    package-chart \
    write-release-notes \
    publish-chart-index \
    publish-chart-oci
do
    printf '\n== chart hook: %s ==\n' "${phase}"
    "${SCRIPT_DIR}/${phase}.bash"
done

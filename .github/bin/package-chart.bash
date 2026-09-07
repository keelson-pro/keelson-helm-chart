#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# Phase 2, via build-and-publish-chart.bash.
#
# helm package, leaving the artefact for the OCI push and an unversioned copy for
# the release attach, where KaptainPM re-adds the version index.yaml points at.

set -euo pipefail

: "${VERSION:?VERSION is required (set by the versions-and-naming build step)}"

# Defaulted only so a direct call lands somewhere sane; real builds always set it.
OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CHART_DIR="charts/keelson"
HELM_BUILD_DIR="${OUTPUT_SUB_PATH%/}/helm-build"

if ! command -v helm >/dev/null 2>&1; then
    printf 'helm not found on PATH - required for package\n' >&2
    exit 1
fi

# Chart.yaml was stamped with $VERSION, so asserting the filename below also
# checks the regen phase ran at this version.
TGZ_NAME="keelson-${VERSION}.tgz"

# Kept: the artefact to inspect when a build goes wrong, and what the OCI push sends.
PACKAGE_OUT="${HELM_BUILD_DIR}/package"
rm -rf "${PACKAGE_OUT}"
mkdir -p "${PACKAGE_OUT}"

printf '== helm package ==\n'
helm package "${CHART_DIR}" --destination "${PACKAGE_OUT}"

TGZ_PATH="${PACKAGE_OUT}/${TGZ_NAME}"
if [[ ! -f "${TGZ_PATH}" ]]; then
    printf 'helm package did not produce expected .tgz at %s\n' "${TGZ_PATH}" >&2
    exit 1
fi
printf 'Packaged %s\n' "${TGZ_NAME}"

RELEASE_DIR="${OUTPUT_SUB_PATH%/}/chart-release"
mkdir -p "${RELEASE_DIR}"
cp "${TGZ_PATH}" "${RELEASE_DIR}/keelson.tgz"
printf 'Staged %s/keelson.tgz for the release attach\n' "${RELEASE_DIR}"

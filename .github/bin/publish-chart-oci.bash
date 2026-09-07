#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# Phase 5, via build-and-publish-chart.bash.
#
# Publishes the chart as a Helm OCI artefact, the reference the release notes name.
#
# helm push appends <chart-name>:<chart-version>, so only the parent path is ours.
# It follows Kaptain's image ref layout plus a helm-charts segment, with prefix and
# project both present so the artefact traces back to the repo that built it:
#
#   ghcr.io/keelson-pro/helm-charts/keelson/keelson-helm-chart/keelson:1.23.0
#           |__ns_____| |_literal_| |prefix| |__project______| |chart| |version|
#
# Runs every build; only the push is gated.

set -euo pipefail

: "${VERSION:?VERSION is required (set by the versions-and-naming build step)}"
: "${PROJECT_NAME:?PROJECT_NAME is required (set by the build)}"
: "${DOCKER_TARGET_REGISTRY:?DOCKER_TARGET_REGISTRY is required (set by the build)}"

OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"
BUILD_MODE="${BUILD_MODE:-local}"
IS_RELEASE="${IS_RELEASE:-false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v helm >/dev/null 2>&1; then
    printf 'helm not found on PATH - required for chart push\n' >&2
    exit 1
fi

CHART_TGZ="${OUTPUT_SUB_PATH%/}/helm-build/package/keelson-${VERSION}.tgz"
if [[ ! -f "${CHART_TGZ}" ]]; then
    printf 'Packaged chart not found at %s\n' "${CHART_TGZ}" >&2
    printf 'package-chart.bash should run before this script.\n' >&2
    exit 1
fi

# Same prefix rule as Kaptain image refs: the segment before the first hyphen.
CHART_PREFIX="${PROJECT_NAME%%-*}"
CHART_REMOTE="oci://${DOCKER_TARGET_REGISTRY}/${DOCKER_TARGET_NAMESPACE:+${DOCKER_TARGET_NAMESPACE}/}helm-charts/${CHART_PREFIX}/${PROJECT_NAME}"

PUBLISH=false
if [[ "${IS_RELEASE}" == "true" && "${BUILD_MODE}" == "build_server" ]]; then
    PUBLISH=true
fi

printf '== publish chart to OCI ==\n'
printf '  chart:  %s\n' "${CHART_TGZ}"
printf '  remote: %s\n' "${CHART_REMOTE}"
printf '  result: %s/keelson:%s\n' "${CHART_REMOTE#oci://}" "${VERSION}"

if [[ "${PUBLISH}" != "true" ]]; then
    printf 'IS_RELEASE=%s BUILD_MODE=%s - not pushing.\n' "${IS_RELEASE}" "${BUILD_MODE}"
    exit 0
fi

# helm reads its own registry config, so a docker login does not authenticate this.
GH_AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${GH_AUTH_TOKEN}" ]]; then
    printf 'GH_TOKEN or GITHUB_TOKEN is required to push the chart.\n' >&2
    exit 1
fi
printf '%s' "${GH_AUTH_TOKEN}" \
    | helm registry login "${DOCKER_TARGET_REGISTRY}" --username x-access-token --password-stdin

helm push "${CHART_TGZ}" "${CHART_REMOTE}"
printf 'Pushed chart %s.\n' "${VERSION}"

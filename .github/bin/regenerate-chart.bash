#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Keelson contributors (Fred Cooke)
#
# Phase 1, via build-and-publish-chart.bash.
#
# Rebuilds charts/ from the <pin>-manifests OCI images and fails if the result
# differs from what git has. All of charts/ is generated; edit src/chart/.

set -euo pipefail

: "${BUILD_SCRIPTS_REPO_ROOT:?BUILD_SCRIPTS_REPO_ROOT is required (set by the build)}"
: "${VERSION:?VERSION is required (set by the versions-and-naming build step)}"

# Defaulted only so a direct call lands somewhere sane; real builds always set it.
OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-kaptain-out}"
if [[ ! -d "${BUILD_SCRIPTS_REPO_ROOT}/src/scripts" ]]; then
    printf 'BUILD_SCRIPTS_REPO_ROOT does not contain src/scripts: %s\n' "${BUILD_SCRIPTS_REPO_ROOT}" >&2
    exit 1
fi

BUILD_MODE="${BUILD_MODE:-local}"
case "${BUILD_MODE}" in
    local|build_server) ;;
    *) printf 'BUILD_MODE must be local or build_server, got: %s\n' "${BUILD_MODE}" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CHARTS_ROOT="charts"
CHART_DIR="${CHARTS_ROOT}/keelson"
TEMPLATES_DIR="${CHART_DIR}/templates"
CHART_SRC_DIR="src/chart"
VERBATIM_DIR="${CHART_SRC_DIR}/verbatim"
VALUES_HEADER="${CHART_SRC_DIR}/values-header.yaml"
CHART_README="${CHART_SRC_DIR}/README.md"
VALUES_DEFAULTS_MARKER="# @KEELSON_DEFAULTS@"
CHART_METADATA="${CHART_SRC_DIR}/metadata.yaml"
UPSTREAM_PINS_DIR="src/upstream"
ARGO_PROJECT="keelson-argo-rollouts-rbac"
FOREIGN_PROJECT="keelson-foreign-ns-rbac"

# Not values: image.* splits the first, keelson.namespaces derives the second.
VALUES_OMITTED_DEFAULTS=(EnvironmentDockerRegistryAndNamespace Scope)

# A literal because bash keeps the backslashes if the doubling is written inline.
SINGLE_QUOTE="'"

for tool in helm unzip; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        printf '%s not found on PATH\n' "${tool}" >&2
        exit 1
    fi
done

read_version_pin() {
    local pin_file="$1"
    local pin
    pin=$(grep -E '^[0-9]+\.[0-9]+$' "${pin_file}" || true)
    if [[ -z "${pin}" ]]; then
        printf 'Could not resolve a MAJOR.MINOR pin from %s\n' "${pin_file}" >&2
        exit 1
    fi
    printf '%s' "${pin}"
}

KEELSON_PIN=$(read_version_pin "${UPSTREAM_PINS_DIR}/KeelsonVersion")
ARGO_PIN=$(read_version_pin "${UPSTREAM_PINS_DIR}/KeelsonArgoRolloutsRbacVersion")
FOREIGN_PIN=$(read_version_pin "${UPSTREAM_PINS_DIR}/KeelsonForeignNsRbacVersion")

# Kaptain appends the patch to the KeelsonVersion prefix, so this is the build's.
CHART_VERSION="${VERSION}"
if [[ ! "${CHART_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION is not a 3-part numeric version: %s\n' "${CHART_VERSION}" >&2
    exit 1
fi
if [[ "${CHART_VERSION}" != "${KEELSON_PIN}."* ]]; then
    printf 'VERSION (%s) does not extend the KeelsonVersion pin (%s) - KaptainPM.yaml and KeelsonVersion have diverged.\n' \
        "${CHART_VERSION}" "${KEELSON_PIN}" >&2
    exit 1
fi

printf 'Regenerating chart %s from keelson %s, %s %s, %s %s (BUILD_MODE=%s)\n' \
    "${CHART_VERSION}" "${KEELSON_PIN}" "${ARGO_PROJECT}" "${ARGO_PIN}" \
    "${FOREIGN_PROJECT}" "${FOREIGN_PIN}" "${BUILD_MODE}"

# Relative because convert-tokens-in-tree rejects absolute. Cleared up front,
# never after, so a failed run stays inspectable.
HELM_BUILD_DIR="${OUTPUT_SUB_PATH%/}/helm-build"
WORKDIR="${HELM_BUILD_DIR}/chart-regen"
KEELSON_SOURCE="${WORKDIR}/keelson-source"
ARGO_SOURCE="${WORKDIR}/${ARGO_PROJECT}-source"
FOREIGN_SOURCE="${WORKDIR}/${FOREIGN_PROJECT}-source"
rm -rf "${WORKDIR}"
mkdir -p "${KEELSON_SOURCE}" "${ARGO_SOURCE}" "${FOREIGN_SOURCE}"

# Unpacks to $target/manifests/<project>/ and $target/contract/, the layout all
# three projects publish.
pull_project_source() {
    local project="$1"
    local pin="$2"
    local target="$3"
    local image="ghcr.io/keelson-pro/keelson/${project}:${pin}-manifests"
    local extract="${BUILD_SCRIPTS_REPO_ROOT}/src/scripts/util/extract-oci-image"

    if [[ ! -x "${extract}" ]]; then
        printf 'extract-oci-image not found or not executable at %s\n' "${extract}" >&2
        exit 1
    fi
    if [[ -z "${IMAGE_BUILD_COMMAND:-}" ]]; then
        printf 'IMAGE_BUILD_COMMAND is required (docker or podman) - set by the build.\n' >&2
        exit 1
    fi

    mkdir -p "${target}"
    printf 'Extracting %s from %s\n' "${project}" "${image}"
    "${extract}" "${image}" "${target}" \
        "/${project}-${pin}-manifests.zip" \
        "/${project}-${pin}-contract.zip"

    local manifests_zip="${target}/${project}-${pin}-manifests.zip"
    local contract_zip="${target}/${project}-${pin}-contract.zip"
    for zip in "${manifests_zip}" "${contract_zip}"; do
        if [[ ! -f "${zip}" ]]; then
            printf 'Expected zip not extracted from image: %s\n' "${zip}" >&2
            exit 1
        fi
    done

    unzip -q -o "${manifests_zip}" -d "${target}/manifests"
    unzip -q -o "${contract_zip}"  -d "${target}/contract"
}

pull_project_source keelson "${KEELSON_PIN}" "${KEELSON_SOURCE}"
pull_project_source "${ARGO_PROJECT}" "${ARGO_PIN}" "${ARGO_SOURCE}"
pull_project_source "${FOREIGN_PROJECT}" "${FOREIGN_PIN}" "${FOREIGN_SOURCE}"

KEELSON_UNPACKED="${KEELSON_SOURCE}/manifests"
KEELSON_MANIFESTS="${KEELSON_UNPACKED}/keelson"
KEELSON_DEFAULTS="${KEELSON_SOURCE}/contract/defaults"
ARGO_UNPACKED="${ARGO_SOURCE}/manifests"
ARGO_MANIFESTS="${ARGO_UNPACKED}/${ARGO_PROJECT}"
FOREIGN_UNPACKED="${FOREIGN_SOURCE}/manifests"
FOREIGN_MANIFESTS="${FOREIGN_UNPACKED}/${FOREIGN_PROJECT}"

# Generic, so a new keelson setting needs nothing here. The sed turns the group
# separator the converter keeps, .Values.keelson/logFormat, into the dot Helm
# needs; any group, since the add-ons carry their own.
convert_tokens_to_helm() {
    local unpacked_dir="$1"
    printf '\n== convert-tokens-in-tree: %s ==\n' "${unpacked_dir}"
    "${BUILD_SCRIPTS_REPO_ROOT}/src/scripts/util/convert-tokens-in-tree" \
        shell PascalCase helm camelCase "${unpacked_dir}"

    local file
    while IFS= read -r -d '' file; do
        sed -i.bak -E 's|(\.Values\.[A-Za-z0-9]+)/|\1.|g' "${file}"
        rm -f "${file}.bak"
    done < <(find "${unpacked_dir}" -type f -print0)

    if grep -rn '\${' "${unpacked_dir}" >&2; then
        printf 'Unconverted kaptain tokens remain (above).\n' >&2
        exit 1
    fi
    if grep -rn '\.Values\.[A-Za-z0-9_.]*/' "${unpacked_dir}" >&2; then
        printf 'Helm value paths still contain a group separator (above).\n' >&2
        exit 1
    fi
}

convert_tokens_to_helm "${KEELSON_UNPACKED}"
convert_tokens_to_helm "${ARGO_UNPACKED}"
convert_tokens_to_helm "${FOREIGN_UNPACKED}"

# Kaptain renames the ConfigMap on a config change to force a rollout;
# add_checksum_annotation does that here instead, so the suffix is dead weight.
#
# ([^a-z0-9-]|$) is a portable word boundary: GNU's \> no-ops on BSD sed.
strip_kaptain_checksum_names() {
    local unpacked_dir="$1"
    local file
    while IFS= read -r -d '' file; do
        sed -i.bak -E 's#-[a-z]+-checksum([^a-z0-9-]|$)#\1#g' "${file}"
        rm -f "${file}.bak"
    done < <(find "${unpacked_dir}" -type f -print0)

    if grep -rn -- '-checksum' "${unpacked_dir}" >&2; then
        printf 'Kaptain checksum naming survived the strip (above).\n' >&2
        exit 1
    fi
}

strip_kaptain_checksum_names "${KEELSON_UNPACKED}"
strip_kaptain_checksum_names "${ARGO_UNPACKED}"
strip_kaptain_checksum_names "${FOREIGN_UNPACKED}"

# The full set each project publishes, so a manifest added upstream fails the build
# instead of being dropped. Defaults need no list: they are enumerated.
KEELSON_EXPECTED_MANIFESTS=(
    clusterrole clusterrolebinding
    clusterrole-all-ns clusterrolebinding-all-ns
    role rolebinding
    role-own-ns rolebinding-own-ns
    configmap deployment serviceaccount
)
ARGO_EXPECTED_MANIFESTS=(clusterrole clusterrolebinding role rolebinding)
FOREIGN_EXPECTED_MANIFESTS=(role rolebinding)

# kaptain-bundle-lineage-data.yaml is bookkeeping, not a manifest, so it is skipped.
check_manifest_set() {
    local manifests_dir="$1"
    shift
    local expected=("$@")
    local name candidate known

    for name in "${expected[@]}"; do
        if [[ ! -f "${manifests_dir}/${name}.yaml" ]]; then
            printf 'Pulled source missing expected manifest: %s/%s.yaml\n' "${manifests_dir}" "${name}" >&2
            exit 1
        fi
    done

    while IFS= read -r -d '' manifest; do
        name="$(basename "${manifest}" .yaml)"
        if [[ "${name}" == "kaptain-bundle-lineage-data" ]]; then
            continue
        fi
        known=0
        for candidate in "${expected[@]}"; do
            if [[ "${candidate}" == "${name}" ]]; then
                known=1
            fi
        done
        if [[ "${known}" -eq 0 ]]; then
            printf 'Upstream ships %s, which this chart does not handle.\n' "${manifest}" >&2
            printf 'Transform it and add it to the expected set, or skip it deliberately.\n' >&2
            exit 1
        fi
    done < <(find "${manifests_dir}" -maxdepth 1 -name '*.yaml' -print0 | LC_ALL=C sort -z)
}

check_manifest_set "${KEELSON_MANIFESTS}" "${KEELSON_EXPECTED_MANIFESTS[@]}"
check_manifest_set "${ARGO_MANIFESTS}"    "${ARGO_EXPECTED_MANIFESTS[@]}"
check_manifest_set "${FOREIGN_MANIFESTS}" "${FOREIGN_EXPECTED_MANIFESTS[@]}"

if [[ ! -d "${KEELSON_DEFAULTS}/Keelson" ]]; then
    printf 'Pulled source missing expected path: %s/Keelson\n' "${KEELSON_DEFAULTS}" >&2
    exit 1
fi

# --- Template transforms -----------------------------------------------------

# Rebuilds each metadata labels and annotations block from an allow-list: the
# provenance keys upstream sets, plus keelson.labels at the top of a labels one.
#
# Keyed on the block, not a line in it, so nothing depends on ordering and a
# label added upstream is dropped instead of leaking through. A missing kept key
# fails the build. matchLabels is not a labels block.
collapse_labels_and_annotations() {
    awk '
        BEGIN {
            keep["labels"] = "kaptain.org/project-name kaptain.org/version kaptain.org/owner"
            keep["annotations"] = "kaptain.org/source-repository"
            kind = ""
        }

        function emit_block(   wanted, count, i, key) {
            if (kind == "labels") {
                printf "%*s{{- include \"keelson.labels\" . | nindent %d }}\n", body_indent, "", body_indent
            }
            count = split(keep[kind], wanted, " ")
            for (i = 1; i <= count; i++) {
                key = wanted[i]
                if (key in found) {
                    printf "%*s%s: %s\n", body_indent, "", key, found[key]
                } else {
                    printf "%s:%d: %s block has no %s\n", FILENAME, header_line, kind, key > "/dev/stderr"
                    failed = 1
                }
            }
            delete found
            kind = ""
        }

        kind != "" {
            match($0, /^[[:space:]]*/)
            if (RLENGTH > header_indent && $0 !~ /^[[:space:]]*$/) {
                if (body_indent == 0) body_indent = RLENGTH
                entry = $0
                sub(/^[[:space:]]+/, "", entry)
                colon = index(entry, ": ")
                if (colon > 0) found[substr(entry, 1, colon - 1)] = substr(entry, colon + 2)
                next
            }
            emit_block()
        }

        /^[[:space:]]*(labels|annotations):[[:space:]]*$/ {
            match($0, /^[[:space:]]*/)
            header_indent = RLENGTH
            header_line = NR
            kind = ($0 ~ /labels:/) ? "labels" : "annotations"
            body_indent = 0
            print
            next
        }

        { print }

        END {
            if (kind != "") emit_block()
            if (failed) exit 1
        }
    ' "$1"
}

# Every name keelson gives its own objects, so they all move together under
# nameOverride and fullnameOverride. Indent is what distinguishes the fields:
#   2  metadata.name and roleRef.name    4  subjects[].name    6  serviceAccountName
#
# The container's 8-space "- name: keelson" is left alone, as are command args
# and mount paths, which is why "keelson" is not replaced everywhere. The rule
# stops at -own-ns and -all-ns so add-on names keep their own project suffix.
# # delimits because | is the alternation.
apply_namespaced_names() {
    sed -E '
        s#^  name: keelson(-(own|all)-ns)?$#  name: {{ include "keelson.fullname" . }}\1#
        s#^    name: keelson(-(own|all)-ns)?$#    name: {{ include "keelson.fullname" . }}\1#
        s#^  name: \{\{ \.Values\.environment \}\}\.keelson(-all-ns)?$#  name: {{ .Release.Namespace }}.{{ include "keelson.fullname" . }}\1#
        s#^      serviceAccountName: keelson$#      serviceAccountName: {{ include "keelson.fullname" . }}#
        s#\{\{ \.Values\.environment \}\}#{{ .Release.Namespace }}#g
    '
}

# Neither target is a chart value, so the token converter cannot reach them.
#
# The image is matched by name, not by being an image: line, so a sidecar keeps
# its own. The configMap name is found by tracking the block rather than the line
# after it: the volume is optional, so a missed rewrite mounts nothing in silence.
apply_deployment_fixups() {
    sed -E 's#^([[:space:]]+image:[[:space:]]+).*/keelson-package:.*$#\1{{ include "keelson.image" . }}#' \
        | awk '
        BEGIN { block_indent = -1 }

        /^[[:space:]]*$/ { print; next }

        {
            match($0, /^[[:space:]]*/)
            indent = RLENGTH
            if (indent <= block_indent) block_indent = -1

            if (block_indent >= 0 && $0 ~ /^[[:space:]]+name: keelson$/) {
                printf "%*sname: {{ include \"keelson.fullname\" . }}\n", indent, ""
                next
            }

            if ($0 ~ /^[[:space:]]*configMap:[[:space:]]*$/) block_indent = indent

            print
        }
    '
}

# Rolls the pods on a ConfigMap change, replacing what the checksum strip removed.
add_checksum_annotation() {
    awk '
        BEGIN { template_seen = 0; meta_seen = 0; injected = 0 }
        !template_seen && /^[[:space:]]+template:[[:space:]]*$/ { template_seen = 1 }
        template_seen && !meta_seen && /^[[:space:]]+metadata:[[:space:]]*$/ { meta_seen = 1 }
        meta_seen && !injected && /^[[:space:]]+annotations:[[:space:]]*$/ {
            match($0, /^[[:space:]]*/)
            ann_indent = RLENGTH + 2
            print
            printf "%*schecksum/config: {{ include (print $.Template.BasePath \"/configmap.yaml\") . | sha256sum }}\n", ann_indent, ""
            injected = 1
            next
        }
        { print }

        # Costs nothing today, since keelson re-reads registries.yaml every scan,
        # and everything the day something in there is read once at boot.
        END {
            if (!injected) {
                printf "No annotations block in the pod template to hang checksum/config on.\n" > "/dev/stderr"
                exit 1
            }
        }
    ' "$1"
}

# Upstream's single hard-coded entry becomes .Values.registries verbatim, so hosts
# and per-host fields need nothing from this script.
rewrite_configmap_registries() {
    sed -E '
        s|^      \{\{ \.Values\.keelson\.environmentDockerRegistry \}\}:[[:space:]]*$|      {{- include "keelson.registries" . \| nindent 6 }}|
        /^        auth-mode: \{\{ \.Values\.keelson\.authMode \}\}[[:space:]]*$/d
    '
}

# A CPU limit when forceCpuLimit is set, for policy engines that demand one.
# Anchored on the end of the limits block so a new limit upstream cannot displace it.
inject_forced_cpu_limit() {
    awk '
        function close_limits() {
            printf "{{- if .Values.forceCpuLimit }}\n"
            printf "%*scpu: \"{{ .Values.forceCpuLimit }}\"\n", limits_indent + 2, ""
            printf "{{- end }}\n"
            limits_indent = -1
        }

        BEGIN { limits_indent = -1 }

        limits_indent >= 0 {
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= limits_indent) close_limits()
        }

        /^[[:space:]]+limits:[[:space:]]*$/ && resources_seen {
            match($0, /^[[:space:]]*/)
            limits_indent = RLENGTH
            resources_seen = 0
            print
            next
        }

        /^[[:space:]]+resources:[[:space:]]*$/ { resources_seen = 1 }

        { print }

        END { if (limits_indent >= 0) close_limits() }
    '
}

# Scope comes from keelson.namespaces alone, so two values cannot contradict
# each other. Anchored on the value lines, which name the setting they carry.
derive_env_lists() {
    sed -E '
        s|^([[:space:]]+value: )"\{\{ \.Values\.keelson\.scope \}\}"$|\1{{ if .Values.keelson.namespaces }}"namespace"{{ else }}"cluster"{{ end }}|
        s|^([[:space:]]+value: )"\{\{ \.Values\.keelson\.namespaces \}\}"$|\1{{ join " " .Values.keelson.namespaces \| quote }}|
        s|^([[:space:]]+value: )"\{\{ \.Values\.keelson\.watchedKinds \}\}"$|\1{{ join " " .Values.keelson.watchedKinds \| quote }}|
    '
}

# Fires once: the collapse leaves 6-space unique to selector.matchLabels.
rewrite_deployment_selector() {
    sed -E '
        s|^      app\.kubernetes\.io/name: keelson$|      {{- include "keelson.selectorLabels" . \| nindent 6 }}|
    '
}

transform_namespaced() {
    collapse_labels_and_annotations "$1" | apply_namespaced_names > "$2"
}

# Cloud identity binds to the ServiceAccount, so both maps have to be extensible.
transform_serviceaccount() {
    collapse_labels_and_annotations "$1" \
        | apply_namespaced_names \
        | sed -E \
            -e 's#^(    \{\{- include "keelson\.labels" \. [|] nindent 4 \}\})$#\1\n    {{- with .Values.serviceAccount.labels }}\n    {{- include "keelson.assertUnreserved" (dict "ctx" $ "user" . "kind" "labels" "field" "serviceAccount.labels") }}\n    {{- toYaml . | nindent 4 }}\n    {{- end }}#' \
            -e 's#^(    kaptain\.org/source-repository: .*)$#\1\n    {{- with .Values.serviceAccount.annotations }}\n    {{- include "keelson.assertUnreserved" (dict "ctx" $ "user" . "kind" "annotations" "field" "serviceAccount.annotations") }}\n    {{- toYaml . | nindent 4 }}\n    {{- end }}#' \
        > "$2"
}

# Pod-level passthroughs upstream has no notion of, anchored on the pod template
# includes and on volumes:, the last block of the spec.
#
# [|] not \| for the literal pipe: BSD sed ignores \| in a pattern and matches
# nothing, so the injection would vanish on a Mac.
apply_pod_passthroughs() {
    sed -E \
        -e 's#^(        \{\{- include "keelson\.labels" \. [|] nindent 8 \}\})$#\1\n        {{- with .Values.podLabels }}\n        {{- include "keelson.assertUnreserved" (dict "ctx" $ "user" . "kind" "labels" "field" "podLabels") }}\n        {{- toYaml . | nindent 8 }}\n        {{- end }}#' \
        -e 's#^(        kaptain\.org/source-repository: .*)$#\1\n        {{- with .Values.podAnnotations }}\n        {{- include "keelson.assertUnreserved" (dict "ctx" $ "user" . "kind" "annotations" "field" "podAnnotations") }}\n        {{- toYaml . | nindent 8 }}\n        {{- end }}#' \
        -e 's|^(      serviceAccountName: .*)$|\1\n      {{- with .Values.imagePullSecrets }}\n      imagePullSecrets:\n        {{- toYaml . \| nindent 8 }}\n      {{- end }}|' \
        -e 's|^      volumes:$|      {{- with .Values.nodeSelector }}\n      nodeSelector:\n        {{- toYaml . \| nindent 8 }}\n      {{- end }}\n      {{- with .Values.tolerations }}\n      tolerations:\n        {{- toYaml . \| nindent 8 }}\n      {{- end }}\n      {{- with .Values.affinity }}\n      affinity:\n        {{- toYaml . \| nindent 8 }}\n      {{- end }}\n      {{- with .Values.priorityClassName }}\n      priorityClassName: {{ . }}\n      {{- end }}\n      volumes:|'
}

# An add-on name starts with keelson because it serves a keelson install, so that
# part takes the helper and the project suffix stays. Default naming is unchanged.
apply_addon_names() {
    local suffix="${1#keelson}"
    sed -E "s#^(( {2}| {4})name: (\{\{ \.Release\.Namespace \}\}\.)?)keelson${suffix}\$#\1{{ include \"keelson.fullname\" . }}${suffix}#"
}

# Guards each RBAC rule on the value that decides whether keelson will use it: a
# rule for an unwatched kind is a grant nobody needs.
#
# Upstream ships one resource per rule, so the rule is emitted untouched and only
# the guard is added. Several resources, or one with no guard, stops the build.
guard_rbac_rules() {
    awk '
        function guard_for(resource) {
            if (resource == "deployments")     return "has \"Deployment\" .Values.keelson.watchedKinds"
            if (resource == "statefulsets")    return "has \"StatefulSet\" .Values.keelson.watchedKinds"
            if (resource == "daemonsets")      return "has \"DaemonSet\" .Values.keelson.watchedKinds"
            if (resource == "cronjobs")        return "has \"CronJob\" .Values.keelson.watchedKinds"
            if (resource == "jobs")            return "and .Values.rbac.allowJobCreate (has \"CronJob\" .Values.keelson.watchedKinds)"
            if (resource == "secrets")         return ".Values.rbac.allowSecretRead"
            if (resource == "serviceaccounts") return "eq .Values.keelson.respectServiceAccountPullSecrets \"true\""
            return ""
        }

        function emit_rule(   guard, i) {
            guard = guard_for(resource)
            if (guard == "") {
                printf "%s: no guard known for RBAC resource %s\n", FILENAME, resource > "/dev/stderr"
                failed = 1
            } else {
                printf "{{- if %s }}\n", guard
                for (i = 1; i <= held; i++) print lines[i]
                printf "{{- end }}\n"
            }
            held = 0
            resource = ""
        }

        !in_rules && /^rules:[[:space:]]*$/ { in_rules = 1; print; next }
        !in_rules { print; next }

        /^[[:space:]]*$/ { next }

        {
            lines[++held] = $0
        }

        /^[[:space:]]*resources:/ {
            if ($0 ~ /,/) {
                printf "%s:%d: one resource per rule expected, got %s\n", FILENAME, NR, $0 > "/dev/stderr"
                failed = 1
            }
            if (match($0, /"[a-z]+"/)) {
                resource = substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }

        /^[[:space:]]*verbs:/ { emit_rule(); next }

        END {
            if (held > 0) {
                printf "%s: rule at end of file has no verbs\n", FILENAME > "/dev/stderr"
                failed = 1
            }
            if (failed) exit 1
        }
    '
}

# Inside range "." is the loop item, so root references become "$". Missing one
# renders empty instead of failing, hence mechanical and asserted afterwards.
rebind_dot_to_root() {
    sed -E '
        s| \.Release\.| $.Release.|g
        s| \.Values\.| $.Values.|g
        s|include ("[^"]+") \.|include \1 $|g
    '
}

# The add-ons name keelson's namespace with a token; here it is the release one.
rewrite_keelson_namespace_token() {
    sed -E 's|\{\{ \.Values\.keelson[A-Za-z]+\.keelsonNamespace \}\}|{{ .Release.Namespace }}|g'
}

# One pair per watched namespace other than keelson's own, which role-own-ns
# covers. The subject stays keelson's ServiceAccount in the release namespace.
#
# Unprefixed, because a namespaced object is already scoped by its namespace,
# which is why upstream prefixes only cluster-scoped names. uniq so a namespace
# listed twice renders once; the env keeps the list as typed so keelson logs it.
transform_foreign_ns() {
    {
        printf '{{- range $foreignNamespace := uniq .Values.keelson.namespaces }}\n'
        printf '{{- if ne $foreignNamespace $.Release.Namespace }}\n'
        printf -- '---\n'
        collapse_labels_and_annotations "$1" \
            | apply_namespaced_names \
            | sed -E 's|^  namespace: \{\{ \.Release\.Namespace \}\}$|  namespace: {{ $foreignNamespace }}|' \
            | rewrite_keelson_namespace_token \
            | apply_addon_names "${FOREIGN_PROJECT}" \
            | guard_rbac_rules \
            | rebind_dot_to_root
        printf '{{- end }}\n'
        printf '{{- end }}\n'
    } > "$2"
}

# As transform_foreign_ns, but gated on a second condition and over every listed
# namespace: an add-on ships one pair for all of them, keelson's own included.
transform_ranged_addon() {
    local guard="$1" project="$2"
    {
        printf '{{- if %s }}\n' "${guard}"
        printf '{{- range $watchedNamespace := uniq .Values.keelson.namespaces }}\n'
        printf -- '---\n'
        collapse_labels_and_annotations "$3" \
            | apply_namespaced_names \
            | sed -E 's|^  namespace: \{\{ \.Release\.Namespace \}\}$|  namespace: {{ $watchedNamespace }}|' \
            | rewrite_keelson_namespace_token \
            | apply_addon_names "${project}" \
            | rebind_dot_to_root
        printf '{{- end }}\n'
        printf '{{- end }}\n'
    } > "$4"
}

# Helm cannot conditionally include a file, so the guard wraps the document.
transform_guarded() {
    local guard="$1"
    {
        printf '{{- if %s }}\n' "${guard}"
        collapse_labels_and_annotations "$2" | apply_namespaced_names
        printf '{{- end }}\n'
    } > "$3"
}

# As above, for the two documents whose rules are per-kind and per-feature.
transform_guarded_rules() {
    local guard="$1"
    {
        printf '{{- if %s }}\n' "${guard}"
        collapse_labels_and_annotations "$2" | apply_namespaced_names | guard_rbac_rules
        printf '{{- end }}\n'
    } > "$3"
}

# The add-on variant: project naming, and the token for keelson's namespace.
transform_guarded_addon() {
    local guard="$1" project="$2"
    {
        printf '{{- if %s }}\n' "${guard}"
        collapse_labels_and_annotations "$3" | apply_namespaced_names \
            | rewrite_keelson_namespace_token | apply_addon_names "${project}"
        printf '{{- end }}\n'
    } > "$4"
}

transform_configmap() {
    collapse_labels_and_annotations "$1" \
        | apply_namespaced_names \
        | rewrite_configmap_registries \
        > "$2"
}

transform_deployment() {
    local staged="${WORKDIR}/deployment.stage1.yaml"
    collapse_labels_and_annotations "$1" \
        | rewrite_deployment_selector \
        | apply_namespaced_names \
        | apply_deployment_fixups \
        | derive_env_lists \
        | inject_forced_cpu_limit \
        | apply_pod_passthroughs \
        > "${staged}"
    add_checksum_annotation "${staged}" > "$2"
}

# --- Chart.yaml + values.yaml ------------------------------------------------

# Name and versions only; the rest is metadata.yaml, comments included, so a note
# to chart users can sit beside the field it is about.
generate_chart_yaml() {
    local pin="$1"
    local version="$2"
    if [[ ! -f "${CHART_METADATA}" ]]; then
        printf 'Chart metadata not found: %s\n' "${CHART_METADATA}" >&2
        exit 1
    fi
    {
        printf 'apiVersion: v2\n'
        printf 'name: keelson\n'
        printf 'version: %s\n' "${version}"
        printf 'appVersion: "%s"\n' "${pin}"
        cat "${CHART_METADATA}"
    } > "${CHART_DIR}/Chart.yaml"
}

values_default_is_omitted() {
    local candidate="$1" omitted
    for omitted in "${VALUES_OMITTED_DEFAULTS[@]}"; do
        if [[ "${candidate}" == "${omitted}" ]]; then
            return 0
        fi
    done
    return 1
}

# Not verbatim because its version examples have to match the manifests built
# from, and hand-editing those at each bump is a diff waiting to be forgotten.
# Tables are re-padded after, since the token is wider than the pin it becomes.
generate_chart_readme() {
    local pin="$1"
    if [[ ! -f "${CHART_README}" ]]; then
        printf 'Chart README not found: %s\n' "${CHART_README}" >&2
        exit 1
    fi
    sed "s|@KEELSON_PIN@|${pin}|g" "${CHART_README}" | realign_markdown_tables > "${CHART_DIR}/README.md"
}

# Pads each cell to the widest in its column, over runs of adjacent | lines.
realign_markdown_tables() {
    awk '
        function flush(   row, col, cell, out, pad) {
            for (row = 1; row <= rows; row++) {
                out = "|"
                for (col = 1; col <= columns; col++) {
                    cell = table[row, col]
                    if (row == 2) {
                        cell = ""
                        for (pad = 0; pad < width[col] + 2; pad++) cell = cell "-"
                        out = out cell "|"
                    } else {
                        out = out " " cell
                        for (pad = length(cell); pad < width[col]; pad++) out = out " "
                        out = out " |"
                    }
                }
                print out
            }
            rows = 0
            columns = 0
            delete width
            delete table
        }

        /^\|/ {
            rows++
            count = split($0, cells, "|")
            for (i = 2; i < count; i++) {
                cell = cells[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
                table[rows, i - 1] = cell
                if (rows != 2 && length(cell) > width[i - 1]) width[i - 1] = length(cell)
                if (i - 1 > columns) columns = i - 1
            }
            next
        }

        { if (rows > 0) flush(); print }

        END { if (rows > 0) flush() }
    '
}

to_camel_case() {
    local name="$1"
    local first_lower
    first_lower="$(printf '%s' "${name:0:1}" | tr '[:upper:]' '[:lower:]')"
    printf '%s%s' "${first_lower}" "${name:1}"
}

# The hand-maintained file with the keelson: block spliced in at its marker, so
# wording changes need nothing here.
generate_values_yaml() {
    local pin="$1"
    if [[ ! -f "${VALUES_HEADER}" ]]; then
        printf 'Values header not found: %s\n' "${VALUES_HEADER}" >&2
        exit 1
    fi
    if ! grep -qF "${VALUES_DEFAULTS_MARKER}" "${VALUES_HEADER}"; then
        printf '%s has no %s marker to splice the keelson: block into.\n' \
            "${VALUES_HEADER}" "${VALUES_DEFAULTS_MARKER}" >&2
        exit 1
    fi

    local defaults_block="${WORKDIR}/keelson-defaults.yaml"
    {
        printf 'keelson:\n'
        while IFS= read -r -d '' default_file; do
            key="$(basename "${default_file}")"
            if values_default_is_omitted "${key}"; then
                continue
            fi
            camel="$(to_camel_case "${key}")"
            value="$(<"${default_file}")"
            value="${value%$'\n'}"
            # A list here instead of the space-separated string keelson takes,
            # because it also decides which RBAC objects render, and a list is
            # what --set and a values file express cleanly.
            if [[ "${key}" == "Namespaces" ]]; then
                if [[ -n "${value}" ]]; then
                    printf 'Upstream now defaults Namespaces to "%s"; the chart assumes empty.\n' "${value}" >&2
                    exit 1
                fi
                printf '  %s: []\n' "${camel}"
                continue
            fi
            # A list for the same reasons as Namespaces, and because the RBAC
            # rules are guarded on it entry by entry.
            if [[ "${key}" == "WatchedKinds" ]]; then
                printf '  %s:\n' "${camel}"
                for kind in ${value}; do
                    printf '    - %s\n' "${kind}"
                done
                continue
            fi
            # Single quotes because YAML processes escapes inside double ones: a
            # default carrying a backslash would land here as something else and
            # still parse. Doubling any quote in the value is the whole escaping
            # rule for this form. Quoted at all so "60" stays a string.
            printf "  %s: '%s'\n" "${camel}" "${value//${SINGLE_QUOTE}/${SINGLE_QUOTE}${SINGLE_QUOTE}}"
        done < <(find "${KEELSON_DEFAULTS}/Keelson" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
    } > "${defaults_block}"

    sed "s|@KEELSON_PIN@|${pin}|g" "${VALUES_HEADER}" \
        | awk -v marker="${VALUES_DEFAULTS_MARKER}" -v block="${defaults_block}" '
            index($0, marker) > 0 {
                while ((getline line < block) > 0) print line
                close(block)
                next
            }
            { print }
        ' > "${CHART_DIR}/values.yaml"
}

# --- Drive -------------------------------------------------------------------

# Rebuilt from empty, so a template upstream drops shows up as a deletion.
if [[ ! -d "${VERBATIM_DIR}" ]]; then
    printf 'Verbatim chart files not found: %s\n' "${VERBATIM_DIR}" >&2
    exit 1
fi
printf 'Clearing %s\n' "${CHARTS_ROOT}"
rm -rf "${CHARTS_ROOT}"
mkdir -p "${TEMPLATES_DIR}"

# Copied first, so a transform that wrongly targets one shows up in the gate.
printf 'Copying verbatim chart files\n'
cp -R "${VERBATIM_DIR}/." "${CHART_DIR}/"

printf 'Writing Chart.yaml, values.yaml and README.md\n'
generate_chart_yaml "${KEELSON_PIN}" "${CHART_VERSION}"
generate_values_yaml "${KEELSON_PIN}"
generate_chart_readme "${KEELSON_PIN}"

printf 'Transforming manifests\n'
transform_serviceaccount "${KEELSON_MANIFESTS}/serviceaccount.yaml"      "${TEMPLATES_DIR}/serviceaccount.yaml"
transform_configmap      "${KEELSON_MANIFESTS}/configmap.yaml"           "${TEMPLATES_DIR}/configmap.yaml"
transform_deployment     "${KEELSON_MANIFESTS}/deployment.yaml"          "${TEMPLATES_DIR}/deployment.yaml"

# Keelson's own operating needs, written in every mode. Never guarded.
transform_namespaced     "${KEELSON_MANIFESTS}/role.yaml"                "${TEMPLATES_DIR}/role.yaml"
transform_namespaced     "${KEELSON_MANIFESTS}/rolebinding.yaml"         "${TEMPLATES_DIR}/rolebinding.yaml"

# keelson.namespaces decides all of the below. Empty is cluster-wide; any entry
# means the own-ns pair if keelson's is listed, a foreign pair for each that is
# not, and the small ClusterRole it uses to check at boot that they exist.
transform_guarded_rules 'has .Release.Namespace .Values.keelson.namespaces' \
    "${KEELSON_MANIFESTS}/role-own-ns.yaml"           "${TEMPLATES_DIR}/role-own-ns.yaml"
transform_guarded 'has .Release.Namespace .Values.keelson.namespaces' \
    "${KEELSON_MANIFESTS}/rolebinding-own-ns.yaml"    "${TEMPLATES_DIR}/rolebinding-own-ns.yaml"

transform_guarded_rules 'not .Values.keelson.namespaces' \
    "${KEELSON_MANIFESTS}/clusterrole-all-ns.yaml"        "${TEMPLATES_DIR}/clusterrole-all-ns.yaml"
transform_guarded 'not .Values.keelson.namespaces' \
    "${KEELSON_MANIFESTS}/clusterrolebinding-all-ns.yaml" "${TEMPLATES_DIR}/clusterrolebinding-all-ns.yaml"

transform_guarded '.Values.keelson.namespaces' \
    "${KEELSON_MANIFESTS}/clusterrole.yaml"        "${TEMPLATES_DIR}/clusterrole.yaml"
transform_guarded '.Values.keelson.namespaces' \
    "${KEELSON_MANIFESTS}/clusterrolebinding.yaml" "${TEMPLATES_DIR}/clusterrolebinding.yaml"

transform_foreign_ns "${FOREIGN_MANIFESTS}/role.yaml"        "${TEMPLATES_DIR}/foreign-ns-role.yaml"
transform_foreign_ns "${FOREIGN_MANIFESTS}/rolebinding.yaml" "${TEMPLATES_DIR}/foreign-ns-rolebinding.yaml"

# Rollout RBAC follows watchedKinds like every other kind: a separate flag could
# only disagree with the list. The bundle ships both scopes, so it takes the same
# fork keelson's own rules do.
ARGO_WATCHED='has "Rollout" .Values.keelson.watchedKinds'
transform_guarded_addon "and (${ARGO_WATCHED}) (not .Values.keelson.namespaces)" "${ARGO_PROJECT}" \
    "${ARGO_MANIFESTS}/clusterrole.yaml"           "${TEMPLATES_DIR}/argo-rollouts-clusterrole.yaml"
transform_guarded_addon "and (${ARGO_WATCHED}) (not .Values.keelson.namespaces)" "${ARGO_PROJECT}" \
    "${ARGO_MANIFESTS}/clusterrolebinding.yaml"    "${TEMPLATES_DIR}/argo-rollouts-clusterrolebinding.yaml"

transform_ranged_addon "${ARGO_WATCHED}" "${ARGO_PROJECT}" \
    "${ARGO_MANIFESTS}/role.yaml"                  "${TEMPLATES_DIR}/argo-rollouts-role.yaml"
transform_ranged_addon "${ARGO_WATCHED}" "${ARGO_PROJECT}" \
    "${ARGO_MANIFESTS}/rolebinding.yaml"           "${TEMPLATES_DIR}/argo-rollouts-rolebinding.yaml"

# The other end of the collapse check: all four in every template, so a transform
# that never ran is caught too.
printf 'Checking provenance keys\n'
for template in "${TEMPLATES_DIR}"/*.yaml
do
    for provenance_key in \
        kaptain.org/project-name kaptain.org/version kaptain.org/owner kaptain.org/source-repository
    do
        if ! grep -qE "^[[:space:]]+${provenance_key}: " "${template}"; then
            printf '%s carries no %s\n' "${template}" "${provenance_key}" >&2
            exit 1
        fi
    done
done

printf 'Checking values coverage\n'
while IFS= read -r -d '' default_file
do
    default_name="$(basename "${default_file}")"
    if values_default_is_omitted "${default_name}"; then
        continue
    fi
    if ! grep -qE "^  $(to_camel_case "${default_name}"):( |$)" "${CHART_DIR}/values.yaml"; then
        printf 'Upstream default %s has no entry in values.yaml.\n' "${default_name}" >&2
        exit 1
    fi
done < <(find "${KEELSON_DEFAULTS}/Keelson" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)

while read -r values_key
do
    if ! grep -qE "^  ${values_key}:( |$)" "${CHART_DIR}/values.yaml"; then
        printf 'Chart reads .Values.keelson.%s, which values.yaml does not set.\n' "${values_key}" >&2
        exit 1
    fi
done < <(grep -rhoE '\.Values\.keelson\.[a-zA-Z0-9]+' "${TEMPLATES_DIR}" "${CHART_DIR}/values.yaml" \
    | sed 's#.*\.Values\.keelson\.##' | sort -u)

# Env and RBAC both come from keelson.namespaces. A stale scope reference would
# render empty and be rejected at boot instead of at install.
printf 'Checking namespace wiring\n'
if grep -n '\.Values\.keelson\.scope' "${TEMPLATES_DIR}"/*.yaml >&2; then
    printf 'keelson.scope is derived from keelson.namespaces and is not a value.\n' >&2
    exit 1
fi
for guarded in \
    "role-own-ns:has .Release.Namespace .Values.keelson.namespaces" \
    "rolebinding-own-ns:has .Release.Namespace .Values.keelson.namespaces" \
    "clusterrole-all-ns:not .Values.keelson.namespaces" \
    "clusterrolebinding-all-ns:not .Values.keelson.namespaces" \
    "clusterrole:.Values.keelson.namespaces" \
    "clusterrolebinding:.Values.keelson.namespaces"
do
    if ! head -1 "${TEMPLATES_DIR}/${guarded%%:*}.yaml" | grep -qF "{{- if ${guarded#*:} }}"; then
        printf '%s.yaml does not open with its keelson.namespaces guard.\n' "${guarded%%:*}" >&2
        exit 1
    fi
done

# A bare root reference in a range renders empty: lints clean, installs broken.
for ranged in foreign-ns-role foreign-ns-rolebinding argo-rollouts-role argo-rollouts-rolebinding
do
    if grep -nE '\{\{-? *\.| \. \}\}| \. \|' "${TEMPLATES_DIR}/${ranged}.yaml" >&2; then
        printf '%s.yaml has a root reference that is not $ inside range (above).\n' "${ranged}" >&2
        exit 1
    fi
done

# A literal package version in the source is one written where @KEELSON_PIN@
# belongs, wrong at the next bump; a surviving token is a substitution missed.
printf 'Checking README version examples\n'
if grep -nE '[0-9]+\.[0-9]+\.1\.[0-9]+' "${CHART_README}" >&2; then
    printf 'Hard-coded package version in %s; use @KEELSON_PIN@ (above).\n' "${CHART_README}" >&2
    exit 1
fi
if grep -nE '@[A-Z_]+@' "${CHART_DIR}/README.md" >&2; then
    printf 'Unsubstituted token left in the generated README (above).\n' >&2
    exit 1
fi

# An unbalanced file renders a truncated rule list instead of failing.
printf 'Checking guarded RBAC rules\n'
for ruled in role-own-ns clusterrole-all-ns foreign-ns-role
do
    if grep -nE '^[[:space:]]+resources: \[[^]]*,' "${TEMPLATES_DIR}/${ruled}.yaml" >&2; then
        printf '%s.yaml has a rule with more than one resource (above).\n' "${ruled}" >&2
        exit 1
    fi
    OPENED=$(grep -cE '^\{\{- (if|range)' "${TEMPLATES_DIR}/${ruled}.yaml" || true)
    CLOSED=$(grep -cE '^\{\{- end \}\}' "${TEMPLATES_DIR}/${ruled}.yaml" || true)
    if [[ "${OPENED}" -ne "${CLOSED}" ]]; then
        printf '%s.yaml opens %s blocks and closes %s.\n' "${ruled}" "${OPENED}" "${CLOSED}" >&2
        exit 1
    fi
done

# Upstream content the transforms replace, none of which should survive. The
# environment rewrite matches exact spacing, so a converter change leaves it.
printf 'Checking for untransformed leftovers\n'
if grep -rnE '\.Values\.(environment|productName)|managed-by: Kaptain|app\.kubernetes\.io/instance' \
    "${TEMPLATES_DIR}" >&2
then
    printf 'Upstream content the transforms should have replaced survived (above).\n' >&2
    exit 1
fi

# Injected by anchoring on lines the collapse emits, so they are first to vanish
# if that output changes, and their absence renders and lints clean.
printf 'Checking values passthroughs\n'
for passthrough in \
    "deployment.yaml:podLabels" \
    "deployment.yaml:podAnnotations" \
    "deployment.yaml:imagePullSecrets" \
    "deployment.yaml:nodeSelector" \
    "deployment.yaml:tolerations" \
    "deployment.yaml:affinity" \
    "deployment.yaml:priorityClassName" \
    "deployment.yaml:forceCpuLimit" \
    "serviceaccount.yaml:serviceAccount.labels" \
    "serviceaccount.yaml:serviceAccount.annotations"
do
    if ! grep -qF ".Values.${passthrough#*:} }" "${TEMPLATES_DIR}/${passthrough%%:*}"; then
        printf '%s no longer offers %s.\n' "${passthrough%%:*}" "${passthrough#*:}" >&2
        exit 1
    fi
done

# A second image line is a container the chart has no values for.
printf 'Checking the image rewrite\n'
IMAGE_LINES=$(grep -cE '^[[:space:]]+image:' "${TEMPLATES_DIR}/deployment.yaml" || true)
if [[ "${IMAGE_LINES}" -ne 1 ]] \
    || ! grep -qE '^[[:space:]]+image: \{\{ include "keelson\.image" \. \}\}$' "${TEMPLATES_DIR}/deployment.yaml"
then
    printf 'Expected exactly one image line, rewritten to keelson.image. Found:\n' >&2
    grep -nE '^[[:space:]]+image:' "${TEMPLATES_DIR}/deployment.yaml" >&2
    exit 1
fi

# A literal name here means a rewrite missed, which renders and lints clean and
# shows up as a resource not found at runtime. "- name: keelson" is the container.
printf 'Checking for missed name rewrites\n'
if LEFTOVER=$(grep -nE '^[[:space:]]+(name|serviceAccountName): keelson$' "${TEMPLATES_DIR}"/*.yaml); then
    printf 'Literal keelson names left where the fullname helper was expected:\n%s\n' "${LEFTOVER}" >&2
    exit 1
fi

# assertUnreserved cannot read the keys the templates set literally, so an
# upstream one it does not list would pass silently. Checked here instead.
printf 'Checking reserved keys\n'
while read -r literal_key
do
    if ! grep -q "\"${literal_key}\"" "${TEMPLATES_DIR}/_helpers.tpl"; then
        printf 'Templates set %s but keelson.assertUnreserved does not reserve it.\n' "${literal_key}" >&2
        printf 'Add it there, in %s/templates/_helpers.tpl.\n' "${CHART_SRC_DIR}" >&2
        exit 1
    fi
done < <(grep -hoE '^[[:space:]]+(kaptain\.org|checksum)/[a-z-]+:' "${TEMPLATES_DIR}"/*.yaml \
    | tr -d '[:blank:]:' | sort -u)

printf '\n== chart sync gate (BUILD_MODE=%s) ==\n' "${BUILD_MODE}"

# local compares against the index so `git add` then re-run passes; build_server
# against HEAD so staging cannot mask it. Untracked files need their own check.
GATE_FAILED=0
if [[ "${BUILD_MODE}" == "build_server" ]]; then
    git diff --exit-code HEAD -- "${CHARTS_ROOT}" || GATE_FAILED=1
else
    git diff --exit-code -- "${CHARTS_ROOT}" || GATE_FAILED=1
fi

UNTRACKED="$(git ls-files --others --exclude-standard -- "${CHARTS_ROOT}")"
if [[ -n "${UNTRACKED}" ]]; then
    printf '\nUntracked generated files under %s:\n%s\n' "${CHARTS_ROOT}" "${UNTRACKED}" >&2
    GATE_FAILED=1
fi

if [[ "${GATE_FAILED}" -ne 0 ]]; then
    printf '\nRegenerated chart deviates from what git has.\n' >&2
    if [[ "${BUILD_MODE}" == "build_server" ]]; then
        printf 'The committed chart was not regenerated before pushing. Run the build\n' >&2
        printf 'locally, git add charts, re-run to confirm clean, commit, push.\n' >&2
    else
        printf 'Expected on the first run after a change. Inspect the diff, then\n' >&2
        printf 'git add %s and re-run.\n' "${CHARTS_ROOT}" >&2
    fi
    exit 1
fi
printf 'Chart is in sync at version %s.\n' "${CHART_VERSION}"

# Both required values, so the tag check and the registries block are exercised.
SMOKE_TAG="${KEELSON_PIN}.0.0-smoke-test"
SMOKE_VALUES=(--set image.tag="${SMOKE_TAG}" --set registry=smoke-registry.example.com)

printf '\n== helm lint ==\n'
helm lint "${CHART_DIR}" "${SMOKE_VALUES[@]}"

printf '\n== helm template ==\n'
helm template smoke-test "${CHART_DIR}" \
    --namespace cluster-infra \
    "${SMOKE_VALUES[@]}" \
    > /dev/null
printf 'Render OK.\n'

# Shadowing app.kubernetes.io/name leaves the Deployment unable to match its own
# pods, and lints clean without the guard.
printf '\n== reserved key rejected ==\n'
if helm template smoke-test "${CHART_DIR}" \
    --namespace cluster-infra \
    "${SMOKE_VALUES[@]}" \
    --set-json 'podLabels={"app.kubernetes.io/name":"shadowed"}' \
    > /dev/null 2>&1
then
    printf 'podLabels overwrote a reserved key without failing.\n' >&2
    exit 1
fi
printf 'Rejected.\n'

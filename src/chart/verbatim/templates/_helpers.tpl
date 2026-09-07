{{/*
Hand-maintained helpers for the keelson chart.

This is the SOURCE copy, under src/chart/verbatim/. The build copies it into
charts/keelson/templates/ on every run, and the whole of charts/ is then diffed
against git with no exclusions - so editing the copy under charts/ achieves
nothing except a failed build. Edit here.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "keelson.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name for NAMESPACED resources.

Deliberately NOT prefixed with the release name: the thing being deployed is
keelson, and it should be called keelson regardless of what the release is
named. Defaults to the chart name and stays overridable the usual Helm way:

    (default)                          -> keelson
    --set nameOverride=bar             -> bar
    --set fullnameOverride=keelson-dev -> keelson-dev

Truncated to 63 chars because some Kubernetes name fields are DNS-limited.
*/}}
{{- define "keelson.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Cluster-scoped objects (ClusterRole, ClusterRoleBinding) have no helper of their
own. The generator builds their names inline, keeping the namespace prefix
upstream already puts there:

    {{ .Release.Namespace }}.{{ include "keelson.fullname" . }}

and the -all-ns pair adds that suffix. Cluster-scoped names must be unique
cluster-wide while keelson.fullname is release-independent, so the namespace is
what separates two installs; fullnameOverride separates two in one namespace.

Deliberately no trunc 63 on that form: the 63-char limit is a DNS label and
label-value limit, and these are ordinary object names bounded at 253.
Truncating could make two long namespaces collide on one ClusterRole, causing
the exact clash the prefix exists to prevent.

Add-on objects, from the Argo Rollouts and foreign-namespace projects, are named
the same way with their project's suffix kept:

    {{ .Release.Namespace }}.{{ include "keelson.fullname" . }}-argo-rollouts-rbac

so the name says both which install the grant is for and where the rules came
from. Both parts matter: two installs in one namespace would otherwise collide.
*/}}

{{/*
Chart name+version label value (e.g. keelson-1.4.1).
*/}}
{{- define "keelson.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Selector labels, written into spec.selector.matchLabels and the pod template.
A single label, as upstream ships it, with the literal swapped for the helper so
it still matches under a rename. spec.selector is immutable, so anything added
here breaks in-place upgrades from a Kaptain-deployed keelson.

keelson.fullname instead of keelson.name: the two are identical unless
fullnameOverride is set, and that is the one case where they must differ. Two
installs in one namespace with the same selector would have their ReplicaSets
fight over each other's pods.
*/}}
{{- define "keelson.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keelson.fullname" . }}
{{- end }}

{{/*
Common labels - written into every object's metadata.labels and into the
pod template labels. Includes selectorLabels.

Nothing from kaptain.org/* here: those are upstream provenance and pass straight
through from the source manifests, so they stay true even if keelson moves org.
*/}}
{{- define "keelson.labels" -}}
helm.sh/chart: {{ include "keelson.chart" . }}
{{ include "keelson.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{- end }}

{{/*
Guard for the user-supplied label and annotation maps.

They are written into the same YAML map as the chart's own keys, so a collision
is a duplicate key that helm lint passes and one side silently wins - including
app.kubernetes.io/name, which the Deployment selector matches on. Fail instead,
naming the keys. Call with kind "labels" or "annotations".

The label keys are read back out of keelson.labels so they cannot drift from it.
The kaptain.org keys are upstream provenance the generator passes through, and
regenerate-chart.bash asserts the templates set none outside this list.
*/}}
{{- define "keelson.assertUnreserved" -}}
{{- $reserved := list "kaptain.org/source-repository" "checksum/config" -}}
{{- if eq .kind "labels" -}}
{{- $reserved = concat (keys (fromYaml (include "keelson.labels" .ctx))) (list "kaptain.org/project-name" "kaptain.org/version" "kaptain.org/owner") -}}
{{- end -}}
{{- $clash := list -}}
{{- range $key, $_ := .user -}}
{{- if has $key $reserved -}}
{{- $clash = append $clash $key -}}
{{- end -}}
{{- end -}}
{{- if $clash -}}
{{- fail (printf "\n\n%s may not set: %s\n\nThe chart sets those itself. Both copies land in the same map, where one silently overwrites the other, so remove them from your values.\n" .field (join ", " $clash)) -}}
{{- end -}}
{{- end }}

{{/*
The registries block for registries.yaml.

.Values.registries is a STRING rendered through tpl, not a map, so the default
can carry a token the user fills in the same way as image.tag:

    --set registry=registry.example.com

Trimmed, because the conditional in the default leaves a leading newline that
nindent would turn into a blank line. Empty renders as {} instead of nothing,
so registries: always has a value: Keelson needs none of this when workloads
carry their own pull secrets.
*/}}
{{- define "keelson.registries" -}}
{{- $rendered := tpl .Values.registries . | trim -}}
{{- if $rendered }}{{ $rendered }}{{ else }}{}{{ end -}}
{{- end }}

{{/*
Image reference. .Values.image.tag is REQUIRED - no default. Pick a tag
from the keelson-package container registry whose kubectl version matches
your cluster's +/-1 window.
*/}}
{{- define "keelson.image" -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag is required - pick a tag from https://github.com/keelson-pro/keelson-package/pkgs/container/keelson%2Fkeelson-package whose kubectl matches your cluster" -}}
{{- end -}}
{{- $line := printf "%s." .Chart.AppVersion -}}
{{- if and (not .Values.image.allowVersionMismatch) (not (hasPrefix $line .Values.image.tag)) -}}
{{- fail (printf "\n\nimage.tag %q is not on the keelson %s line, but these templates are generated from keelson %s.\nA package image and the manifests that configure it move together, so a mismatched pair can behave in ways neither version intends.\n\nPick a %s* tag whose kubectl minor is within one of your cluster:\n  https://github.com/keelson-pro/keelson-package/pkgs/container/keelson%%2Fkeelson-package\n\nIf you know the pairing is fine, set image.allowVersionMismatch=true.\n" .Values.image.tag .Chart.AppVersion .Chart.AppVersion $line) -}}
{{- end -}}
{{- printf "%s/%s:%s" .Values.image.registryAndNamespace .Values.image.name .Values.image.tag -}}
{{- end }}

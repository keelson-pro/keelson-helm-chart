Helm chart for [Keelson](https://github.com/keelson-pro/keelson), built from
keelson `@KEELSON_PIN@` manifests.

## Install

The chart is published as a Helm OCI artefact. This is the one to use:

```bash
helm install keelson oci://@CHART_REF@ \
  --version @VERSION@ \
  --namespace cluster-infra --create-namespace \
  --set image.tag=<keelson-package-tag>
```

Or from the classic repo, which serves every released version:

```bash
helm repo add keelson @PAGES_URL@
helm repo update
helm install keelson keelson/keelson --version @VERSION@ \
  --namespace cluster-infra --create-namespace \
  --set image.tag=<keelson-package-tag>
```

The `.tgz` attached below is the same artefact, and is what the classic repo
index points at.

## Picking `image.tag`

Required, no default. It must be on the keelson `@KEELSON_PIN@` line, matching
these manifests, and its `kubectl` minor must be within one of your API server.
Rendering fails with guidance if either is wrong.

Tags: <https://github.com/keelson-pro/keelson-package/pkgs/container/keelson%2Fkeelson-package>

## Contents

| | |
| --- | --- |
| Chart version | `@VERSION@` |
| keelson source | `@KEELSON_PIN@` |
| Argo Rollouts RBAC add-on | `@ARGO_PIN@`, installed when `keelson.watchedKinds` names `Rollout` |
| Foreign namespace RBAC add-on | `@FOREIGN_PIN@`, used per namespace listed in `keelson.namespaces` |

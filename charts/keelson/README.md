# Keelson

[Keelson](https://github.com/keelson-pro/keelson) is a near drop-in replacement
 for [Keel](https://keel.sh) with better docs, better logging, and a simpler,
opinionated implementation.

This chart deploys a single-replica Keelson controller into a namespace. By
default it watches the whole cluster. Listing namespaces in
`keelson.namespaces` confines it to those, and grants it nothing outside them.

Keelson is cluster infrastructure, so install it alongside your other
cluster-wide components rather than in a namespace of its own. The examples
below use `cluster-infra`; use whatever you already call that namespace.

One value is required, and rendering fails without it: `image.tag`.


## Choosing `image.tag`

Keelson is Kubernetes version agnostic for most intents and purposes. Its
scripts are released and versioned in the `keelson` project, then consumed in
the `keelson-package` project in a series of branches, one for each Kubernetes
version. Package versions are self-explanatory once you know the pattern:

```
# Parts
[Keelson version][Kube major.minor][package patch]
# Format
1.X.1.Y.Z
# Example
1.24.1.36.1
```

Where:

* X is the Keelson minor, and must match this chart's `appVersion`, because the
  package and the manifests that configure it are released together.
* Y is your cluster's Kubernetes minor, plus or minus one, matching kubectl's
  +/-1 support window.
* Z is a per-release patch starting at 1 for a given combination of Keelson and
  kube support.

Read your cluster's minor from your cloud console or API, or with an active kube
config:

```bash
kubectl version -o yaml | grep -A2 serverVersion
```

**Take the highest Y your cluster allows, one above its current minor, and the
highest Z.** For a chart whose `appVersion` is `1.24`:

| Cluster | Suitable package versions                   | Recommended   |
|---------|---------------------------------------------|---------------|
| `1.35`  | `1.24.1.34.Z`, `1.24.1.35.Z`, `1.24.1.36.Z` | `1.24.1.36.Z` |
| `1.36`  | `1.24.1.35.Z`, `1.24.1.36.Z`, `1.24.1.37.Z` | `1.24.1.37.Z` |

Every version in the middle column suits the cluster today, but they age
differently. Pinning one above your cluster leaves two cluster upgrades before
the pairing is unsupported. Matching your cluster exactly leaves one. Pinning
below leaves none, since the next upgrade takes you outside the window. Z is
usually 1, but take the highest published.

Published versions are on the [keelson-package releases page](https://github.com/keelson-pro/keelson-package/releases).
Rendering fails if X does not match this chart's `appVersion`, naming the line to
pick from. To pair them deliberately anyway, set `image.allowVersionMismatch=true`.


## Install

```bash
# OCI (Helm 3.8+)
helm install keelson oci://ghcr.io/keelson-pro/helm-charts/keelson/keelson-helm-chart/keelson \
  --version <chart-version> \
  --namespace cluster-infra --create-namespace \
  --set image.tag=<package-tag> \
  --set registry=<your-registry-host>

# Classic repo via GitHub Pages
helm repo add keelson https://keelson-pro.github.io/keelson-helm-chart
helm repo update
helm install keelson keelson/keelson \
  --namespace cluster-infra --create-namespace \
  --set image.tag=<package-tag> \
  --set registry=<your-registry-host>

# From a clone
helm install keelson ./keelson-helm-chart/charts/keelson \
  --namespace cluster-infra --create-namespace \
  --set image.tag=<package-tag> \
  --set registry=<your-registry-host>
```

The [`helm-git`](https://github.com/aslafy-z/helm-git) plugin also works:

```bash
helm install keelson \
  "git+https://github.com/keelson-pro/keelson-helm-chart@charts/keelson?ref=main" \
  --namespace cluster-infra --create-namespace \
  --set image.tag=<package-tag> --set registry=<your-registry-host>
```

For production, copy the image into your own registry and point at it:

```bash
--set image.registryAndNamespace=registry.example.com/platform \
--set image.name=keelson/keelson-package
```


## Registries

Keelson authenticates to a registry to read tags. It tries the central config in
this chart, `registries.yaml`, first, then falls back to the workload's own
`imagePullSecrets`, and its ServiceAccount's after those when
`keelson.respectServiceAccountPullSecrets` is `true`.

Central first because a host you have configured then costs no Secret read per
workload, and because it is the credential you can reason about. A credential
that resolves is not one that works, so each source is tried against the
registry in turn: a stale pull secret no longer masks a working central one.

So configure `registry` or `registries` for the hosts you own, and leave both
empty where every workload already carries its own. Per workload, the
`keelson.pro/credentials` annotation changes the order: `central` for central
only, `respect-pod-spec` for the workload's own only.

To fill the central config with a single registry, matching the Kaptain install:

```bash
--set registry=registry.example.com
```

These are the registries **your** workloads pull from. Keelson's own image
comes from `image.registryAndNamespace`, which is a separate thing.

`registries` is the block the chart writes into `registries.yaml`, and it
renders as a Helm template, which is how the default carries the `registry`
token:

```yaml
registries: |
  {{ required "..." .Values.registry }}:
    auth-mode: {{ .Values.keelson.authMode }}
```

Replace that block to configure several registries. The token goes with it, so
`registry` is then unused. Set `auth-mode` to `secret`, `aws`, `azure` or `gcp`.
The older `aws-irsa`, `azure-wi` and `gcp-wi` spellings are still accepted.

For `secret`, Keelson reads a dockerconfigjson Secret named after the host, with
any port's colon turned into a hyphen since a colon cannot appear in a
Kubernetes name, and looks the host up inside it verbatim. So `reg.example:5000`
reads the Secret `reg.example-5000` and finds `reg.example:5000` in its `.auths`.
Three optional fields per entry override the rest: `namespace` for where the
Secret lives, `secret-name-override` for its name, and `secret-key-override` for
the key read inside it.

Since the block is a string, `--set` mangles anything multi-line: it treats
`\n` literally. Use a values file, or `--set-file`. Each wants a different file:

```bash
# In a values file, as the value of registries
helm install keelson <chart> -f my-values.yaml

# Or in a file of its own, which becomes the value verbatim
helm install keelson <chart> --set-file registries=./registry-hosts.yaml
```

`my-values.yaml`:

```yaml
registries: |
  quay.io:
    auth-mode: secret
    namespace: platform-secrets
  123456789012.dkr.ecr.eu-west-1.amazonaws.com:
    auth-mode: aws
  europe-west1-docker.pkg.dev:
    auth-mode: gcp
```

`registry-hosts.yaml` is the same thing with the key and its indentation gone:

```yaml
quay.io:
  auth-mode: secret
  namespace: platform-secrets
123456789012.dkr.ecr.eu-west-1.amazonaws.com:
  auth-mode: aws
europe-west1-docker.pkg.dev:
  auth-mode: gcp
```

Where no file is possible, `--set-json 'registries="quay.io:\n  auth-mode: secret\n"'`
does the same with the newlines escaped by hand.


## Values

| Key                          | Description                                                     |
|------------------------------|-----------------------------------------------------------------|
| `image.tag`                  | **Required.** Package version. See above.                       |
| `image.allowVersionMismatch` | Skip the X-matches-`appVersion` check. Default `false`.         |
| `image.registryAndNamespace` | Where Keelson's own image lives. Default `ghcr.io/keelson-pro`. |
| `image.name`                 | Image name. Default `keelson/keelson-package`.                  |
| `registry`                   | Host for the default `registries` block. See above.             |
| `registries`                 | Central credential config. See above.                           |
| `keelson.namespaces`         | Namespaces to watch. Default empty, the whole cluster.          |
| `keelson.watchedKinds`       | Kinds to watch, and the RBAC that follows. See below.           |
| `rbac.allowSecretRead`       | Permit `secrets` get. Default `true`. See below.                |
| `rbac.allowJobCreate`        | Permit `jobs` create. Default `true`. See below.                |
| `nameOverride`               | Renames resources. Default the chart name, `keelson`.           |
| `fullnameOverride`           | Replaces the resource name outright.                            |
| `serviceAccount.annotations` | Bind cloud identity to the ServiceAccount. See below.           |
| `serviceAccount.labels`      | Extra ServiceAccount labels. See below.                         |
| `imagePullSecrets`           | Pull secrets for Keelson's own image.                           |
| `podAnnotations`             | Extra pod template annotations.                                 |
| `podLabels`                  | Extra pod template labels.                                      |
| `forceCpuLimit`              | CPU limit. Empty, and best left so. See `values.yaml`.          |
| `nodeSelector`               | Standard scheduling control.                                    |
| `tolerations`                | Standard scheduling control.                                    |
| `affinity`                   | Standard scheduling control.                                    |
| `priorityClassName`          | Standard scheduling control.                                    |
| `keelson.*`                  | Runtime tunables from the pinned source defaults.               |
| `keelson.awsEcrCacheDir`     | Passed to `docker-credential-ecr-login`, not read by Keelson.   |
| `keelson.awsEcrDisableCache` | The same, and empty is the answer you want. See `values.yaml`.  |

Cloud platforms that bind identity to the ServiceAccount need metadata on it:
`eks.amazonaws.com/role-arn` for EKS IRSA, `iam.gke.io/gcp-service-account` for
GKE Workload Identity, and `azure.workload.identity/client-id` plus the
`azure.workload.identity/use: "true"` label for Azure. Node credentials often
cover this already.


## Installed resources

Always:

- `Deployment` single-replica using `strategy: Recreate` since a brief absence doesn't matter
- `ServiceAccount` for the controller deployment
- `ConfigMap` holding the per-registry auth bindings, `registries.yaml`
- `Role` and `RoleBinding` for the ConfigMaps keelson keeps in its own namespace

Then whichever of these `keelson.namespaces` calls for:

- empty: `ClusterRole` and `ClusterRoleBinding` over workload kinds cluster-wide
- listed: `ClusterRole` and `ClusterRoleBinding` granting only `get` on namespaces, which keelson uses at boot to check they exist
- your own namespace listed: a second `Role` and `RoleBinding`, suffixed `-own-ns`
- any other namespace listed: a `Role` and `RoleBinding` in that namespace, one pair each

With `Rollout` in `keelson.watchedKinds`, RBAC for `rollouts.argoproj.io`
alongside whichever of the above applies: a `ClusterRole` and
`ClusterRoleBinding` when no namespaces are listed, otherwise a `Role` and
`RoleBinding` in each listed namespace.

Resources in the install namespace are named `keelson`. Names that must be
unique beyond it take the namespace as a prefix, `<namespace>.keelson`: the
cluster-scoped pair, and the pairs written into other namespaces, where two
Keelsons can be granted access to one namespace. Add-on objects keep their
project's suffix, `<namespace>.keelson-argo-rollouts-rbac` and
`<namespace>.keelson-foreign-ns-rbac`. `nameOverride` and `fullnameOverride`
move all of them.

Those namespaces must already exist, and installing needs rights to create
Roles in them. Where you do not have those rights, the namespace's owner can
install [keelson-foreign-ns-rbac](https://github.com/keelson-pro/keelson-foreign-ns-rbac)
themselves, which grants the same access from their side.


## Minimum Argo Rollouts CRD Version

Keelson only works correctly with Argo Rollouts 1.9.0 or newer. Earlier
versions of the CRD are flawed and will result in corrupted resources if used
with Keelson.


## Security through least privilege

Keelson ships RBAC for its whole feature set, and its README lists
[what can be removed and when](https://github.com/keelson-pro/keelson/blob/main/README.md#security-through-least-privilege).
This chart makes those reductions for you, from values you are setting anyway:

| Grant                                          | Held while                                         |
|------------------------------------------------|----------------------------------------------------|
| `deployments` get, list, watch, patch, update  | `keelson.watchedKinds` names `Deployment`          |
| `statefulsets` get, list, watch, patch, update | it names `StatefulSet`                             |
| `daemonsets` get, list, watch, patch, update   | it names `DaemonSet`                               |
| `cronjobs` get, list, watch, patch, update     | it names `CronJob`                                 |
| `jobs` create                                  | `rbac.allowJobCreate`, and `CronJob` watched       |
| `secrets` get                                  | `rbac.allowSecretRead`                             |
| `serviceaccounts` get                          | `keelson.respectServiceAccountPullSecrets` is true |
| `rollouts` get, list, watch, patch, update     | `keelson.watchedKinds` names `Rollout`             |
| `configmaps` get, list, create, patch, update  | always, in the install namespace only              |
| `namespaces` get                               | `keelson.namespaces` is not empty                  |

The first two reductions on that list need nothing from you: `keelson.namespaces`
picks the cluster-scoped set or the per-namespace set, never both. Leaving it
empty is the widest this chart gets, so if the Secret and Job grants above give
you pause, that is the value to change first.

# Keelson Helm Chart

Builds and publishes the Helm chart for [Keelson](https://github.com/keelson-pro/keelson).
The chart is provided as an OCI artefact, a classic Helm repo on GitHub Pages,
and a GitHub Release asset.


## Documentation

1. Using this chart: [`charts/keelson/README.md`](charts/keelson/README.md)
2. Keelson core README: [`keelson`/README.md](https://github.com/keelson-pro/keelson/blob/main/README.md)
3. Configuration detail: [`keelson`/Configuration.md](https://github.com/keelson-pro/keelson/blob/main/Configuration.md)
4. Field ownership info: [`keelson`/FieldManagerOwnership.md](https://github.com/keelson-pro/keelson/blob/main/FieldManagerOwnership.md)
5. Entry point specifications: [`keelson`/EntryPoints.md](https://github.com/keelson-pro/keelson/blob/main/EntryPoints.md)
6. Branchout ecosystem docs: [`keelson-all`/README.md](https://github.com/keelson-pro/keelson-all/blob/main/README.md)


## Layout

| Path                                          |                                                                |
|-----------------------------------------------|----------------------------------------------------------------|
| `src/upstream/KeelsonVersion`                 | Version of `keelson` main manifest set to use.                 |
| `src/upstream/KeelsonArgoRolloutsRbacVersion` | Version of `keelson-argo-rollouts-rbac` add-on to use.         |
| `src/upstream/KeelsonForeignNsRbacVersion`    | Version of `keelson-foreign-ns-rbac` add-on to use.            |
| `src/chart/verbatim/`                         | Chart files copied in unchanged, mirroring the chart layout.   |
| `src/chart/README.md`                         | The chart README. The keelson pin is substituted in.           |
| `src/chart/values-header.yaml`                | The top half of `values.yaml`. The build generates the rest.   |
| `src/chart/metadata.yaml`                     | The static half of `Chart.yaml`. The build generates the rest. |
| `charts/`                                     | Generated, and committed. Do not edit these files.             |
| `.github/bin/`                                | The build scripts chained by `build-and-publish-chart.bash`.   |

Edit chart content in `src/`. The next regeneration overwrites everything under
`charts/`, and the sync gate rejects any difference from what is committed, so
every file and template stays consistent. It's worth reviewing the diff
regardless.


## Build loop

The hook copies `src/chart/verbatim/` into the chart, generates the rest over
the top, then diffs the whole directory against last committed state.

| `BUILD_MODE`   | Compared against  | Effect                                  |
|----------------|-------------------|-----------------------------------------|
| `local`        | the git **index** | `git add charts` allows local iteration |
| `build_server` | **HEAD**          | Only fully committed content passes     |

So, locally:

```bash
kaptain build                  # regenerates, fails, shows the diff
git add charts                 # Indicate intent
kaptain build                  # passes
git commit -m "Update charts." # Ideally something better
```

Open a PR from a branch created without doing that and the PR build will fail.
Untracked files under `charts/` fail the build in both modes as they should.
If another PR/branch is merged and released first, and you rebase, the charts
will have stale version information inside them and the build will fail. Re-run
the build locally and `git commit --amend` with the results before force
pushing your branch for a re-run on your PR.


## First-time setup

If forking to a new org, delete the `gh-pages` branch for a fresh start, then
after the first release build creates `gh-pages`, enable GitHub Pages once in
Settings -> Pages: Source `gh-pages`, folder `/`.

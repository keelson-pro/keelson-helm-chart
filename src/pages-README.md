# Keelson Helm chart - classic repo index

This branch is the GitHub Pages source for the Keelson classic Helm repo:

    helm repo add keelson @PAGES_URL@
    helm repo update
    helm install keelson keelson/keelson \
        -n cluster-infra --create-namespace \
        --set image.tag=<keelson-package-tag>

The chart tarballs are NOT in this branch; they are attached as assets to
the GitHub Releases of this repo. `index.yaml` points at those URLs.

Auto-published by `.github/bin/publish-chart-index.bash`. Do not edit by hand.

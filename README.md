# _OCI charts releaser_ Action

A GitHub action for single chart or multi-chart repositories that performs push and github releases creation for the hosted charts.

## Usage

### Pre-requisites

1. A GitHub repo containing a directory with your Helm charts (one of the following folders named `/charts`, `/chart` or `helm`, if you want
   to maintain your charts in a different directory, you must include a `charts_dir` input in the workflow).
1. Create a workflow `.yml` file in your `.github/workflows` directory. An [example workflow](#example-workflow) is available below.
   For more information, reference the GitHub Help Documentation for [Creating a workflow file](https://help.github.com/en/articles/configuring-a-workflow#creating-a-workflow-file)

### Inputs

- `version`: The helm version to use (default: v3.19.4)
- `charts_dir`: The charts directory
- **`oci_registry`**: The OCI registry host
- **`oci_username`**: The username used to login to the OCI registry
- **`oci_password`**: The OCI user's password
- **`github-token`**: Github Actions token must be provided to manage release creation and update.
- `tag_name_pattern`: Specifies GitHub repository release naming pattern (ex. '{chartName}-chart'). For instance you chart is named as app, but you want it to be released as *app-chart-x.y.z*, use *tag_name_pattern* `{chartName}-chart`.
- `oci_tag_pattern`: Specifies OCI artifact tag pattern (ex. '{chartName}-{version}'). Default: `{chartName}-{version}`. This controls the tag applied to the OCI artifact (the part after the colon in `oci://registry/repo:tag`).
- `skip_helm_install`: Skip helm installation (default: false)
- `skip_dependencies`: Skip dependencies update from "Chart.yaml" to dir "charts/" before packaging (default: false)
- `skip_existing`: Skip the chart push if the GithHub release exists
- `skip_oci_login`: Skip the OCI login step (rely on existing credentials)
- `mark_as_latest`: When you set this to `false`, it will mark the created GitHub release not as 'latest'.
- `skip_gh_release`: Skip the GitHub release creation
- `cosign_sign`: Sign each pushed OCI chart with cosign (default: false)
- `cosign_version`: The cosign version to install (default: v3.1.4)
- `cosign_key`: Path or URI to a cosign private key (for example `cosign.key`, `env://COSIGN_PRIVATE_KEY`, or a KMS URI). Leave empty for keyless signing.
- `cosign_key_password`: Password for an encrypted `cosign_key`. It is exported as `COSIGN_PASSWORD` and never passed on the command line.
- `cosign_extra_args`: Additional whitespace-separated arguments appended to `cosign sign` (for example `--tlog-upload=false -a env=prod`).
- `skip_cosign_install`: Skip cosign installation and use an existing `cosign` from `PATH`

### Outputs

- `released_charts`: A comma-separated list of charts that were released on this run. Will be an empty string if no updates were detected, will be unset if `--skip_packaging` is used: in the latter case your custom packaging step is responsible for setting its own outputs if you need them.
- `chart_version`: The version of the most recently generated charts; will be set even if no charts have been updated since the last run.

### Example Workflow

Create a workflow (eg: `.github/workflows/release.yml`):

```yaml
name: Release Charts

on:
  push:
    branches:
      - main

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v3
        with:
          fetch-depth: 0

      - name: Configure Git
        run: |
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"

      - name: Run chart-releaser
        uses: bitdeps/helm-oci-charts-releaser@v0.1.5
        with:
            oci_registry: ghcr.io/username
            oci_username: username
            oci_password: ${{ secrets.GITHUB_TOKEN }}
            github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Custom OCI Tag Pattern

By default, OCI artifacts are tagged as `{chartName}-{version}` (e.g., `ghost-on-kubernetes-1.0.0`). You can customize this:

```yaml
      - name: Run chart-releaser
        uses: sredevopsorg/helm-oci-charts-releaser@v0.0.2
        with:
            oci_registry: ghcr.io/username
            oci_username: username
            oci_password: ${{ secrets.GITHUB_TOKEN }}
            github_token: ${{ secrets.GITHUB_TOKEN }}
            oci_tag_pattern: "{chartName}-v{version}"  # Results in: ghost-on-kubernetes-v1.0.0
```

**Available pattern variables:**
- `{chartName}` - Chart name from Chart.yaml
- `{version}` - Chart version from Chart.yaml

**Examples:**
- `{version}` → `1.0.0` (Helm standard)
- `{chartName}-{version}` → `ghost-on-kubernetes-1.0.0` (default)
- `v{version}` → `v1.0.0`
- `{chartName}-v{version}` → `ghost-on-kubernetes-v1.0.0`

## Signing OCI charts with cosign

Signing is optional and disabled by default. When `cosign_sign` is `true`, every chart is signed **by digest** immediately after `helm push` succeeds and before the GitHub release is created. A signing failure fails the run, so an unsigned chart is never paired with a published release.

The action signs the OCI artifact itself (`<registry>/<path>/<chart>@sha256:...`). Signing the `.tgz` assets attached to the GitHub release is not part of this feature.

### Keyless signing (recommended for GitHub Actions)

Keyless signing uses GitHub's OIDC token, so the workflow needs `id-token: write`:

```yaml
name: Release Charts

on:
  push:
    branches:
      - main

permissions:
  contents: write
  packages: write
  id-token: write   # required for keyless cosign signing

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
        with:
          fetch-depth: 0

      - name: Run chart-releaser
        uses: sredevopsorg/helm-oci-charts-releaser@v0.0.2
        with:
          oci_registry: ghcr.io/username
          oci_username: username
          oci_password: ${{ secrets.GITHUB_TOKEN }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          cosign_sign: true
```

No `cosign_key` is required. Cosign is installed from the pinned `cosign_version` and its SHA-256 is verified against the GitHub release asset digest before use.

### Key-based signing

For environments without an OIDC provider, or to use an existing key pair:

```yaml
      - name: Write cosign key
        run: |
          printf '%s' "${{ secrets.COSIGN_PRIVATE_KEY }}" > cosign.key
          chmod 600 cosign.key

      - name: Run chart-releaser
        uses: sredevopsorg/helm-oci-charts-releaser@v0.0.2
        with:
          oci_registry: ghcr.io/username
          oci_username: username
          oci_password: ${{ secrets.GITHUB_TOKEN }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          cosign_sign: true
          cosign_key: cosign.key
          cosign_key_password: ${{ secrets.COSIGN_PASSWORD }}

      - name: Remove cosign key
        if: always()
        run: rm -f cosign.key
```

You can also avoid the temporary file by setting `COSIGN_PRIVATE_KEY` on the step and passing `cosign_key: env://COSIGN_PRIVATE_KEY`.

### Verifying a signed chart

Signing is pinned to the pushed digest. Use the digest printed by Helm:

```bash
# Keyless (GitHub Actions OIDC)
cosign verify ghcr.io/username/charts/demo@sha256:<digest> \
  --certificate-identity-regexp 'https://github.com/<org>/<repo>/.github/workflows/<workflow>.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Key-based
cosign verify --key cosign.pub ghcr.io/username/charts/demo@sha256:<digest>
```

### Notes

- The action reuses `oci_username` / `oci_password` for cosign. When the action performs the login, the Docker credentials are isolated under `<install_dir>/.docker` so the runner's `~/.docker/config.json` and Helm's registry config are left untouched.
- With `skip_oci_login: true`, no cosign login is performed. The runner must already have Docker credentials that cosign can read (Helm's own registry config is not shared with cosign).
- Cosign v3 stores signatures as OCI 1.1 referring artifacts by default. Pin `cosign_version: v2.6.2` if your registry or verification tooling requires legacy `.sig` tags.
- Use `cosign_extra_args` for registry-specific flags such as `--allow-http-registry`, `--tlog-upload=false`, or annotations (`-a key=value`).
- `--skip-cosign-install` is available when cosign is preinstalled in the runner image.

This uses under the hood uses Helm and gh cli (which is available to actions). Helm is used to login and push charts into an OCI registry, while gh cli is used to create and update the repository releases.

It does this – during every push to `main` – by checking each chart in your project, and whenever there's a new chart version, creates a corresponding [GitHub release](https://help.github.com/en/github/administering-a-repository/about-releases) named for the chart version, adds Helm chart artifacts to the release, and pushes the chart into the given OCI registry.

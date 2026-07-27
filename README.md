# tgbyte/builder

A rootless, multi-arch container image builder for GitLab CI. It ships the
`tgbyte/builder` image (based on `moby/buildkit` rootless) together with a
reusable GitLab CI pipeline that **scans, builds, and publishes** your Docker
images — and optionally your Helm charts — from a single `include:`.

## Features

- **Rootless builds** — BuildKit via `buildctl-daemonless.sh`; no Docker daemon, no `--privileged`.
- **Single multi-arch build** — `MULTIARCH=1` produces a `linux/amd64,linux/arm64` manifest list in one build+push, with no per-arch jobs to stitch together.
- **Built-in vulnerability scanning** — Trivy scans the image; the pipeline can report or gate on findings.
- **Skip-if-unchanged** — a build is skipped when its tag already exists in the registry and isn't flagged vulnerable.
- **Helm charts** — packages and pushes an OCI Helm chart when a `charts/<name>` directory is present.
- **Harbor proxy-cache aware** — optionally routes base-image and Trivy-DB pulls through a Harbor proxy cache to avoid upstream rate limits.
- **Batteries included** — `git`, `helm`, `skopeo`, `trivy`, `jq`, `node`/`npm`, `python3`/`pip`, `make`, `httpie`, and more.

## Quick start (downstream project)

Add a `Dockerfile` to your repository, then include the pipeline:

```yaml
# .gitlab-ci.yml
include:
  - project: 'docker/builder'
    file: '/templates/.gitlab-ci.yml'

variables:
  MULTIARCH: 1        # build linux/amd64 + linux/arm64 (omit for amd64 only)
```

On the default branch this runs three stages — **scan → build → verify** — and
pushes the resulting image to your registry. Jobs run inside the
`tgbyte/builder` image on runners tagged `rootless`.

Image name and tag are derived automatically:

- **Image** — the GitLab Container Registry (`$CI_REGISTRY_IMAGE`) when available, otherwise `tgbyte/<project>` on Docker Hub.
- **Tag** — `latest` on the default branch, a sanitized branch name elsewhere, or the contents of a `.version` file when present.

## Pipeline

The template (`templates/.gitlab-ci.yml`) defines:

| Stage | Job | What it does |
|-------|-----|--------------|
| `scan` | `trivy` | Pre-build scan of the currently published image to decide whether a rebuild must be forced. Runs on the default branch for non-`push` pipelines (e.g. scheduled security re-scans); `allow_failure: true`. Skipped when `SKIP_TRIVY=1`. |
| `build` | `build` | Builds and pushes the image. Skipped when the tag already exists and isn't flagged vulnerable or forced. |
| `verify` | `trivy-result` | Re-scans the freshly published image and writes `.trivy-report.json`. Skipped when `SKIP_TRIVY=1`. |

## Configuration

All variables are optional unless noted.

| Variable | Default | Purpose |
|---|---|---|
| `IMAGE` | auto (registry / Docker Hub) | Target image repository |
| `TAG` | `latest` / branch / `.version` | Image tag |
| `MULTIARCH` | unset | `1` → build `linux/amd64,linux/arm64` |
| `PLATFORMS` | derived from `MULTIARCH` | Override target platforms directly |
| `DOCKERFILE` | `<BUILD_DIR>/Dockerfile` | Dockerfile path |
| `BUILD_DIR` | `.` | Build context |
| `SKIP_DOCKER_PUSH` | unset | Build only, don't push |
| `FORCE` | unset | Build even if the tag already exists |
| `SKIP_TRIVY` | unset | `1` → skip both Trivy jobs (pre-build scan and post-build verify scan); the missing pre-build scan then does not force a rebuild |
| `TRIVY_SEVERITY` | `HIGH,CRITICAL,MEDIUM` | Severities that fail the scan |
| `HARBOR_REGISTRY` | unset | Route pulls through a Harbor proxy cache |
| `DOCKER_HUB_USER` / `DOCKER_HUB_PASSWORD` | — | Docker Hub auth (non-GitLab registries) |

GitLab Container Registry auth is picked up automatically from the
CI-provided `CI_REGISTRY_*` (or `CI_DEPLOY_*`) credentials. Never hardcode
secrets — pass them as CI/CD variables.

Advanced: `BUILD_IMAGE_SCRIPT` and `TRIVY_SCRIPT` let a project swap in its own
wrapper around the defaults (this repo uses that to build itself).

## Scripts (`bin/`)

- `build-image.sh` — build and push the image (multi-arch via BuildKit); also builds a Helm chart when one is present.
- `build-helm.sh` — package and push an OCI Helm chart from `charts/<name>`.
- `add-tag.sh <tag…>` — copy the built image to additional tags (`skopeo copy --all`).
- `check-tag.sh <image:tag>` — exit `0` if the tag exists in the registry.
- `trivy.sh` — scan `$FULL_IMAGE` and write `.trivy-*` markers / report.

Shared logic — environment discovery, registry auth, tag/version resolution,
Harbor `FROM` rewriting — lives in `share/build-functions.sh`, which every
script sources.

## Helm charts

When a `charts/<project-name>` directory exists, the build also packages the
chart and pushes it as an OCI artifact to `oci://<IMAGE>/helm` (chart version
`0.0.0-<short-sha>`, app version = the image `TAG`).

## Harbor proxy-cache (optional)

Set `HARBOR_REGISTRY` (e.g. `harbor.example.io`) to route `FROM` base images
and the Trivy vulnerability / Java DBs through Harbor proxy-cache projects,
avoiding upstream rate limits and outages. Unset is a no-op (pull direct from
upstream). See [AGENTS.md](AGENTS.md#harbor-proxy-cache-routing) for the
routing map and details.

## The builder image

Based on `moby/buildkit:v<version>-rootless` (Alpine), runs as UID `1000`, and
bundles common build/release tooling. Multi-arch builds require QEMU/binfmt
handlers registered on the runner node.

The BuildKit version is pinned by `ARG BUILDKIT_VERSION` in
[`Dockerfile`](Dockerfile) (kept current by Renovate) and the image is
published as a rolling `tgbyte/builder:latest`. On startup it prints a banner
identifying its tag and the git commit it was built from.

## Contributing

See [AGENTS.md](AGENTS.md) for repository layout, coding style, and
conventions. This repo builds itself with its own pipeline; there are no unit
tests.

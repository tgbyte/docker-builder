# Repository Guidelines

## Project Structure & Module Organization
- `bin/`: Bash entrypoints for build, tagging, and security scan workflows.
- `share/build-functions.sh`: Shared helpers and environment discovery used by all scripts.
- `Dockerfile`: Image definition for the builder container (installs tooling like buildkit, helm, trivy).
- `templates/`: Reusable GitLab CI pipeline (`.gitlab-ci.yml`) included by downstream projects.

## Build, Test, and Development Commands
- `bin/build-image.sh`: Build and optionally push a Docker image. With `MULTIARCH=1` (the default in CI) it performs a single multi-platform build+push via rootless BuildKit and produces the manifest list directly. Example: `TAG=1.2.3 IMAGE=org/app bin/build-image.sh`.
- `bin/build-helm.sh`: Package and optionally push a Helm chart from `charts/<name>`.
- `bin/add-tag.sh <tag...>`: Add extra tags to an existing image and push them.
- `bin/check-tag.sh <image:tag>`: Exit success if the tag exists in the registry.
- `bin/trivy.sh`: Run a vulnerability scan on `${FULL_IMAGE}` and write `.trivy-*` markers.

## Coding Style & Naming Conventions
- Bash scripts with `#!/bin/bash` and `set -e` (or `-ex` for verbose runs).
- Indentation: 2 spaces, no tabs.
- Function names are `lower_snake_case`; environment variables are `UPPER_SNAKE_CASE`.
- Script filenames use kebab case (e.g., `build-image.sh`).

## Testing Guidelines
- No automated unit tests in this repo.

## Commit & Pull Request Guidelines
- Commit messages are short, sentence-case, and descriptive (e.g., “Improve docker login security…”).
- PRs should include: purpose, affected scripts, and any required environment variables.
- If a change impacts build output, mention the exact command used and key flags.

## Harbor Proxy-Cache Routing
- Set `HARBOR_REGISTRY` (e.g. `harbor.tgbyte.io`) to route external image/DB pulls through Harbor proxy-cache projects, avoiding upstream rate limits and outages. Unset is a no-op (pull direct from upstream). The rootless CI runner sets it automatically.
- **Base images:** `harbor_rewrite_dockerfile` (`share/build-functions.sh`) rewrites `FROM` lines via `share/harbor-rewrite.awk`, mapping each upstream registry to its proxy-cache project (`docker.io→dockerhub`, `ghcr.io→ghcr`, `quay.io→quay`, `registry.k8s.io→k8s`, …). Left untouched: `scratch`, prior build stages, refs already on `HARBOR_REGISTRY`, dynamic (`$var`) hosts, and unmapped registries.
- **Trivy DB:** `bin/trivy.sh` routes the vulnerability DB and Java DB through the `ghcr` proxy-cache project (`${HARBOR_REGISTRY}/ghcr/aquasecurity/trivy-db:2` and `trivy-java-db:1`) when `HARBOR_REGISTRY` is set; otherwise the vuln DB falls back to the `public.ecr.aws` mirror and the Java DB to trivy's default. An explicit `TRIVY_DB_REPOSITORY` / `TRIVY_JAVA_DB_REPOSITORY` overrides both.
- The route map must match the proxy-cache projects actually configured in Harbor; the Trivy DBs are OCI artifacts pulled anonymously.

## Security & Configuration Tips
- Registry credentials are expected via env vars (`DOCKER_HUB_USER`, `CI_REGISTRY_USER`, etc.); do not hardcode secrets.
- Builds run rootless (no `--privileged`); registry auth is written to `config.json` by `registry_auth`.

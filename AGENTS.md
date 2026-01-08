# Repository Guidelines

## Project Structure & Module Organization
- `bin/`: Bash entrypoints for build, tagging, manifest, and security scan workflows.
- `share/build-functions.sh`: Shared helpers and environment discovery used by all scripts.
- `Dockerfile`: Image definition for the builder container (installs tooling like docker, helm, trivy).
- `templates/`: Reserved for future scaffolding; currently empty.

## Build, Test, and Development Commands
- `bin/build-image.sh`: Build and optionally push a Docker image. Example: `TAG=1.2.3 IMAGE=org/app bin/build-image.sh`.
- `bin/build-manifest.sh`: Create/push a multi-arch manifest after per-arch builds. Requires `MULTIARCH=1`.
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

## Security & Configuration Tips
- Registry credentials are expected via env vars (`DOCKER_HUB_USER`, `CI_REGISTRY_USER`, etc.); do not hardcode secrets.

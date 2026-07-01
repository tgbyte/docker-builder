# Rootless BuildKit Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the DinD-based image builder with embedded rootless BuildKit so CI build jobs no longer require `--privileged`.

**Architecture:** The `tgbyte/builder` image is rebased on `moby/buildkit:*-rootless`; `bin/build-image.sh` builds via `buildctl-daemonless.sh` (an ephemeral rootless `buildkitd` per job) instead of a Docker daemon. Multi-arch collapses into one multi-platform build that pushes the manifest list directly, so `build-manifest.sh` and the per-arch jobs are removed. Registry auth becomes a hand-written `config.json` (no daemon to `docker login`); skopeo/trivy/helm/buildctl all read it. Node-level QEMU handlers move to a one-time privileged DaemonSet. See spec: `docs/superpowers/specs/2026-07-01-rootless-buildkit-migration-design.md`.

**Tech Stack:** GitLab CI (Kubernetes executor), BuildKit (`buildctl-daemonless.sh`), Alpine/apk, bash, skopeo, trivy, helm, jq, Renovate.

## Global Constraints

- **No `--privileged`** in any build job. (Privileged is permitted *only* in the one-time node binfmt DaemonSet — Task 9.)
- **Base image:** `moby/buildkit:v0.31.0-rootless`, referenced via `ARG BUILDKIT_VERSION=v0.31.0` and `FROM moby/buildkit:${BUILDKIT_VERSION}-rootless`.
- **Rootless runtime:** builder image runs as uid/gid **1000**; buildkitd started via `buildctl-daemonless.sh` with env `BUILDKITD_FLAGS=--oci-worker-no-process-sandbox`.
- **Harbor proxy-cache pulls are anonymous** — `config.json` carries push-registry creds only, no Harbor entry.
- **Multi-arch:** single job. `PLATFORMS=linux/amd64,linux/arm64` when `MULTIARCH=1`, else `linux/amd64`.
- **Dropped:** `--squash` / `DOCKER_SQUASH`; per-arch jobs; `bin/build-manifest.sh`; the `DOCKER_VERSION` build-arg.
- **Shell style (from `AGENTS.md`):** `#!/bin/bash` with `set -e` (or `-ex`); 2-space indent, no tabs; functions `lower_snake_case`; env vars `UPPER_SNAKE_CASE`; filenames kebab-case. All shell must pass `shellcheck`.
- **No unit-test framework exists** in this repo (per `AGENTS.md`). Each task's "test" is a concrete verification command (shellcheck / `bash -n` / config validators / a live smoke check) with expected output. Infra tasks (8–10) are verified in a pipeline/cluster, not locally.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `share/build-functions.sh` | Shared env discovery + `registry_auth`, `PLATFORMS`, `BUILD_OPTS` | Modify |
| `bin/build-image.sh` | Build+push image via buildctl | Rewrite |
| `bin/build-manifest.sh` | (obsolete) | Delete |
| `bin/add-tag.sh` | Add tags to a pushed image | Modify (skopeo) |
| `bin/check-tag.sh` | Registry tag existence check | Modify (auth swap) |
| `bin/trivy.sh` | Vuln scan | Modify (auth swap) |
| `bin/build-helm.sh` | Package+push helm chart | Modify (auth swap) |
| `templates/.gitlab-ci.yml` | Reusable pipeline | Rewrite (collapse jobs) |
| `.gitlab-ci.yml` | This repo's pipeline vars | Modify |
| `Dockerfile` | Builder image | Rewrite (base + tooling) |
| `renovate.json` | Base-image bump automation | Create |
| `AGENTS.md` | Contributor docs | Modify |
| Runner `config.toml` (infra, not in repo) | build-job pod security context | Modify |
| `binfmt` DaemonSet (infra, not in repo) | node QEMU registration | Create |

---

## Task 1: Rework `share/build-functions.sh` (auth + platform + build-opts)

**Files:**
- Modify: `share/build-functions.sh`

**Interfaces:**
- Produces (consumed by all later script tasks):
  - `registry_auth` — no args. Writes `${DOCKER_CONFIG}/config.json` with base64 push-registry auth; runs `helm registry login` when building a chart; exports `DOCKER_CONFIG` and `REGISTRY_AUTH_FILE`; idempotent via the `.docker-logged-in` marker.
  - `PLATFORMS` — comma-separated platform list (e.g. `linux/amd64,linux/arm64`).
  - `BUILD_OPTS` — bash array of `--opt build-arg:KEY=VALUE` pairs derived from `ARG_*` env vars.
  - `FULL_IMAGE` — `${IMAGE}:${TAG}` (unchanged). `FULL_IMAGE_ARCH` is removed.

- [ ] **Step 1: Replace the three `docker login` functions with `registry_auth`**

Replace lines 8–49 (`docker_login`, `gitlab_login`, `docker_hub_login`) with:

```bash
function registry_auth {
  if [ -e .docker-logged-in ]; then
    return 0
  fi

  DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
  REGISTRY_AUTH_FILE="${DOCKER_CONFIG}/config.json"
  export DOCKER_CONFIG REGISTRY_AUTH_FILE
  mkdir -p "${DOCKER_CONFIG}"

  if [ -n "$CI_REGISTRY_IMAGE" ]; then
    registry_auth_gitlab
  else
    registry_auth_docker_hub
  fi
}

# write_auth <registry-host> <username> <password>
function write_auth {
  local reg="$1" user="$2" pass="$3"
  local cfg="${REGISTRY_AUTH_FILE}"
  local token
  token=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
  if [ -s "$cfg" ]; then
    jq --arg reg "$reg" --arg auth "$token" \
      '.auths[$reg] = {auth: $auth}' "$cfg" > "${cfg}.tmp"
  else
    jq -n --arg reg "$reg" --arg auth "$token" \
      '{auths: {($reg): {auth: $auth}}}' > "${cfg}.tmp"
  fi
  mv "${cfg}.tmp" "$cfg"
}

function registry_auth_gitlab {
  if [ -n "$CI_REGISTRY_USER" ]; then
    echo "Detected GitLab Container registry - writing auth for CI_REGISTRY_USER..."
    write_auth "$CI_REGISTRY" "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD"
    if [ -n "$BUILD_HELM_CHART" ]; then
      helm registry login "$CI_REGISTRY" \
        --username "$CI_REGISTRY_USER" \
        --password "$CI_REGISTRY_PASSWORD"
    fi
  elif [ -n "$CI_DEPLOY_USER" ]; then
    echo "Detected GitLab Container registry - writing auth for CI_DEPLOY_USER..."
    write_auth "$CI_REGISTRY" "$CI_DEPLOY_USER" "$CI_DEPLOY_PASSWORD"
    helm registry login "$CI_REGISTRY" \
      --username "$CI_DEPLOY_USER" \
      --password "$CI_DEPLOY_PASSWORD"
  else
    echo "No credentials defined to login to GitLab Container Registry. See https://docs.gitlab.com/ee/ci/docker/using_docker_build.html#authenticating-to-the-container-registry for options."
    exit 1
  fi
  touch .docker-logged-in
}

function registry_auth_docker_hub {
  if [ -n "$DOCKER_HUB_USER" ]; then
    echo "Detected Docker Hub - writing auth for DOCKER_HUB_USER..."
    write_auth "https://index.docker.io/v1/" "$DOCKER_HUB_USER" "$DOCKER_HUB_PASSWORD"
    touch .docker-logged-in
  fi
}
```

- [ ] **Step 2: Replace ARCH/PLATFORM detection with `PLATFORMS`**

Replace lines 128–134 (the `docker version`-based ARCH/PLATFORM block):

```bash
if [ -z "$ARCH" ]; then
  ARCH=$(docker version | grep OS/Arch | head -1 | sed s,.\*/,,)
fi

if [ -z "$PLATFORM" ]; then
  PLATFORM=${ARCH}
fi
```

with:

```bash
if [ -z "$PLATFORMS" ]; then
  if [ "$MULTIARCH" == "1" ]; then
    PLATFORMS="linux/amd64,linux/arm64"
  else
    PLATFORMS="linux/amd64"
  fi
fi
```

- [ ] **Step 3: Remove the per-arch `FULL_IMAGE_ARCH` and convert build-args to `BUILD_OPTS`**

Delete the `FULL_IMAGE_ARCH` line (line 157):

```bash
# shellcheck disable=SC2034
FULL_IMAGE_ARCH="$IMAGE":"$TAG"-"$ARCH"
```

Replace the `BUILD_ARGS` block (lines 168–172):

```bash
declare -a BUILD_ARGS
while IFS='=' read -r -d '' n v; do
    BUILD_ARGS+=("--build-arg")
    BUILD_ARGS+=("$n=$v")
done < <(env -0 | grep -z '^ARG_' | sed -rze 's/^ARG_//')
```

with:

```bash
declare -a BUILD_OPTS
while IFS='=' read -r -d '' n v; do
    BUILD_OPTS+=("--opt")
    BUILD_OPTS+=("build-arg:$n=$v")
done < <(env -0 | grep -z '^ARG_' | sed -rze 's/^ARG_//')
```

In the settings echo block (lines 186–201) change `echo BUILD_ARGS: "${BUILD_ARGS[@]}"` to `echo BUILD_OPTS: "${BUILD_OPTS[@]}"` and add a `echo "PLATFORMS: $PLATFORMS"` line.

- [ ] **Step 4: Lint**

Run: `shellcheck share/build-functions.sh`
Expected: exits 0, no warnings (existing `# shellcheck disable=` directives preserved).

- [ ] **Step 5: Functional smoke test of `registry_auth` (Docker Hub path)**

Run:
```bash
docker run --rm -v "$PWD:/w" -w /w alpine:3.20 sh -c '
  apk add --no-cache bash jq coreutils >/dev/null &&
  export HOME=/tmp CI_REGISTRY_IMAGE= DOCKER_HUB_USER=u DOCKER_HUB_PASSWORD=p &&
  bash -c "source share/build-functions.sh >/dev/null; registry_auth; cat \$DOCKER_CONFIG/config.json"
'
```
Expected: JSON with `"auths": {"https://index.docker.io/v1/": {"auth": "dTpw"}}` (`dTpw` == base64 of `u:p`).
Cleanup: `rm -f .docker-logged-in`

- [ ] **Step 6: Commit**

```bash
git add share/build-functions.sh
git commit -m "Replace docker_login with config.json registry_auth; add PLATFORMS/BUILD_OPTS"
```

---

## Task 2: Rewrite `bin/build-image.sh` to buildctl-daemonless

**Files:**
- Modify: `bin/build-image.sh`

**Interfaces:**
- Consumes from Task 1: `registry_auth`, `exit_if_image_present`, `harbor_rewrite_dockerfile`, `PLATFORMS`, `BUILD_OPTS`, `FULL_IMAGE`, `DOCKERFILE`, `BUILD_DIR`, `SKIP_DOCKER_PUSH`, `BUILD_HELM_CHART`.
- Produces: pushes `${FULL_IMAGE}` as a manifest list; writes `results/metadata.json` (contains `containerimage.digest`).

**Design notes (why no `--no-cache`/`--pull`):** `buildctl-daemonless.sh` starts a fresh `buildkitd` with an empty state dir inside the ephemeral job pod, so every build already starts cache-cold and pulls base images fresh — the old `--no-cache --pull` flags are redundant. The Harbor FROM-rewrite still runs and repoints `DOCKERFILE` at the processed copy.

- [ ] **Step 1: Replace the entire file**

```bash
#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_auth
exit_if_image_present

harbor_rewrite_dockerfile

DOCKERFILE_DIR="$(dirname "${DOCKERFILE}")"
DOCKERFILE_NAME="$(basename "${DOCKERFILE}")"

OUTPUT="type=image,name=${FULL_IMAGE}"
if [ -z "${SKIP_DOCKER_PUSH}" ]; then
  OUTPUT="${OUTPUT},push=true"
fi

mkdir -p results

echo "Building image ${FULL_IMAGE} for platforms ${PLATFORMS}..."
buildctl-daemonless.sh build \
  --frontend dockerfile.v0 \
  --local context="${BUILD_DIR}" \
  --local dockerfile="${DOCKERFILE_DIR}" \
  --opt filename="${DOCKERFILE_NAME}" \
  --opt platform="${PLATFORMS}" \
  "${BUILD_OPTS[@]}" \
  --output "${OUTPUT}" \
  --metadata-file results/metadata.json

if [ -n "${SKIP_DOCKER_PUSH}" ]; then
  echo "SKIP_DOCKER_PUSH set - image built but not pushed."
else
  DIGEST=$(jq -r '."containerimage.digest" // empty' results/metadata.json)
  echo "Pushed ${FULL_IMAGE}@${DIGEST}"
fi

if [ -n "$BUILD_HELM_CHART" ]; then
  build-helm.sh
fi
```

- [ ] **Step 2: Lint**

Run: `shellcheck bin/build-image.sh`
Expected: exits 0.

- [ ] **Step 3: Local rootless build smoke test (no push)**

Run (uses the pinned base directly; needs the seccomp/apparmor opts locally):
```bash
printf 'FROM alpine:3.20\nRUN echo hi\n' > /tmp/Dockerfile.smoke
docker run --rm \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -e BUILDKITD_FLAGS=--oci-worker-no-process-sandbox \
  -v /tmp:/w -w /w \
  --entrypoint buildctl-daemonless.sh \
  moby/buildkit:v0.31.0-rootless \
  build --frontend dockerfile.v0 --local context=/w --local dockerfile=/w \
    --opt filename=Dockerfile.smoke --opt platform=linux/amd64,linux/arm64 \
    --output type=image,name=example.com/smoke,push=false
```
Expected: build completes for both platforms, ending `exporting to image ... DONE` with no privileged and no daemon. (This validates the `buildctl` invocation shape; it does not push.)

- [ ] **Step 4: Commit**

```bash
git add bin/build-image.sh
git commit -m "Build via buildctl-daemonless (rootless), single multi-platform push"
```

---

## Task 3: Convert `bin/add-tag.sh` to skopeo copy

**Files:**
- Modify: `bin/add-tag.sh`

**Interfaces:**
- Consumes from Task 1: `registry_auth`, `REGISTRY_AUTH_FILE`, `IMAGE`, `FULL_IMAGE`.

- [ ] **Step 1: Replace the docker tag/push loop**

Replace the whole file with:

```bash
#!/bin/bash

set -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_auth

for NEW_TAG in "$@"; do
  NEW_FULL_IMAGE="${IMAGE}:${NEW_TAG}"
  echo "Copying ${FULL_IMAGE} -> ${NEW_FULL_IMAGE}..."
  skopeo copy --all "docker://${FULL_IMAGE}" "docker://${NEW_FULL_IMAGE}"
done
```

(`--all` copies the full manifest list, which `docker tag`+`push` could not do cleanly. skopeo reads `REGISTRY_AUTH_FILE`, exported by `registry_auth`.)

- [ ] **Step 2: Lint**

Run: `shellcheck bin/add-tag.sh`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add bin/add-tag.sh
git commit -m "add-tag: use skopeo copy --all instead of docker tag/push"
```

---

## Task 4: Swap `docker_login` → `registry_auth` in check-tag / trivy / build-helm

**Files:**
- Modify: `bin/check-tag.sh:8`
- Modify: `bin/trivy.sh:6`
- Modify: `bin/build-helm.sh:8`

**Interfaces:**
- Consumes from Task 1: `registry_auth` (replaces the removed `docker_login`).

- [ ] **Step 1: Replace the call in each file**

In `bin/check-tag.sh`, `bin/trivy.sh`, and `bin/build-helm.sh`, change the single line `docker_login` to `registry_auth`. No other changes (check-tag already uses `skopeo inspect`; trivy already scans the registry image; build-helm already uses `helm`).

- [ ] **Step 2: Verify no stale `docker_login` references remain**

Run: `grep -rn 'docker_login' bin share`
Expected: no output.

- [ ] **Step 3: Lint**

Run: `shellcheck bin/check-tag.sh bin/trivy.sh bin/build-helm.sh`
Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add bin/check-tag.sh bin/trivy.sh bin/build-helm.sh
git commit -m "Use registry_auth in check-tag, trivy, build-helm"
```

---

## Task 5: Delete build-manifest.sh; collapse CI pipeline; update docs

**Files:**
- Delete: `bin/build-manifest.sh`
- Rewrite: `templates/.gitlab-ci.yml`
- Modify: `.gitlab-ci.yml`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: the new single `build` job runs `bin/build-image.sh` (Task 2).

- [ ] **Step 1: Delete the obsolete manifest script**

Run: `git rm bin/build-manifest.sh`

- [ ] **Step 2: Replace `templates/.gitlab-ci.yml`**

```yaml
cache:
  paths:
    - .trivy/

stages:
  - scan
  - build
  - verify

trivy:
  stage: scan
  script:
    - ${TRIVY_SCRIPT:-trivy.sh}
  allow_failure: true
  artifacts:
    expire_in: 1 day
    paths:
      - .trivy-run
      - .trivy-vulnerable
      - .version
    when: always
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE != "push"

build:
  stage: build
  script:
    - ${BUILD_IMAGE_SCRIPT:-build-image.sh}
  variables:
    BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
  artifacts:
    expire_in: 1 day
    paths:
      - results/
      - '**/results/'
      - .version
  needs:
    - job: trivy
      optional: true
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

trivy-result:
  stage: verify
  script:
    - ${TRIVY_SCRIPT:-trivy.sh}
  artifacts:
    expire_in: 1 month
    paths:
      - .trivy-report.json
    when: always
  needs:
    - job: trivy
      optional: true
    - job: build
  variables:
    TRIVY_DISABLE_VEX_NOTICE: 1
    TRIVY_REPORT_JSON: 1
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $SKIP_TRIVY != "1"

variables:
  TRIVY_DISABLE_VEX_NOTICE: '1'
```

(Removes `build-amd64`, `build-arm64`, `build-manifest`, and the `-multiarch` trivy-result variant. `MULTIARCH` no longer gates jobs — it only selects `PLATFORMS` inside `build-image.sh`.)

- [ ] **Step 3: Update `.gitlab-ci.yml` (this repo)**

Remove the `BUILD_MANIFEST_SCRIPT: bin/build-manifest.sh` line (line 9). Keep `MULTIARCH: 1` (now: build both platforms in the one job) and the `TRIVY_*` vars. Resulting `variables:` block:

```yaml
variables:
  BUILD_IMAGE_SCRIPT: bin/build-image.sh
  MULTIARCH: 1
  TRIVY_SCRIPT: bin/trivy.sh
  TRIVY_SEVERITY: CRITICAL
  SKIP_TRIVY: 1
```

- [ ] **Step 4: Update `AGENTS.md`**

In the "Build, Test, and Development Commands" section: delete the `bin/build-manifest.sh` bullet; change the `bin/build-image.sh` bullet to note it now performs a single multi-platform (`MULTIARCH=1`) build+push via rootless BuildKit and produces the manifest list directly. In "Security & Configuration Tips", add: "Builds run rootless (no `--privileged`); registry auth is written to `config.json` by `registry_auth`."

- [ ] **Step 5: Validate the pipeline YAML**

Run (requires `glab` authenticated to gitlab.tgbyte.de; otherwise run in an MR and read the lint result in the UI):
```bash
glab ci lint --dry-run templates/.gitlab-ci.yml
```
Expected: `✓ CI/CD YAML is valid` (or the GitLab UI "Pipeline syntax is correct").

- [ ] **Step 6: Commit**

```bash
git add -A templates/.gitlab-ci.yml .gitlab-ci.yml AGENTS.md
git commit -m "Collapse multi-arch into one buildctl job; drop build-manifest"
```

---

## Task 6: Rewrite `Dockerfile` (buildkit base + tooling)

**Files:**
- Rewrite: `Dockerfile`

**Interfaces:**
- Produces: `tgbyte/builder` image containing `buildkitd`/`buildctl`/`buildctl-daemonless.sh` (from base) plus bash, coreutils, git, grep, helm, httpie, jq, make, node/npm, openssh-client, patch, python3, sed, skopeo, trivy; runs as uid 1000; the `bin/` and `share/` scripts on PATH.

- [ ] **Step 1: Replace the entire `Dockerfile`**

```dockerfile
ARG BUILDKIT_VERSION=v0.31.0

# renovate: datasource=docker depName=moby/buildkit versioning=docker
FROM moby/buildkit:${BUILDKIT_VERSION}-rootless

ARG GIT_COMMIT
ARG GIT_COMMIT_DATE

ENV LANG=C.UTF-8

# Reset the buildkitd entrypoint so GitLab CI can inject its shell script.
ENTRYPOINT []

USER root
RUN set -x \
    && apk upgrade --no-cache \
    && apk add --no-cache \
         bash \
         coreutils \
         curl \
         git \
         grep \
         helm \
         httpie \
         jq \
         make \
         nodejs \
         npm \
         openssh-client \
         patch \
         py3-pip \
         python3 \
         sed \
    && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
         skopeo \
    && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing \
         trivy

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/

RUN set -x \
    && mkdir -p /usr/local/etc \
    && echo $GIT_COMMIT > /usr/local/etc/.builder-commit \
    && echo $GIT_COMMIT_DATE > /usr/local/etc/.builder-commit-date

USER 1000
```

- [ ] **Step 2: Build the image (bootstrap, rootless)**

Because the old published `tgbyte/builder` is DinD-based, build the new image with the base directly (this is also the Task 10 bootstrap mechanism):
```bash
docker run --rm \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -e BUILDKITD_FLAGS=--oci-worker-no-process-sandbox \
  -v "$PWD:/w" -w /w \
  --entrypoint buildctl-daemonless.sh \
  moby/buildkit:v0.31.0-rootless \
  build --frontend dockerfile.v0 --local context=/w --local dockerfile=/w \
    --opt build-arg:GIT_COMMIT="$(git rev-parse --short HEAD)" \
    --opt build-arg:GIT_COMMIT_DATE="$(git show -s --format=%cd)" \
    --output type=docker,name=tgbyte/builder:candidate | docker load
```
Expected: `Loaded image: tgbyte/builder:candidate`.

- [ ] **Step 3: Verify tooling and non-root user in the built image**

Run:
```bash
docker run --rm --entrypoint sh tgbyte/builder:candidate -c \
  'id -u; buildctl --version; helm version --short; trivy --version | head -1; skopeo --version; command -v buildctl-daemonless.sh'
```
Expected: first line `1000`; then non-empty version strings for buildctl, helm, trivy, skopeo; and a path for `buildctl-daemonless.sh`.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "Rebase builder image on moby/buildkit rootless; drop docker base"
```

---

## Task 7: Add `renovate.json`

**Files:**
- Create: `renovate.json`

**Interfaces:**
- Produces: Renovate config that bumps `ARG BUILDKIT_VERSION` in `Dockerfile`.

- [ ] **Step 1: Create `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/(^|/)Dockerfile$/"],
      "matchStrings": ["ARG BUILDKIT_VERSION=(?<currentValue>\\S+)"],
      "datasourceTemplate": "docker",
      "depNameTemplate": "moby/buildkit",
      "versioningTemplate": "docker"
    }
  ]
}
```

(The `-rootless` suffix lives outside the ARG, so the regex captures only `v0.31.0`; `moby/buildkit` publishes matching `vX.Y.Z` tags, so `versioning=docker` bumps correctly and the Dockerfile re-appends `-rootless`.)

- [ ] **Step 2: Validate the config**

Run: `npx --yes --package renovate -- renovate-config-validator renovate.json`
Expected: `Config validated successfully` (no errors).

- [ ] **Step 3: Verify the regex matches the Dockerfile ARG**

Run: `grep -oP 'ARG BUILDKIT_VERSION=\K\S+' Dockerfile`
Expected: `v0.31.0`

- [ ] **Step 4: Commit**

```bash
git add renovate.json
git commit -m "Add Renovate customManager to bump BUILDKIT_VERSION"
```

---

## Task 8: Runner `config.toml` — build-job pod security context (infra)

**Files:**
- Modify: GitLab Runner `config.toml` (lives on the runner / Helm values — **not** in this repo).
- Modify: `templates/.gitlab-ci.yml` — add a runner `tag` to the `build` job.

**Interfaces:**
- Produces: a Kubernetes runner that runs the `build` job as uid 1000, seccomp `Unconfined`, AppArmor `unconfined`, **no privileged**. Other jobs stay on the default (confined) runner.

- [ ] **Step 1: Add a dedicated rootless-buildkit runner block**

Add to `config.toml` (values reflect a K8s runner ≥ current; adjust the seccomp/apparmor keys to your runner + Kubernetes version — seccomp via `build_container_security_context.seccomp_profile` on recent runners, AppArmor via pod annotation shown below):

```toml
[[runners]]
  name = "buildkit-rootless"
  url = "https://gitlab.tgbyte.de"
  token = "REDACTED"
  executor = "kubernetes"
  [runners.kubernetes]
    image = "tgbyte/builder"
    privileged = false
    [runners.kubernetes.pod_security_context]
      run_as_non_root = true
      run_as_user = 1000
      run_as_group = 1000
      fs_group = 1000
    [runners.kubernetes.build_container_security_context]
      [runners.kubernetes.build_container_security_context.seccomp_profile]
        type = "Unconfined"
    [runners.kubernetes.pod_annotations]
      "container.apparmor.security.beta.kubernetes.io/build" = "unconfined"
```

(The AppArmor annotation targets the container named `build`, which is the GitLab job container. On Kubernetes ≥ 1.30 you may instead set `appArmorProfile.type = "Unconfined"` in `build_container_security_context`. Advanced alternative, if your cluster supports user namespaces: drop the seccomp/apparmor relaxation and set `hostUsers = false` via `pod_spec` instead.)

- [ ] **Step 2: Register the runner tag on the build job**

In `templates/.gitlab-ci.yml`, add to the `build` job:

```yaml
  tags:
    - buildkit
```

and register the new runner with the `buildkit` tag. Commit the YAML change:
```bash
git add templates/.gitlab-ci.yml
git commit -m "Route build job to the buildkit-rootless runner"
```

- [ ] **Step 3: Verify the build pod has no privileged and the expected context**

Trigger a pipeline (or a throwaway job on the `buildkit` tag) and, while it runs:
```bash
kubectl get pod -l 'job.gitlab.com/...' -o jsonpath='{.items[0].spec.containers[?(@.name=="build")].securityContext}{"\n"}'
kubectl get pod <build-pod> -o jsonpath='{.spec.containers[?(@.name=="build")].securityContext.privileged}{"\n"}'
```
Expected: securityContext shows `runAsUser:1000` and seccompProfile `Unconfined`; the `privileged` query prints empty/`false`.

---

## Task 9: Node binfmt DaemonSet (infra)

**Files:**
- Create: `binfmt-daemonset.yaml` (applied to the cluster; keep it in your infra repo, not necessarily this one).

**Interfaces:**
- Produces: QEMU `binfmt_misc` handlers registered on every node so rootless BuildKit can emulate arm64. This is the **only** place `privileged` remains.

- [ ] **Step 1: Create the DaemonSet manifest**

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: binfmt
  namespace: kube-system
  labels:
    app: binfmt
spec:
  selector:
    matchLabels:
      app: binfmt
  template:
    metadata:
      labels:
        app: binfmt
    spec:
      initContainers:
        - name: binfmt-install
          image: tonistiigi/binfmt:latest
          args: ["--install", "arm64"]
          securityContext:
            privileged: true
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 10m
              memory: 8Mi
```

(`tonistiigi/binfmt --install` registers handlers with the `F` fix-binary flag, so the QEMU interpreter is resident on the host and works inside rootless containers that don't ship qemu.)

- [ ] **Step 2: Apply and verify registration on a node**

Run:
```bash
kubectl apply -f binfmt-daemonset.yaml
kubectl rollout status daemonset/binfmt -n kube-system
kubectl get nodes -o name | head -1   # pick a node
```
Then on any node (via a debug pod or node shell):
```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```
Expected: output beginning `enabled` and a line containing `flags: ...F...`.

---

## Task 10: Rollout / cutover + end-to-end validation

**Files:**
- None (operational runbook). Merges the branch and validates the live pipeline.

**Interfaces:**
- Consumes: all prior tasks. Produces: a published rootless `tgbyte/builder` and a green pipeline with no privileged build jobs.

**Ordering rationale:** the currently published `tgbyte/builder:latest` is the old DinD image, so the first pipeline running the new `build-image.sh` cannot rely on it. Bootstrap the new image first, then let normal self-builds take over.

- [ ] **Step 1: Land infra prerequisites**

Confirm Task 9 DaemonSet is applied and Task 8 runner (tag `buildkit`, no privileged) is registered and picking up jobs. Keep the old privileged/dind runner available until Step 4.

- [ ] **Step 2: Bootstrap-publish the new builder image**

From a checkout of this branch, build and push using the base directly (not the old image):
```bash
docker run --rm \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -e BUILDKITD_FLAGS=--oci-worker-no-process-sandbox \
  -e DOCKER_CONFIG=/w/.docker \
  -v "$PWD:/w" -w /w \
  --entrypoint buildctl-daemonless.sh \
  moby/buildkit:v0.31.0-rootless \
  build --frontend dockerfile.v0 --local context=/w --local dockerfile=/w \
    --opt build-arg:GIT_COMMIT="$(git rev-parse --short HEAD)" \
    --opt build-arg:GIT_COMMIT_DATE="$(git show -s --format=%cd)" \
    --opt platform=linux/amd64,linux/arm64 \
    --output type=image,name=tgbyte/builder:latest,push=true
```
(Populate `/w/.docker/config.json` with push creds first, e.g. via `registry_auth` or `docker login`.)
Expected: both platforms export and push; `skopeo inspect --raw docker://tgbyte/builder:latest | jq '.manifests[].platform'` lists amd64 and arm64.

- [ ] **Step 3: Merge and run a normal pipeline**

Merge the branch to `main` and run a scheduled/web pipeline (so `trivy` runs). Confirm the `build` job now uses the freshly published image and succeeds rootlessly.
Expected: `trivy` → `build` → `trivy-result` all green; `build` job pod has no `privileged` (re-check as in Task 8 Step 3).

- [ ] **Step 4: Validate a downstream consumer project**

Pick a project that `include:`s this template with `MULTIARCH=1`, run its pipeline.
Verify:
```bash
skopeo inspect --raw docker://<project-image>:<tag> | jq '.mediaType, [.manifests[].platform.architecture]'
```
Expected: an OCI/Docker image index whose `manifests` cover `amd64` and `arm64`. Also confirm `check-tag.sh` short-circuits a rebuild on the second run, and `add-tag.sh` (if used) copies the manifest list.

- [ ] **Step 5: Decommission privileged**

Once green, remove the old dind/privileged runner (or set `privileged = false` globally) so no build path can request privileged. Re-run a pipeline to confirm it still passes on the rootless runner only.
Expected: pipeline green; `grep -r privileged` across runner config shows only the binfmt DaemonSet.

- [ ] **Step 6: Final commit / tag**

```bash
git commit --allow-empty -m "Cutover complete: rootless BuildKit, no privileged build jobs"
```

---

## Self-Review

**Spec coverage:**
- §1 base image → Task 6 (+ Task 7 update mechanism). ✅
- §1a maintenance (apk refresh + Renovate) → Task 7; apk `upgrade` retained in Task 6. ✅
- §2 runner security context → Task 8. ✅
- §3 node binfmt DaemonSet → Task 9. ✅
- §4 pipeline collapse → Task 5. ✅
- §5 scripts (build-functions, build-image, build-manifest delete, add-tag, check-tag, trivy, build-helm) → Tasks 1–5. ✅
- §6 drops (`--squash`, per-arch, results per-arch) → Tasks 1, 2, 5. ✅
- §7 auth / anonymous Harbor pull → Task 1 (config.json, push creds only). ✅
- Testing/verification strategy → per-task verifications + Task 10. ✅

**Placeholder scan:** `token = "REDACTED"` in Task 8 is an intentional secret redaction, not a plan gap. No `TBD`/`TODO`/"handle edge cases".

**Type/name consistency:** `registry_auth`, `write_auth`, `PLATFORMS`, `BUILD_OPTS`, `REGISTRY_AUTH_FILE`, `FULL_IMAGE`, `results/metadata.json` used consistently across Tasks 1–5 and 10.

# Design: Migrate docker-builder from DinD to embedded rootless BuildKit

- **Date:** 2026-07-01
- **Status:** Approved (design)
- **Repo:** `docker/builder` (`tgbyte/builder`)
- **Author:** tg@tgbyte.de (with Claude)

## Goal

Eliminate the requirement for **`--privileged` Docker-in-Docker** in the CI image
builder. Replace the DinD daemon with **rootless BuildKit embedded in the
`tgbyte/builder` image**, invoked per-job via `buildctl-daemonless.sh`.

Primary driver: **security** — remove per-job privileged containers. Not
performance (the current pipeline deliberately uses `--no-cache --pull`, so
cross-pipeline layer caching is out of scope for this change).

## Context (current state)

- **Executor:** GitLab Runner, **Kubernetes**. DinD is wired in at the runner
  level (the CI templates declare no `docker:dind` service or `DOCKER_HOST`).
- **Builder image:** `Dockerfile` is `FROM docker:${DOCKER_VERSION}` plus bash,
  git, helm, trivy, skopeo, jq, node, awk, etc.
- **Pipeline** (`templates/.gitlab-ci.yml`): `scan` (trivy) → `build-image`
  (`build-amd64` + `build-arm64`) → `build-manifest` → `verify` (trivy-result).
- **Multi-arch:** arm64 is **QEMU-emulated** on amd64 runners. Each arch builds
  in its own job (`docker build --platform`), pushing a per-arch tag; a manifest
  job combines them with `docker manifest`. `build-image.sh` installs QEMU via
  `docker run --privileged tonistiigi/binfmt`.
- **Harbor:** `share/harbor-rewrite.awk` rewrites Dockerfile `FROM` lines to
  route base images through a Harbor proxy-cache (`HARBOR_REGISTRY`).
- **Trivy:** runs in its own stage against the **registry** image `${FULL_IMAGE}`
  (not the local daemon), before the build, to force a rebuild when the currently
  published image is vulnerable.

### Daemon-dependency surface (audit)

| Script | Docker-daemon usage today | Migration |
| --- | --- | --- |
| `bin/build-image.sh` | `docker run --privileged binfmt`, `docker build`, `docker push`, `docker inspect` | **Rewrite** to `buildctl-daemonless.sh` |
| `bin/build-manifest.sh` | `docker manifest create/annotate/push` | **Delete** (BuildKit emits the manifest list) |
| `bin/add-tag.sh` | `docker tag` + `docker push` | `skopeo copy` (skopeo already installed) |
| `bin/check-tag.sh` | already uses `skopeo inspect` | only swap `docker_login` |
| `bin/trivy.sh` | none (`trivy image` reads registry) | only swap `docker_login` |
| `bin/build-helm.sh` | none (helm OCI push) | only swap `docker_login` |
| `share/build-functions.sh` | `docker_login`, `ARCH=$(docker version …)` | replace both |

**Key finding:** `build-image.sh` is the only script that truly needs a build
daemon. Everything else needs only registry auth via a config file, which
skopeo, trivy, helm, and buildctl all consume.

## Chosen approach

**Embedded daemonless rootless BuildKit** (evaluated against a rootless sidecar
service and a persistent remote `buildkitd` Deployment). Chosen because it is the
smallest deviation from the current one-container-per-job model, keeps all
tooling co-located with the build (so `build-image.sh`'s bash/awk/git/helm flow
is unchanged), needs no new standing infrastructure, and fully removes per-job
privileged. The sidecar variant remains a future option if we want the seccomp
relaxation confined off the credential-bearing script container; the persistent
remote builder is deferred until warm cross-pipeline caching is a goal.

## Design

### 1. Image (`Dockerfile`)

- **Change the base** from `FROM docker:${DOCKER_VERSION}` (which bundles the
  daemon/CLI we are removing) to **`FROM moby/buildkit:v0.31.0-rootless`**. It is
  Alpine-based and already ships `buildkitd`, `buildctl`,
  `buildctl-daemonless.sh`, `rootlesskit`, `fuse-overlayfs`, and the matched
  rootless plumbing (non-root `user` uid/gid 1000, `/etc/subuid`, `/etc/subgid`,
  `XDG_RUNTIME_DIR`). This collapses the BuildKit version pin into the single base
  tag and removes the risk of hand-rolled rootless setup drifting from the
  buildkitd binary.
- Install the existing tooling on top via `apk` (as root, then return to the
  non-root user): the same set as today — bash, coreutils, curl, git, grep, helm,
  httpie, jq, make, nodejs, npm, openssh-client, patch, py3-pip, python3, sed,
  skopeo, trivy.
- Drop the `DOCKER_VERSION` build-arg (the base tag carries the version). Keep
  `GIT_COMMIT` / `GIT_COMMIT_DATE` args and the `.builder-commit*` markers.
- **Consequence:** the whole `tgbyte/builder` image now runs as uid 1000 by
  default, so non-build jobs (trivy, helm, tag) also run rootless. Acceptable —
  none require root.

**Alternative considered:** keep an `alpine` base and multi-stage `COPY` the
BuildKit binaries, hand-rolling the rootless user / subuid / fuse-overlayfs setup.
Rejected as the default because it duplicates upstream plumbing that can drift
from the binary; retained as a fallback if root-by-default for non-build jobs is
later required.

### 2. Runner config (`config.toml`) — scoped to build jobs only

- Pod/container `securityContext`: `runAsNonRoot: true`, `runAsUser: <buildkit
  uid>`, seccomp profile `Unconfined`, and the AppArmor `unconfined` annotation.
  **No `privileged`, no host mounts.**
- Env `BUILDKITD_FLAGS: --oci-worker-no-process-sandbox`.
- Scope the relaxation to the build job only (dedicated runner tag and/or pod
  annotations) so unrelated jobs keep the default confined profile.

### 3. Node-level binfmt (explicit trade-off)

Rootless BuildKit **cannot** register QEMU `binfmt_misc` handlers itself — that
is exactly what the per-job `docker run --privileged tonistiigi/binfmt` did. For
emulated arm64 the **nodes** must have the handlers pre-registered via a
**one-time privileged DaemonSet** (`tonistiigi/binfmt` or equivalent), run once
per node.

Net effect: privileged is **not eliminated from the cluster**; it is **relocated**
from every build job to a single, auditable, node-level DaemonSet. This is an
accepted trade-off. Alternatives (out of scope): drop arm64, or acquire native
arm64 runners.

### 4. Pipeline (`templates/.gitlab-ci.yml`)

- **scan:** `trivy` — unchanged.
- **build:** a single `build` job replacing `build-amd64` + `build-arm64` +
  `build-manifest`. Runs one multi-platform `buildctl` build over
  `linux/amd64,linux/arm64` with `--output type=image,push=true`, which produces
  and pushes the manifest list directly.
- **verify:** `trivy-result` — unchanged.
- When `MULTIARCH != 1`, build a single native platform (`linux/amd64`).

### 5. Scripts

**`share/build-functions.sh`**
- Replace `docker_login` with `registry_auth`: write `$DOCKER_CONFIG/config.json`
  containing auths for the **push** registry (GitLab or Docker Hub). Harbor
  proxy-cache pulls are anonymous, so no Harbor entry is needed (see §7). Keep the
  existing `helm registry login`. Preserve the `.docker-logged-in` idempotency
  guard.
- Replace `ARCH=$(docker version | grep OS/Arch …)` (no daemon) with a
  configurable `PLATFORMS` variable (default `linux/amd64,linux/arm64`, reduced to
  a single platform when `MULTIARCH != 1`).

**`bin/build-image.sh`**
- Replace `docker build/push/inspect` and the binfmt install with:
  ```
  buildctl-daemonless.sh build \
    --frontend dockerfile.v0 \
    --local context="$BUILD_DIR" \
    --local dockerfile="$(dirname "$DOCKERFILE")" \
    --opt filename="$(basename "$DOCKERFILE")" \
    --opt platform="$PLATFORMS" \
    --opt build-arg:KEY=VALUE …  \
    --output type=image,name="$FULL_IMAGE",push=true \
    --metadata-file results/metadata.json
  ```
- Harbor FROM-rewrite is unchanged: it still produces a processed Dockerfile;
  point `--local dockerfile` / `--opt filename` at it.
- Build-args continue to come from `ARG_*` env vars, mapped to `--opt build-arg:`.
- Drop `--squash` handling (see §6).

**`bin/build-manifest.sh`** — delete.

**`bin/add-tag.sh`** — replace `docker tag` + `docker push` with
`skopeo copy docker://$FULL_IMAGE docker://$IMAGE:$NEW_TAG` per tag.

**`bin/check-tag.sh`, `bin/trivy.sh`, `bin/build-helm.sh`** — swap
`docker_login` → `registry_auth`; no other change.

### 6. Dropped / accepted

- **`--squash` (`DOCKER_SQUASH`)** — unsupported by BuildKit; removed. Communicate
  to any consumer relying on it; multi-stage builds are the replacement for image
  slimming.
- **Per-arch parallelism** — the single job builds both platforms serially.
  Emulated arm64 dominates wall-clock either way, so the loss is roughly one
  (fast, native) amd64 build time per pipeline. Revisit via a remote multi-node
  builder only if this becomes painful.
- **`results/` per-arch digest files** — obsolete once the manifest is
  auto-created. Optionally keep a single manifest-list digest written from
  `--metadata-file` (`containerimage.digest`) for downstream consumers.

### 7. Registry auth & Harbor pull

With no daemon, auth is a hand-written `config.json` (`$DOCKER_CONFIG`). Auth is
required for **push**, not pull: the Harbor proxy-cache serves base-image pulls
**anonymously**, so `config.json` needs only the push-registry credentials
(GitLab or Docker Hub) and no Harbor entry.

Residual (minor): if the Harbor host uses a private CA, the fresh rootless
`buildkitd` must trust it (mount the CA into the build job). This is unlikely
given base-image pulls already succeed today; treat as a verification step, not a
blocker.

## Testing / verification strategy

- **Local/CI dry run:** build a trivial multi-arch image end-to-end (amd64 +
  emulated arm64), confirm the pushed tag is a manifest list with both platforms
  (`skopeo inspect --raw` / `docker buildx imagetools inspect`).
- **No-privileged assertion:** confirm the build job pod runs with no
  `privileged` container and the expected non-root securityContext.
- **Harbor path:** confirm `FROM` base images resolve through Harbor and pull
  successfully from the rootless daemon.
- **Auth matrix:** GitLab registry push, Docker Hub push, and helm chart push all
  succeed against the new `config.json`.
- **Tag ops:** `add-tag.sh` (skopeo copy) and `check-tag.sh` behave as before.
- **Trivy:** scan and JSON report stages unchanged and green.

## Out of scope

- Enabling BuildKit cross-pipeline registry caching / removing `--no-cache`.
- Sidecar or persistent remote `buildkitd` topologies.
- Native arm64 runners.

## Open questions

1. ~~Exact `moby/buildkit` version to pin~~ — **resolved:** base on
   `moby/buildkit:v0.31.0-rootless` (§1); bump if a newer stable lands before
   implementation.
2. ~~Harbor proxy-cache auth model~~ — **resolved:** pulls are anonymous; no
   Harbor creds needed. Private-CA trust remains a minor verification step (§7).

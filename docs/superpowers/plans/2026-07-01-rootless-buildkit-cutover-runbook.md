# Rootless BuildKit Cutover Runbook (Task 10)

Deadlock-free rollout from privileged Docker-in-Docker to rootless BuildKit for
the `tgbyte/builder` CI image builder. Every step is additive and reversible;
the old DinD path keeps working until it is deliberately retired **last**.

## The deadlock this avoids

1. **Self-build chicken-and-egg** — `docker-builder`'s own pipeline builds the
   next `tgbyte/builder` using the *published* `tgbyte/builder`. The new
   `build-image.sh` calls `buildctl`, which only exists in the *new* image. So
   new scripts + old image = broken, and the pipeline that would publish the new
   image is the broken one.
2. **Fleet-wide flip** — every consumer `include:`s the template ref-less
   (tracks `main`). Merging `docker-builder` to `main` flips them all at once.

The escape: **hand-build the first rootless image out-of-band**, and bring the
new runner up **in parallel** (never mutate the shared DinD runner in place).

## Artifacts already prepared

| Repo | Branch | Contents | State |
| --- | --- | --- | --- |
| `docker/builder` | `rootless-buildkit` | rootless scripts, buildkit-base Dockerfile, collapsed template (`tags: [buildkit]`), renovate.json | ready, **not merged** |
| `tgbyte/k8s-config` | `binfmt-daemonset` | `platform/binfmt` DaemonSet + hetzner app | ready |
| `tgbyte/k8s-config` | `gitlab-runner-buildkit` | parallel rootless runner (`platform/gitlab-runner-buildkit`) + app | ready, **placeholders** |

## Manual prerequisites (you must do these — I can't)

- **P1. New GitLab runner.** In GitLab → Admin → CI/CD → Runners, create a
  runner with tag **`buildkit`** and **"Run untagged jobs" = No** (critical: if
  left "Yes" it will steal untagged jobs from the DinD runner). Copy its
  `glrt-…` authentication token.
- **P2. Token secret.** `sops secrets/hetzner/gitlab-runner-buildkit.yaml`
  providing a Secret named `gitlab-runner-buildkit-token-secret` (namespace
  `gitlab-runner`) with key `runner-token` = the P1 token. Mirror the structure
  of `secrets/hetzner/gitlab-runner.yaml`. Add it to the bootstrap-base apply set
  the same way.
- **P3. Confirm K8s version** for the AppArmor mechanism. The runner values use
  the annotation `container.apparmor.security.beta.kubernetes.io/build:
  unconfined`. It is honored on ≤1.29 and deprecated-but-functional on 1.30–1.33.
  If your cluster removed annotation support, switch to
  `appArmorProfile.type: Unconfined` in the build container security context.

## Pre-flight validation (before enabling anything)

```bash
# k8s-config, gitlab-runner-buildkit branch
helm template grb gitlab-runner --repo https://charts.gitlab.io --version 0.90.1 \
  -n gitlab-runner -f platform/gitlab-runner-buildkit/values.yaml | less
# Confirm: Deployment, ServiceAccount, Role/RoleBinding render; config.toml has
# no `privileged`, no dind service, seccomp Unconfined on the build container.

kubectl apply --dry-run=server -k platform/binfmt          # binfmt DaemonSet
```

The embedded `config.toml` has already been validated as well-formed TOML with
the intended values; the digest placeholder passes render and only fails at pod
scheduling (expected until step 1).

---

## Rollout steps

Each row keeps the DinD path fully working. "Old builds work?" = yes until the
final retire.

### Step 0 — binfmt (safe, inert)

Merge and sync the `binfmt-daemonset` branch. It only registers QEMU handlers;
it does nothing to the current privileged-dind builds.

```
Verify: kubectl -n binfmt-system get ds binfmt   # DESIRED == READY
        # on a node: cat /proc/sys/fs/binfmt_misc/qemu-aarch64  → "enabled ... F"
Rollback: delete the argocd app / revert the branch.
```

### Step 1 — bootstrap-publish the first rootless image (breaks the egg)

Build the new image with `moby/buildkit` directly — depends on nothing in the
cluster — and push it to a **distinct** tag `:rootless` (NOT `:latest`, so the
DinD runner, pinned to the old `:latest` digest, is untouched).

```bash
# from a checkout of docker/builder @ rootless-buildkit, with push creds in
# $PWD/.docker/config.json (registry_auth or docker login)
docker run --rm \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -e BUILDKITD_FLAGS=--oci-worker-no-process-sandbox \
  -e DOCKER_CONFIG=/w/.docker -v "$PWD:/w" -w /w \
  --entrypoint buildctl-daemonless.sh moby/buildkit:v0.31.0-rootless \
  build --frontend dockerfile.v0 --local context=/w --local dockerfile=/w \
    --opt build-arg:GIT_COMMIT="$(git rev-parse --short HEAD)" \
    --opt build-arg:GIT_COMMIT_DATE="$(git show -s --format=%cd)" \
    --opt platform=linux/amd64,linux/arm64 \
    --output type=image,name=tgbyte/builder:rootless,push=true

# capture the manifest-list digest:
skopeo inspect --raw docker://tgbyte/builder:rootless | sha256sum   # or read from
# --metadata-file; confirm both platforms:
skopeo inspect --raw docker://tgbyte/builder:rootless | jq '[.manifests[].platform.architecture]'
```

Put the resulting `sha256:…` into
`platform/gitlab-runner-buildkit/values.yaml` (replace the `0000…` placeholder),
commit on the `gitlab-runner-buildkit` branch.

```
Old builds work? YES (new tag, nothing consumes it).
Rollback: delete the :rootless tag.
```

### Step 2 — bring up the parallel rootless runner

After P1/P2 (token + secret) and the digest from step 1: merge and sync the
`gitlab-runner-buildkit` branch.

```
Verify: kubectl -n gitlab-runner get deploy | grep buildkit   # Available
        GitLab → Runners: the buildkit runner shows "online", untagged = No.
Old builds work? YES (no job requests the `buildkit` tag yet).
Rollback: delete the argocd app / revert the branch.
```

### Step 3 — prove the new path on docker-builder itself (no fleet impact)

Run `docker-builder`'s pipeline **from the `rootless-buildkit` branch** so it
uses the branch's new template + scripts on the buildkit runner. Two ways to make
its `include:` use the branch template instead of `main`:

- temporarily set `ref: rootless-buildkit` on the self-`include` in
  `.gitlab-ci.yml` on that branch, **or**
- push a throwaway pipeline that runs the branch's `templates/.gitlab-ci.yml`
  with `tags: [buildkit]`.

```
Verify:
  - the build job pod has NO privileged container, runs as uid 1000
    (kubectl -n gitlab-ci get pod <job> -o jsonpath=...securityContext)
  - pushes a manifest list: skopeo inspect --raw docker://<image>:<tag>
      | jq '[.manifests[].platform.architecture]'   → [amd64, arm64]
  - Harbor base pulls succeed; trivy scan + report stages green.
This proves the new path can self-publish images going forward.
Old builds work? YES (only this branch pipeline is on the new path).
Rollback: nothing to undo.
```

### Step 4 — (optional) migrate a guinea-pig consumer

Pick one consumer, add `ref: rootless-buildkit` to its builder `include:`, run
it. Confirms a real downstream project builds on the new path. Revert the `ref`
to roll back that one project.

### Step 5 — flip the fleet (merge docker-builder → main)

Only after steps 1–3 are green. Merge `docker/builder` `rootless-buildkit` →
`main`. Ref-less consumers now pick up the new template; its `tags: [buildkit]`
routes their build jobs to the (proven) rootless runner, using the rootless
image.

```
Verify: a couple of real consumer pipelines go green; build pods non-privileged.
Old builds work? Consumers are now on the NEW path (that's the goal).
Rollback: revert the merge commit on main → ref-less consumers fall back to the
          old template/DinD immediately (the DinD runner is still up).
```

Then repin the buildkit runner from `:rootless` to the normal published image and
let Renovate keep it fresh:

```
image = "tgbyte/builder:latest@sha256:<current>"   # in gitlab-runner-buildkit values
```

(Do this only after step 5, when the DinD runner no longer needs `:latest` = old.
Until then keep `:rootless` so the two runners stay isolated. The renovate manager
in k8s-config already matches `tgbyte/builder:<tag>@sha256` and will bump it.)

### Step 6 — retire the DinD runner (the only destructive step)

Once all pipelines are green on the new path and stable (give it a few days):

```
- remove the `gitlab-runner` (DinD) app from deployment/hetzner/development.yaml
  and delete platform/gitlab-runner/values.yaml's dind bits (or the whole release);
- delete the old GitLab runner registration + its token secret;
- confirm no config anywhere still sets privileged:  grep -rn privileged
    → only the binfmt DaemonSet's init container remains.
Rollback: re-add the release (it's just GitOps) — but by now nothing needs it.
```

## Renovate note during the parallel window

Both runners pin `tgbyte/builder` by digest. While both exist, do **not** merge a
Renovate MR that bumps the **DinD** runner's `:latest@sha256` pin — that would put
the rootless image on the DinD runner (broken). After step 6 the DinD pin is gone
and the concern disappears. The buildkit runner's pin should track normally.

## One-line summary

Bring up binfmt + a parallel rootless runner + a hand-built rootless image
(steps 0–2, all additive), prove it on docker-builder and one consumer (steps
3–4), flip the fleet by merging to main with instant revert available (step 5),
and only then retire DinD (step 6). There is never a moment where neither path
works.

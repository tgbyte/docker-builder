#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_auth

echo "Scanning ${FULL_IMAGE} for vulnerabilities..."

set +e

# Vulnerability + Java DB sources. Route through the Harbor proxy-cache when
# configured, so Harbor caches them once and every scan pulls locally, dodging
# ghcr.io's trivy-db pull rate limits. Falls back to the public ECR mirror for
# the vuln DB (and trivy's own default for the Java DB) when Harbor is unset.
# An explicit caller value for either wins.
#
# The Java DB comes from Docker Hub (aquasec/trivy-java-db, the same blob as
# ghcr.io/aquasecurity/trivy-java-db), not from ghcr: ghcr serves blobs through
# signed CDN URLs valid for 5-10 minutes and cuts the transfer ~45 s after they
# expire, and from fsn it delivers ~1.2 MB/s -- too slow for the ~1 GB Java DB
# to finish, so Harbor never cached it and every scan failed with "error
# verifying size". Docker Hub delivers the same blob at ~100 MB/s. Measured
# 2026-10-28.
if [ -z "${TRIVY_DB_REPOSITORY:-}" ]; then
  if [ -n "${HARBOR_REGISTRY:-}" ]; then
    TRIVY_DB_REPOSITORY="${HARBOR_REGISTRY%/}/ghcr/aquasecurity/trivy-db:2"
  else
    TRIVY_DB_REPOSITORY=public.ecr.aws/aquasecurity/trivy-db:2
  fi
fi
if [ -z "${TRIVY_JAVA_DB_REPOSITORY:-}" ] && [ -n "${HARBOR_REGISTRY:-}" ]; then
  TRIVY_JAVA_DB_REPOSITORY="${HARBOR_REGISTRY%/}/dockerhub/aquasec/trivy-java-db:1"
fi

TRIVY_PARAMS=()
TRIVY_PACKAGE_TYPES="${TRIVY_PKG_TYPES:-${TRIVY_VULN_TYPE}}"

if [ -n "${TRIVY_SCANNERS}" ]; then
    TRIVY_PARAMS+=(--scanners)
    TRIVY_PARAMS+=("${TRIVY_SCANNERS}")
fi
if [ -n "${TRIVY_SKIP_DIRS}" ]; then
    TRIVY_PARAMS+=(--skip-dirs)
    TRIVY_PARAMS+=("${TRIVY_SKIP_DIRS}")
fi
if [ -n "${TRIVY_PKG_TYPES}" ] && [ -n "${TRIVY_VULN_TYPE}" ]; then
    echo "TRIVY_VULN_TYPE is deprecated and ignored because TRIVY_PKG_TYPES is set."
fi
if [ -n "${TRIVY_VULN_TYPE}" ] && [ -z "${TRIVY_PKG_TYPES}" ]; then
    echo "TRIVY_VULN_TYPE is deprecated; use TRIVY_PKG_TYPES instead."
fi
if [ -n "${TRIVY_PACKAGE_TYPES}" ]; then
    TRIVY_PARAMS+=(--pkg-types)
    TRIVY_PARAMS+=("${TRIVY_PACKAGE_TYPES}")
fi
if [ -n "${TRIVY_DB_REPOSITORY}" ]; then
    TRIVY_PARAMS+=(--db-repository)
    TRIVY_PARAMS+=("${TRIVY_DB_REPOSITORY}")
fi
if [ -n "${TRIVY_JAVA_DB_REPOSITORY:-}" ]; then
    TRIVY_PARAMS+=(--java-db-repository)
    TRIVY_PARAMS+=("${TRIVY_JAVA_DB_REPOSITORY}")
fi

unset TRIVY_VULN_TYPE

trivy \
  --cache-dir .trivy \
  image \
  --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL,MEDIUM}" \
  "${TRIVY_PARAMS[@]}" \
  --ignore-unfixed \
  --exit-code 2 \
  --no-progress \
  --skip-version-check \
  "${FULL_IMAGE}"
EXITCODE=$?

if [ -n "${TRIVY_REPORT_JSON}" ]; then
  echo "Generating Trivy JSON report..."

  trivy \
    --cache-dir .trivy \
    image \
    --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL,MEDIUM}" \
    "${TRIVY_PARAMS[@]}" \
    --ignore-unfixed \
    --no-progress \
    --format json \
    --skip-version-check \
    "${FULL_IMAGE}" > .trivy-report.json
fi

if [ $EXITCODE -eq 2 ]; then
  echo "Detected vulnerable Docker image ${FULL_IMAGE}..."
  touch .trivy-vulnerable
fi
touch .trivy-run

exit $EXITCODE

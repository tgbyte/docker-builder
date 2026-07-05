#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_auth

echo "Scanning ${FULL_IMAGE} for vulnerabilities..."

set +e

# Vulnerability + Java DB sources. Route through the Harbor proxy-cache when
# configured — reuses the `ghcr` proxy-cache project (both DBs' canonical
# upstream is ghcr.io/aquasecurity), so Harbor caches them once and every scan
# pulls locally, dodging ghcr.io's trivy-db pull rate limits. Falls back to the
# public ECR mirror for the vuln DB (and trivy's ghcr.io default for the Java
# DB) when Harbor is unset. An explicit caller value for either wins.
if [ -z "${TRIVY_DB_REPOSITORY:-}" ]; then
  if [ -n "${HARBOR_REGISTRY:-}" ]; then
    TRIVY_DB_REPOSITORY="${HARBOR_REGISTRY%/}/ghcr/aquasecurity/trivy-db:2"
  else
    TRIVY_DB_REPOSITORY=public.ecr.aws/aquasecurity/trivy-db:2
  fi
fi
if [ -z "${TRIVY_JAVA_DB_REPOSITORY:-}" ] && [ -n "${HARBOR_REGISTRY:-}" ]; then
  TRIVY_JAVA_DB_REPOSITORY="${HARBOR_REGISTRY%/}/ghcr/aquasecurity/trivy-java-db:1"
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

#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

docker_login

echo "Scanning ${FULL_IMAGE} for vulnerabilities..."

set +e

TRIVY_DB_REPOSITORY=public.ecr.aws/aquasecurity/trivy-db:2

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

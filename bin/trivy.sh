#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

gitlab_login

echo "Scanning ${FULL_IMAGE} for vulnerabilities..."

set +e

TRIVY_PARAMS=()
if [ -n "${TRIVY_SCANNERS}" ]; then
    TRIVY_PARAMS+=(--scanners)
    TRIVY_PARAMS+=("${TRIVY_SCANNERS}")
fi
if [ -n "${TRIVY_SKIP_DIRS}" ]; then
    TRIVY_PARAMS+=(--skip-dirs)
    TRIVY_PARAMS+=("${TRIVY_SKIP_DIRS}")
fi
if [ -n "${TRIVY_VULN_TYPE}" ]; then
    TRIVY_PARAMS+=(--vuln-type)
    TRIVY_PARAMS+=("${TRIVY_VULN_TYPE}")
fi

trivy \
  --cache-dir .trivy \
  image \
  --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL,MEDIUM}" \
  "${TRIVY_PARAMS[@]}" \
  --ignore-unfixed \
  --exit-code 2 \
  --no-progress \
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
    "${FULL_IMAGE}" > .trivy-report.json
fi

if [ $EXITCODE -eq 2 ]; then
  echo "Detected vulnerable Docker image ${FULL_IMAGE}..."
  touch .trivy-vulnerable
fi
touch .trivy-run

exit $EXITCODE

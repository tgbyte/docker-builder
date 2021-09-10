#!/bin/bash -e

# shellcheck disable=SC2034
QUIET=1
# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

gitlab_login

set +e
skopeo inspect "docker://$1" > /dev/null 2>&1

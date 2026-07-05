#!/bin/bash

set -e -o pipefail

# Print the current stable BuildKit release (e.g. 0.31.1). The releases/latest
# endpoint already excludes drafts and pre-releases, so no extra filtering is needed.
curl -s "https://api.github.com/repos/moby/buildkit/releases/latest" \
| jq -r '.tag_name' \
| sed 's/^v//'

#!/bin/bash

source $(dirname $0)/../share/build-functions.sh

gitlab_login

skopeo inspect "docker://$1"

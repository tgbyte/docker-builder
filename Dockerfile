ARG BUILDKIT_VERSION=0.31.2

# renovate: datasource=docker depName=moby/buildkit versioning=docker
FROM moby/buildkit:v${BUILDKIT_VERSION}-rootless

ARG GIT_COMMIT
ARG GIT_COMMIT_DATE
ARG BUILDER_TAG

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
    && echo $GIT_COMMIT_DATE > /usr/local/etc/.builder-commit-date \
    && echo $BUILDER_TAG > /usr/local/etc/.builder-tag

USER 1000

ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

ARG GIT_COMMIT
ARG GIT_COMMIT_DATE

ENV LANG=C.UTF-8
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
    && echo $GIT_COMMIT_DATE > /usr/local/etc/.builder-commit-date

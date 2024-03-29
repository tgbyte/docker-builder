ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

ENV LANG C.UTF-8
RUN set -x \
    && apk upgrade --no-cache \
    && apk add --no-cache \
         bash \
         coreutils \
         curl \
         git \
         grep \
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

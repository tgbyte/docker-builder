FROM amd64/ubuntu:18.04 as qemu

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
  && apt-get update -qq \
  && apt-get install -qq -y qemu-user-static

ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

COPY --from=qemu /usr/bin/qemu-arm-static /usr/bin

ENV LANG C.UTF-8
RUN set -x \
    && apk add --no-cache \
         bash \
         coreutils \
         curl \
         git \
         jq \
         maven \
         openjdk8 \
         openssh-client

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/

FROM amd64/ubuntu:20.04 as qemu

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
  && apt-get update -qq \
  && apt-get install -qq -y qemu-user-static

ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

COPY --from=qemu /usr/bin/qemu-arm-static /usr/bin
COPY --from=qemu /usr/bin/qemu-aarch64-static /usr/bin

ENV LANG C.UTF-8
RUN set -x \
    && apk add --no-cache \
         bash \
         coreutils \
         curl \
         git \
         grep \
         httpie \
         jq \
         make \
         openssh-client \
         sed \
         skopeo \
    && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing \
         pup

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/

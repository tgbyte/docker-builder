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
         gcc \
         git \
         go \
         grep \
         httpie \
         jq \
         make \
         musl-dev \
         openssh-client \
         sed \
         skopeo \
    && git clone https://github.com/containerd/imgcrypt \
    && cd imgcrypt \
    && make \
    && make install \
    && cd - \
    && rm -rf imgcrypt \
    && apk del --no-cache \
      gcc \
      go \
      musl-dev

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/
COPY etc/* /usr/local/etc/

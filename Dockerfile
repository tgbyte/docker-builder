ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

ENV LANG C.UTF-8
RUN set -x \
    && apk add --no-cache \
         bash \
         coreutils \
         curl \
         git \
         jq \
         openssh-client

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/

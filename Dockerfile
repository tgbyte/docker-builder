ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

RUN set -x \
    && apk add --no-cache \
         bash \
         git \
         openssh-client

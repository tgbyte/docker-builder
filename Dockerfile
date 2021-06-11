ARG DOCKER_VERSION

FROM docker:${DOCKER_VERSION:-latest}

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
         skopeo

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/

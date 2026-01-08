FROM ubuntu:24.04

ARG GIT_COMMIT
ARG GIT_COMMIT_DATE

ENV LANG=C.UTF-8
RUN set -x \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends -qq \
         ca-certificates \
         curl \
         gnupg \
         software-properties-common \
    && add-apt-repository -y universe \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor -o /etc/apt/keyrings/helm.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
         > /etc/apt/sources.list.d/helm-stable-debian.list \
    && curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /etc/apt/keyrings/trivy.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
         > /etc/apt/sources.list.d/trivy.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends -qq \
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
         python3 \
         python3-pip \
         sed \
         buildah \
         fuse-overlayfs \
         skopeo \
         trivy \
    && rm -rf /var/lib/apt/lists/*

COPY bin/* /usr/local/bin/
COPY share/* /usr/local/share/

RUN set -x \
    && mkdir -p /usr/local/etc \
    && echo $GIT_COMMIT > /usr/local/etc/.builder-commit \
    && echo $GIT_COMMIT_DATE > /usr/local/etc/.builder-commit-date

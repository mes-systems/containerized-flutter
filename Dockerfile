FROM ubuntu:24.04@sha256:a61567bd31828687156d735ea8eb01ba4e37636e225dd6a48ba94136a70d9d61

ARG FLUTTER_VERSION
ARG FLUTTER_CHANNEL=stable
ARG FLUTTER_REVISION
ARG FLUTTER_ARCHIVE_SHA256
ARG SOURCE_REVISION=unknown

ENV FLUTTER_ROOT=/opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

LABEL \
  org.opencontainers.image.title="Flutter SDK" \
  org.opencontainers.image.description="Linux amd64 Flutter SDK toolchain image" \
  org.opencontainers.image.source="https://github.com/mes-systems/containerized-flutter" \
  org.opencontainers.image.licenses="Unlicense" \
  org.opencontainers.image.version="${FLUTTER_VERSION}" \
  org.opencontainers.image.revision="${SOURCE_REVISION}" \
  io.mes-systems.flutter.version="${FLUTTER_VERSION}" \
  io.mes-systems.flutter.channel="${FLUTTER_CHANNEL}" \
  io.mes-systems.flutter.revision="${FLUTTER_REVISION}"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    libglu1-mesa \
    unzip \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/*

COPY .artifacts/flutter-sdk.tar.xz /tmp/flutter-sdk.tar.xz

RUN set -eux; \
  test -n "${FLUTTER_VERSION}"; \
  test -n "${FLUTTER_REVISION}"; \
  test -n "${FLUTTER_ARCHIVE_SHA256}"; \
  printf '%s  %s\n' "${FLUTTER_ARCHIVE_SHA256}" /tmp/flutter-sdk.tar.xz \
    | sha256sum --check --status -; \
  tar --extract --xz --file /tmp/flutter-sdk.tar.xz \
    --directory /opt --no-same-owner; \
  rm -f /tmp/flutter-sdk.tar.xz; \
  test -x /opt/flutter/bin/flutter; \
  test -x /opt/flutter/bin/dart; \
  test -d /opt/flutter/.git; \
  test "$(git -C /opt/flutter rev-parse HEAD)" = "${FLUTTER_REVISION}"; \
  git -C /opt/flutter tag --points-at HEAD | grep -Fx -- "${FLUTTER_VERSION}"

RUN flutter config --no-analytics \
  && dart --disable-analytics

WORKDIR /workspace

# ── Stage 1: Builder ─────────────────────────────────────────────────────────
# Extracts the Openfire tarball, strips unused components (bundled JRE, docs),
# and assembles config + plugins into /opt/openfire so runtime needs only one COPY.
#
# Place openfire_<VERSION>.tar.gz (dots replaced with underscores) in build context.
# Build args:  --build-arg OPENFIRE_VERSION=5.1.1 --build-arg OPENFIRE_SHA256=<sha256>
# OPENFIRE_SHA256 is mandatory: the tarball is verified inside the build, so
# every build path (CI, local, airgapped) ships only checksum-verified bytes.
FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:8bf0e8f20737e9c8a68c8a498299e9504ab397b1b1f2837acb2fef12ec698f0e AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG OPENFIRE_VERSION=5.1.1
ARG OPENFIRE_SHA256=""
ARG OPENFIRE_DOWNLOAD_BASE_URL=https://github.com/igniterealtime/Openfire/releases/download

# Stage config files into /tmp for the single RUN below
COPY log4j2-container.xml /tmp/
COPY conf/openfire.xml /tmp/
COPY plugins/ /tmp/plugins/
COPY lib/ /tmp/lib/
COPY exclude.txt /tmp/

# Single RUN: derive version file name, validate tarball, extract, strip,
# overlay config + plugins, then clean up /tmp.
# Uses bind mount for the tarball so no layer is created for the large .tar.gz.
# - Removes bundled JRE (container provides OpenJDK 17) and docs to save space
# - Replaces log4j2.xml to route all logs to stdout for container log drivers
# - Copies default openfire.xml (no credentials baked in -- first boot serves
#   the setup wizard; unattended setup is a mounted config, see docs)
# - Installs any plugin JARs placed in plugins/ before build
# - Installs any server-classpath JARs placed in lib/ before build
#   (JDBC drivers, custom auth providers -- see lib.txt)
RUN --mount=type=bind,target=/src \
    VERSION_FILE=$(echo "${OPENFIRE_VERSION}" | tr '.' '_') && \
    test -f "/src/openfire_${VERSION_FILE}.tar.gz" || { \
      echo ""; \
      echo "ERROR: openfire_${VERSION_FILE}.tar.gz not found in build context."; \
      echo "       Download it first:"; \
      echo "       curl -fsSL -o openfire_${VERSION_FILE}.tar.gz \\"; \
      echo "         ${OPENFIRE_DOWNLOAD_BASE_URL}/v${OPENFIRE_VERSION}/openfire_${VERSION_FILE}.tar.gz"; \
      echo ""; \
      exit 1; \
    } && \
    test -n "${OPENFIRE_SHA256}" || { \
      echo ""; \
      echo "ERROR: OPENFIRE_SHA256 build arg is required (sha256 of the tarball)."; \
      echo "       --build-arg OPENFIRE_SHA256=\$(sha256sum openfire_${VERSION_FILE}.tar.gz | cut -d' ' -f1)"; \
      echo ""; \
      exit 1; \
    } && \
    echo "${OPENFIRE_SHA256}  /src/openfire_${VERSION_FILE}.tar.gz" | sha256sum -c - && \
    tar xzf "/src/openfire_${VERSION_FILE}.tar.gz" -C /opt/ && \
    rm -rf /opt/openfire/jre /opt/openfire/documentation && \
    # Remove every lib/ JAR matching a glob in exclude.txt (unused bundled
    # JDBC drivers -- the list and rationale live in that file). Runs BEFORE
    # lib.txt JARs are copied in, so pinned JARs cannot be caught here.
    while IFS= read -r jar; do \
      case "$jar" in ''|\#*) continue ;; esac; \
      find /opt/openfire/lib -maxdepth 1 -name "$jar" -print -delete; \
    done < /tmp/exclude.txt && \
    cp /tmp/log4j2-container.xml /opt/openfire/lib/log4j2.xml && \
    cp /tmp/openfire.xml /opt/openfire/conf/openfire.xml && \
    if ls /tmp/plugins/*.jar >/dev/null 2>&1; then cp /tmp/plugins/*.jar /opt/openfire/plugins/; fi && \
    if ls /tmp/lib/*.jar >/dev/null 2>&1; then cp /tmp/lib/*.jar /opt/openfire/lib/; fi && \
    mkdir -p /opt/openfire/embedded-db /opt/openfire/logs && \
    # Least-privilege permissions, preserved by the runtime COPY:
    # group-writable ONLY where Openfire writes at runtime -- application code
    # (lib/, bin/) stays read-only so an in-process compromise cannot
    # persist itself into the classpath.
    chmod -R u=rwX,g=rX,o= /opt/openfire && \
    chmod -R g+w /opt/openfire/conf /opt/openfire/embedded-db \
      /opt/openfire/logs /opt/openfire/plugins /opt/openfire/resources/security && \
    chmod 775 /opt/openfire && \
    rm -rf /tmp/*

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
# Minimal runtime image. Only one filesystem layer is added on top of the base
# (the COPY below). All other instructions are metadata-only.
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:1.24@sha256:6245fa3b65d2e5a9d95eb8fd1336512f7771bae30c773798257ddb2c64729237

ARG OPENFIRE_VERSION=5.1.1

# OCI image metadata
LABEL org.opencontainers.image.title="Openfire XMPP Server" \
      org.opencontainers.image.description="Openfire XMPP server on Red Hat UBI9 OpenJDK 17" \
      org.opencontainers.image.version="${OPENFIRE_VERSION}" \
      org.opencontainers.image.vendor="mkoese" \
      org.opencontainers.image.source="https://gitlab.com/mkoese/openfire-oci"

ENV OPENFIRE_HOME=/opt/openfire

# Create the destination directory with correct permissions BEFORE copying.
# COPY --chmod only applies to contents, not the destination directory itself.
# OpenShift runs with an arbitrary UID in GID 0 — the home directory needs
# group-write so Openfire can create runtime files.
USER root
RUN mkdir -p ${OPENFIRE_HOME} && chmod 775 ${OPENFIRE_HOME} && chown 1001:0 ${OPENFIRE_HOME}

# Trailing slash: copy CONTENTS into the existing directory (preserving its permissions).
# --chown sets UID 1001 / GID 0 (OpenShift arbitrary UID compatible).
# File modes come from the builder stage: writable dirs are group-writable,
# application code is read-only (no blanket --chmod).
COPY --from=builder --chown=1001:0 /opt/openfire/ ${OPENFIRE_HOME}/

# No VOLUME declarations on purpose: they spawn surprise anonymous volumes
# under plain podman/docker (masking rebuilt plugin jars, "losing" data on
# container replacement) and are ignored by Kubernetes anyway. Persistence is
# the deployment's job -- mount volumes explicitly (see openfire-gitops).

# XMPP client (5222/5223), S2S federation (5269/5270), component (5275/5276),
# BOSH/WebSocket (7070/7443), file transfer proxy (7777), admin console (9090/9091)
EXPOSE 5222 5223 5269 5270 5275 5276 7070 7443 7777 9090 9091

# Aligned with K8s liveness/readiness probes in deployment.yaml
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost:9090/login.jsp || exit 1

# Run as non-root
USER 1001
WORKDIR ${OPENFIRE_HOME}

# JVM flags (override via JAVA_OPTS environment variable):
#   -XX:+UseContainerSupport              — respect cgroup memory/CPU limits
#   -XX:MaxRAMPercentage=60.0             — heap; the REST of the limit belongs to
#                                           native memory (see next flag)
#   -XX:MaxDirectMemorySize=1g            — Netty keeps TLS buffers in DIRECT
#                                           memory; the JVM default (= heap size)
#                                           lets heap+native exceed the cgroup
#                                           limit -> OOMKilled without Java
#                                           diagnostics (ExitOnOutOfMemoryError
#                                           only catches heap OOM)
#   -XX:+UseG1GC                          — low-latency garbage collector
#   -XX:+ExitOnOutOfMemoryError           — crash fast instead of running degraded
#   -Dlog4j2.formatMsgNoLookups           — CVE-2021-44228 (Log4Shell) mitigation
#   -Djava.security.egd=file:/dev/urandom — non-blocking entropy for faster TLS handshakes
ENV JAVA_OPTS="-XX:+UseContainerSupport \
  -XX:MaxRAMPercentage=60.0 \
  -XX:MaxDirectMemorySize=1g \
  -XX:+UseG1GC \
  -XX:+ExitOnOutOfMemoryError \
  -Dlog4j2.formatMsgNoLookups=true \
  -Djava.security.egd=file:/dev/urandom"

ENTRYPOINT ["sh", "-c", "exec java -server ${JAVA_OPTS} -DopenfireHome=/opt/openfire -Dopenfire.lib.dir=/opt/openfire/lib -Dlog4j.configurationFile=/opt/openfire/lib/log4j2.xml -jar /opt/openfire/lib/startup.jar"]

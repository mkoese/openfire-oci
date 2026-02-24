# ── Stage 1: Builder ─────────────────────────────────────────────────────────
# Extracts the Openfire tarball, strips unused components (bundled JRE, docs),
# and assembles config + plugins into /opt/openfire so runtime needs only one COPY.
#
# Place openfire_<VERSION_FILE>.tar.gz in build context before building.
# Override version at build time:
#   --build-arg OPENFIRE_VERSION=5.1.0 --build-arg OPENFIRE_VERSION_FILE=5_1_0
FROM registry.access.redhat.com/ubi9/ubi:9.5 AS builder

ARG OPENFIRE_VERSION=5.0.3
ARG OPENFIRE_VERSION_FILE=5_0_3

# Validate the tarball exists using a bind mount (no layer created).
# Prints download instructions on failure so the user knows what to do.
RUN --mount=type=bind,target=/ctx \
    test -f /ctx/openfire_${OPENFIRE_VERSION_FILE}.tar.gz || { \
      echo ""; \
      echo "ERROR: openfire_${OPENFIRE_VERSION_FILE}.tar.gz not found in build context."; \
      echo "       Download it first:"; \
      echo "       curl -fsSL -o openfire_${OPENFIRE_VERSION_FILE}.tar.gz \\"; \
      echo "         https://github.com/igniterealtime/Openfire/releases/download/v${OPENFIRE_VERSION}/openfire_${OPENFIRE_VERSION_FILE}.tar.gz"; \
      echo ""; \
      exit 1; \
    }

# Stage all build-context files into /tmp for the single RUN below
COPY openfire_${OPENFIRE_VERSION_FILE}.tar.gz /tmp/
COPY log4j2-container.xml /tmp/
COPY conf/openfire.xml /tmp/
COPY plugins/ /tmp/plugins/

# Single RUN: extract, strip, overlay config + plugins, then clean up /tmp.
# - Removes bundled JRE (container provides OpenJDK 17) and docs to save space
# - Replaces log4j2.xml to route all logs to stdout for container log drivers
# - Copies default openfire.xml with autosetup for zero-config first boot
# - Installs any plugin JARs placed in plugins/ before build
RUN tar xzf /tmp/openfire_${OPENFIRE_VERSION_FILE}.tar.gz -C /opt/ \
    && rm -rf /opt/openfire/jre /opt/openfire/documentation \
    && cp /tmp/log4j2-container.xml /opt/openfire/lib/log4j2.xml \
    && cp /tmp/openfire.xml /opt/openfire/conf/openfire.xml \
    && cp /tmp/plugins/*.jar /opt/openfire/plugins/ 2>/dev/null; \
    chmod 775 /opt/openfire && rm -rf /tmp/*

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
# Minimal runtime image. Only one filesystem layer is added on top of the base
# (the COPY below). All other instructions are metadata-only.
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20

ARG OPENFIRE_VERSION=5.0.3

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
# --chmod 775 grants group write so GID 0 can modify files at runtime.
COPY --from=builder --chown=1001:0 --chmod=775 /opt/openfire/ ${OPENFIRE_HOME}/

# Volumes for data that should persist across container restarts
VOLUME ["${OPENFIRE_HOME}/conf", \
        "${OPENFIRE_HOME}/embedded-db", \
        "${OPENFIRE_HOME}/plugins", \
        "${OPENFIRE_HOME}/resources/security"]

# XMPP client (5222/5223), S2S federation (5269/5270), component (5275/5276),
# BOSH/WebSocket (7070/7443), file transfer proxy (7777), admin console (9090/9091)
EXPOSE 5222 5223 5269 5270 5275 5276 7070 7443 7777 9090 9091

# Aligned with K8s liveness/readiness probes in deployment.yaml
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -sf http://localhost:9090/login.jsp || exit 1

# Run as non-root
USER 1001
WORKDIR ${OPENFIRE_HOME}

# JVM flags:
#   -XX:+UseContainerSupport     — respect cgroup memory/CPU limits
#   -XX:MaxRAMPercentage=75.0    — use up to 75% of container memory for heap
#   -XX:+UseG1GC                 — low-latency garbage collector
#   -XX:+ExitOnOutOfMemoryError  — crash fast instead of running degraded
#   -Dlog4j2.formatMsgNoLookups  — CVE-2021-44228 (Log4Shell) mitigation
CMD ["java", "-server", \
     "-XX:+UseContainerSupport", \
     "-XX:MaxRAMPercentage=75.0", \
     "-XX:+UseG1GC", \
     "-XX:+ExitOnOutOfMemoryError", \
     "-Dlog4j2.formatMsgNoLookups=true", \
     "-DopenfireHome=/opt/openfire", \
     "-Dopenfire.lib.dir=/opt/openfire/lib", \
     "-Dlog4j.configurationFile=/opt/openfire/lib/log4j2.xml", \
     "-jar", "/opt/openfire/lib/startup.jar"]

# ── Stage 1: Extract ─────────────────────────────────────────────────────────
# Place openfire_<VERSION_FILE>.tar.gz in build context before building.
# Override version at build time:
#   --build-arg OPENFIRE_VERSION=5.1.0 --build-arg OPENFIRE_VERSION_FILE=5_1_0
FROM registry.access.redhat.com/ubi9/ubi:9.5 AS builder

ARG OPENFIRE_VERSION=5.0.3
ARG OPENFIRE_VERSION_FILE=5_0_3

# Fail early with a helpful message if the archive is missing
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

COPY openfire_${OPENFIRE_VERSION_FILE}.tar.gz /tmp/
COPY log4j2-container.xml /tmp/
COPY conf/openfire.xml /tmp/
COPY plugins/ /tmp/plugins/

RUN tar xzf /tmp/openfire_${OPENFIRE_VERSION_FILE}.tar.gz -C /opt/ \
    && rm -rf /opt/openfire/jre /opt/openfire/documentation \
    && cp /tmp/log4j2-container.xml /opt/openfire/lib/log4j2.xml \
    && cp /tmp/openfire.xml /opt/openfire/conf/openfire.xml \
    && cp /tmp/plugins/*.jar /opt/openfire/plugins/ 2>/dev/null; \
    rm -rf /tmp/*

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20

ARG OPENFIRE_VERSION=5.0.3

LABEL org.opencontainers.image.title="Openfire XMPP Server" \
      org.opencontainers.image.description="Openfire XMPP server on Red Hat UBI9 OpenJDK 17" \
      org.opencontainers.image.version="${OPENFIRE_VERSION}" \
      org.opencontainers.image.vendor="mkoese" \
      org.opencontainers.image.source="https://gitlab.com/mkoese/openfire-oci"

ENV OPENFIRE_HOME=/opt/openfire

# Single COPY from builder with ownership set — no extra RUN layer needed
COPY --from=builder --chown=1001:0 --chmod=775 /opt/openfire ${OPENFIRE_HOME}

VOLUME ["${OPENFIRE_HOME}/conf", \
        "${OPENFIRE_HOME}/embedded-db", \
        "${OPENFIRE_HOME}/plugins", \
        "${OPENFIRE_HOME}/resources/security"]

# Standard Openfire ports (use port mapping to expose on different host ports)
EXPOSE 5222 5223 5269 5270 5275 5276 7070 7443 7777 9090 9091

USER 1001
WORKDIR ${OPENFIRE_HOME}

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

# ── Stage 1: Extract ─────────────────────────────────────────────────────────
# Place openfire_5_0_3.tar.gz in build context before building
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20 AS builder

LABEL org.opencontainers.image.title="Openfire XMPP Server" \
      org.opencontainers.image.description="Openfire XMPP server on Red Hat UBI9 OpenJDK 17" \
      org.opencontainers.image.version="5.0.3" \
      org.opencontainers.image.vendor="mkoese" \
      org.opencontainers.image.source="https://gitlab.com/mkoese/openfire-oci"
ARG OPENFIRE_VERSION_UNDERSCORE=5_0_3
COPY openfire_${OPENFIRE_VERSION_UNDERSCORE}.tar.gz /tmp/
RUN tar xzf /tmp/openfire_${OPENFIRE_VERSION_UNDERSCORE}.tar.gz -C /opt/ \
    && rm -rf /opt/openfire/jre /opt/openfire/documentation

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20

ENV OPENFIRE_HOME=/opt/openfire

COPY --from=builder /opt/openfire ${OPENFIRE_HOME}

# Override log4j2.xml so ALL logs go to stdout (not just plugin messages)
COPY log4j2-container.xml ${OPENFIRE_HOME}/lib/log4j2.xml

# Non-root: UID 1001, GID 0 for OpenShift arbitrary UID
USER root
RUN chown -R 1001:0 ${OPENFIRE_HOME} \
    && chmod -R g=u ${OPENFIRE_HOME}

VOLUME ["${OPENFIRE_HOME}/conf", \
        "${OPENFIRE_HOME}/embedded-db", \
        "${OPENFIRE_HOME}/plugins", \
        "${OPENFIRE_HOME}/resources/security"]

EXPOSE 15222 15223 5269 7070 7443 19090 19091

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

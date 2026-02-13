# ── Stage 1: Extract ─────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS builder
ARG OPENFIRE_VERSION=5.0.3
RUN microdnf install -y tar gzip \
    && curl -fsSL \
       "https://github.com/igniterealtime/Openfire/releases/download/v${OPENFIRE_VERSION}/openfire_${OPENFIRE_VERSION}.tar.gz" \
       -o /tmp/openfire.tar.gz \
    && tar xzf /tmp/openfire.tar.gz -C /opt/ \
    && rm -rf /opt/openfire/jre /opt/openfire/documentation

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
ARG JAVA_PACKAGE=java-17-openjdk-headless
RUN microdnf install -y ${JAVA_PACKAGE} && microdnf clean all

ENV JAVA_HOME=/usr/lib/jvm/jre-17-openjdk \
    OPENFIRE_HOME=/opt/openfire

COPY --from=builder /opt/openfire ${OPENFIRE_HOME}

# Override log4j2.xml so ALL logs go to stdout (not just plugin messages)
COPY log4j2-container.xml ${OPENFIRE_HOME}/lib/log4j2.xml

# Non-root: UID 1001, GID 0 for OpenShift arbitrary UID
RUN chown -R 1001:0 ${OPENFIRE_HOME} \
    && chmod -R g=u ${OPENFIRE_HOME}

VOLUME ["${OPENFIRE_HOME}/conf", \
        "${OPENFIRE_HOME}/embedded-db", \
        "${OPENFIRE_HOME}/plugins", \
        "${OPENFIRE_HOME}/resources/security"]

EXPOSE 5222 5223 5269 7070 7443 9090 9091
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

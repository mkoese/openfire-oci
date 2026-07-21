# Openfire OCI

Base container image for the [Openfire](https://www.igniterealtime.org/projects/openfire/)
XMPP server on Red Hat UBI9 / OpenJDK 17 — hardened for OpenShift and built from
pinned, checksum-verified inputs.

Part of a 3-repo setup:

| Repo | Purpose |
|------|---------|
| **openfire-oci** | This repo — base container image + plugins + server-classpath JARs |
| [openfire-gitops](https://gitlab.com/mkoese/openfire-gitops) | Deployment: Helm chart (OpenShift/K8s) |
| [openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider) | Java/Maven customizations (AD-gated AuthProvider), baked in via `lib.txt` |

> New here? Start with the [architecture overview](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/architecture.md).

## Image at a glance

| | |
|---|---|
| **Base (runtime)** | `ubi9/openjdk-17-runtime:1.24` |
| **Base (builder)** | `ubi9/ubi:9.8` |
| **Openfire** | 5.1.1 |
| **Java** | OpenJDK 17 |
| **User** | `1001:0` (OpenShift arbitrary-UID compatible) |
| **Structure** | 2-stage build → base + two small layers (perms + app) |

## How the image is built

A **two-stage** [`Containerfile`](Containerfile) keeps build tooling out of the
shipped image:

- **Stage 1 — builder** (`ubi9/ubi:9.8`): extracts the Openfire tarball (via a
  **bind mount**, so the archive is never a layer), strips the bundled JRE and
  docs, overlays the container `log4j2.xml` (logs → stdout), the default
  `openfire.xml`, and any pinned plugins/libs — all in a **single `RUN`**.
- **Stage 2 — runtime** (`ubi9/openjdk-17-runtime:1.24`): a home-dir `RUN`
  plus a **single** `COPY --from=builder --chown=1001:0` of `/opt/openfire`
  (file modes come from the builder: app code read-only, data dirs
  group-writable). Everything else (`LABEL`/`ENV`/`EXPOSE`/`HEALTHCHECK`/
  `USER`/`ENTRYPOINT`) is metadata — no `VOLUME`s, on purpose.

**Pinned inputs** — build artifacts are declared in two `name|url|sha256` lists,
verified on every build (content-addressed, so mirrors are safe):

- [`plugins.txt`](plugins.txt) → `/opt/openfire/plugins/`
- [`lib.txt`](lib.txt) → `/opt/openfire/lib/` (JDBC driver, auth provider)
- [`exclude.txt`](exclude.txt) → bundled JARs *removed* from `lib/` (unused DB drivers — PostgreSQL-only)

→ Full walkthrough and the three build modes: **[docs/build.md](docs/build.md)**.

## Security

Hardened for the OpenShift `restricted-v2` SCC:

- runs as an **arbitrary non-root UID** in **GID 0** — numeric `USER 1001`, no
  `/etc/passwd` dependency, all writable dirs group-0 writable (incl.
  `embedded-db`/`logs`, so it doesn't CrashLoop under a random UID)
- **no secrets in the image** — no default admin credentials; first boot serves
  the setup wizard
- **supply chain**: every input pinned by sha256 and verified; a tampered
  (even mirrored) artifact fails the build
- multi-stage (no build tools shipped), JRE/docs stripped, no SUID, Log4Shell
  mitigation in `JAVA_OPTS`, `readOnlyRootFilesystem`-compatible

→ Details: **[docs/security.md](docs/security.md)**.

## Special configuration

- **Logs → stdout** — the container `log4j2.xml` routes everything to the
  container log driver (no log files to mount); levels are live-reloadable
  (`monitorInterval`) — see [docs/logging.md](docs/logging.md)
- **Setup wizard on first boot** — no credentials baked in; unattended setup
  via a mounted `<autosetup>` config (production: the gitops chart injects
  credentials from Kubernetes secrets)
- **Declarative system properties** — non-reserved `openfire.xml` properties
  seed the DB `ofProperty` at setup (how `sasl.*`/`ldap.*`/`adAuth.*` are provisioned)
- **Container-aware JVM** — `JAVA_OPTS` uses cgroup limits, G1GC, fail-fast OOM;
  override via the `JAVA_OPTS` env var

→ Details: **[docs/configuration.md](docs/configuration.md)**.

## Quick start

```bash
# 127.0.0.1: until the setup wizard is completed, whoever reaches 9090 first
# owns the admin account -- never expose a pre-setup console to the network
podman run -d --name openfire -p 127.0.0.1:9090:9090 -p 5222:5222 openfire-oci:5.1.1
```

Open http://localhost:9090 and complete the setup wizard. For real
deployments (OpenShift/Kubernetes, PostgreSQL, AD auth) see
[openfire-gitops](https://gitlab.com/mkoese/openfire-gitops).

## Documentation

| Doc | What |
|-----|------|
| [docs/build.md](docs/build.md) | Image build architecture + local / CI / airgapped modes |
| [docs/security.md](docs/security.md) | Rootless / arbitrary-UID model, supply-chain pinning |
| [docs/configuration.md](docs/configuration.md) | Ports, first-boot setup, system properties, sizing |
| [docs/logging.md](docs/logging.md) | Log to stdout, enable debug/trace, monitoring/observability |
| [docs/airgapped-setup.md](docs/airgapped-setup.md) | Building with no internet (internal registry + mirrors) |
| [docs/local-dev.md](docs/local-dev.md) | Build, run, and iterate locally with Podman |
| [docs/debugging.md](docs/debugging.md) | Logs, common failures, image inspection, JVM diagnostics |

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright 2026 Mikail Koese.

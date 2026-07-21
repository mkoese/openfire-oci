# Logging & monitoring

How logging works in this image and how to raise the level to `debug` / `trace`.

## How it works

The image replaces Openfire's stock `lib/log4j2.xml` with
[`log4j2-container.xml`](../log4j2-container.xml), which sends **all output to
stdout** — the container log driver is the single source of truth. There are no
log files to mount or rotate.

```bash
podman logs -f openfire                                  # local
oc logs -f deployment/<release>-openfire -n openfire     # Kubernetes/OpenShift
```

Default level is **INFO** (root), with `org.eclipse.jetty` pinned to `warn` to
cut noise.

## Enable debug/trace with an environment variable (easiest)

Levels are driven by env vars, so you change them from the **OpenShift/Kubernetes
UI** — no rebuild, no file edit. Editing a Deployment env var rolls a new pod that
starts at the new level.

| Env var | Category | Default |
|---------|----------|---------|
| `OPENFIRE_LOG_LEVEL` | root (everything) | `info` |
| `OPENFIRE_LOG_LEVEL_AUTH` | `com.mkoese.openfire.auth` (AD auth provider) | `info` |
| `OPENFIRE_LOG_LEVEL_LDAP` | `org.jivesoftware.openfire.ldap` | `info` |
| `OPENFIRE_LOG_LEVEL_SASL` | `org.jivesoftware.openfire.net` (SASL/TLS) | `info` |

Values are case-insensitive: `off`, `error`, `warn`, `info`, `debug`, `trace`, `all`.

**OpenShift UI:** *Workloads → Deployments → openfire → Environment* → set e.g.
`OPENFIRE_LOG_LEVEL_AUTH = trace` → Save (the deployment redeploys at that level).

**CLI:**
```bash
oc set env deployment/<release>-openfire OPENFIRE_LOG_LEVEL_AUTH=trace -n openfire
# back to normal:
oc set env deployment/<release>-openfire OPENFIRE_LOG_LEVEL_AUTH=info -n openfire
```

**Podman:**
```bash
podman run -e OPENFIRE_LOG_LEVEL_AUTH=trace ... openfire-oci:5.1.1
```

The [openfire-gitops](https://gitlab.com/mkoese/openfire-gitops) chart renders all
four as env vars (from the `logging` values block), so they're always present and
editable in the UI.

## Other ways to change levels

The config also sets `monitorInterval="30"` (re-reads the file every 30s), so a
`log4j2.xml` change applies without a restart:

- **Mount an override** — mount your own `log4j2.xml` over
  `/opt/openfire/lib/log4j2.xml` via a ConfigMap (persistent; works under
  `readOnlyRootFilesystem`). Use this to add categories not covered by the env vars:
  ```xml
  <Logger name="org.jivesoftware.openfire.muc" level="debug"/>
  ```
- **Live edit (ephemeral)** — `oc exec … vi /opt/openfire/lib/log4j2.xml`; reloads
  within 30s, lost on restart.
- **Bake into the image** — edit `log4j2-container.xml` in this repo and rebuild.

## Openfire's own debug toggle

Openfire can raise the level of its **own** loggers (`org.jivesoftware.*`) at
runtime via the property `log.debug.enabled=true` (admin console → *System
Properties*, or seed via `openfire.xml`). That toggle does **not** cover
third-party categories like `com.mkoese.openfire.auth` — use a `<Logger>` entry
(above) for those.

## Log format

```
2026.07.13 20:20:34.231 INFO  [main]: org.jivesoftware.openfire.XMPPServer - Openfire 5.1.1 [...]
└─ date/time            │level │thread │ category (logger name)              │ message
```

`%msg{nolookups}` is used deliberately — part of the Log4Shell mitigation (see
[security.md](security.md#jvm-security-hardening)).

## Monitoring / observability

- **Health** — the K8s startup/liveness/readiness probes (gitops chart) and the
  image `HEALTHCHECK` hit `/login.jsp`. See [security.md › Health](security.md#health).
- **Metrics** — Openfire is not Spring Boot (no actuator/`/metrics`) and has no
  Prometheus plugin; scrape it via the JMX Exporter javaagent. Full guide:
  [openfire-gitops › monitoring](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/monitoring.md).
- **Log aggregation** — because everything is stdout, any cluster log stack
  (EFK/Loki, OpenShift Logging) collects it with no extra config.

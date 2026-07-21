# Configuration

Runtime configuration of the image: ports, first-boot setup, system properties,
and sizing. Deployment-time config (PostgreSQL, AD/Kerberos, TLS) is handled by
[openfire-gitops](https://gitlab.com/mkoese/openfire-gitops).

## Ports

| Port | Description |
|------|-------------|
| 5222 | XMPP client (STARTTLS) |
| 5223 | XMPP client (Direct TLS) |
| 5269 | Server-to-server (STARTTLS) |
| 5270 | Server-to-server (Direct TLS) |
| 5275 | External components (STARTTLS) |
| 5276 | External components (Direct TLS) |
| 7070 | BOSH / WebSocket (HTTP) |
| 7443 | BOSH / WebSocket (HTTPS) |
| 7777 | File transfer proxy |
| 9090 | Admin console (HTTP) |
| 9091 | Admin console (HTTPS) |

Defaults match the [Network Configuration guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/network-configuration-guide.html).
Clustering adds Hazelcast inter-node port `5701` — not exposed here, see
[openfire-gitops › Scaling](https://gitlab.com/mkoese/openfire-gitops#scaling-beyond-one-node-clustering).

## First boot

The image ships **without credentials**: `conf/openfire.xml` has no
`<autosetup>` block, so the first start serves the **setup wizard** on port
9090, where domain, database, and the admin password are chosen. See
[security.md › No secrets in the image](security.md#no-secrets-in-the-image).

For an **unattended first boot**, mount your own `openfire.xml` containing an
`<autosetup>` block (pick a real password!):

```xml
<autosetup>
  <run>true</run>
  <locale>en</locale>
  <xmpp>
    <domain>localhost</domain>
    <fqdn>localhost</fqdn>
  </xmpp>
  <encryption>
    <algorithm>AES</algorithm>
  </encryption>
  <database>
    <mode>embedded</mode>
  </database>
  <profile>
    <mode>default</mode>
  </profile>
  <admin>
    <email>admin@example.com</email>
    <password>CHANGE-ME</password>
  </admin>
</autosetup>
```

```bash
podman run -d --name openfire -p 127.0.0.1:9090:9090 \
  -v "$(pwd)/my-openfire.xml:/opt/openfire/conf/openfire.xml:Z" openfire-oci:5.1.1
```

Autosetup runs once, then replaces itself with `<setup>true</setup>`. An
already-configured instance (existing DB schema) mounts a config with
`<setup>true</setup>` directly. Production deployments do all of this via the
gitops chart, which injects credentials from Kubernetes secrets.

### Database schema

Against an **empty PostgreSQL** the schema is created automatically on first
boot — Openfire's setup runs `openfire_postgresql.sql` itself
([Database Installation guide](https://download.igniterealtime.org/openfire/docs/latest/documentation/database.html)),
no manual pre-load needed. The only prerequisite is the JDBC driver, baked in via
`lib.txt`. On a version upgrade the schema is auto-migrated. Full data model:
[openfire-gitops › data lifecycle](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/data-lifecycle.md).

## System properties via openfire.xml

Openfire system properties live in the database (`ofProperty`), but they can be
**seeded declaratively** through `conf/openfire.xml`: when setup completes, every
XML property outside the reserved set is copied into the DB (only if not already
set there). Dots become nested elements:

```xml
<jive>
  <!-- sasl.mechs -->
  <sasl>
    <mechs>PLAIN,SCRAM-SHA-1,GSSAPI</mechs>
  </sasl>
  <!-- adAuth.password.minLength (see openfire-authprovider) -->
  <adAuth>
    <password>
      <minLength>12</minLength>
    </password>
  </adAuth>
</jive>
```

Rules:

- Seeding happens **once, at setup completion**. Afterwards, change properties in
  the admin console (*Server Manager → System Properties*) — editing the XML has
  no effect on already-seeded DB properties.
- The **reserved set stays XML-only** and is always read from the file:
  `database.*` connection settings, `connectionProvider.className`, `fqdn`,
  `locale`, `adminConsole.*`, `setup`.
- Properties listed in `security.xml` under `<encrypt><property>` are encrypted
  on first use.

Used heavily by
[openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider)
(`provider.auth.className`, `ldap.*`, `adAuth.*`) — the gitops chart renders all
of this from Helm values.

## Performance & sizing

The `JAVA_OPTS` in the Containerfile are container-aware
(`-XX:+UseContainerSupport`, `-XX:MaxRAMPercentage=60.0`, `-XX:MaxDirectMemorySize=1g`, G1GC,
`-XX:+ExitOnOutOfMemoryError`). Heap follows the container memory limit (60%;
the rest is reserved for Netty's direct TLS buffers, metaspace and stacks —
capping direct memory matters because the JVM default equals the heap size and
heap+native would exceed the cgroup limit). The gitops chart sizes per
concurrency tier — see
[openfire-gitops › scaling](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/scaling.md).

For large deployments, size against the
[Openfire Scalability paper](https://www.igniterealtime.org/about/OpenfireScalability.pdf)
(≈ 2 GB heap sustained 50k+ concurrent sessions on a single node) — raise the
container memory limit and heap. That paper also recommends `ulimit -n 65535`,
which **cannot be set from inside the container** — configure it on the node
(OpenShift: a `Tuned`/`MachineConfig`). A single well-tuned node scales far;
multi-node clustering is a separate step
([openfire-gitops › Scaling](https://gitlab.com/mkoese/openfire-gitops#scaling-beyond-one-node-clustering)).

Override `JAVA_OPTS` entirely via the environment variable (the gitops chart
exposes `javaOpts`).

# Security model

What makes this image safe to run under a locked-down SCC, and the supply-chain
guarantees of the build. For the deployment-side controls (NetworkPolicy,
secrets, TLS, `readOnlyRootFilesystem`) see
[openfire-gitops › Security](https://gitlab.com/mkoese/openfire-gitops#security).

## Runs as an arbitrary non-root UID

The image is built for the OpenShift `restricted-v2` SCC, where the container
runs as a **random UID** (e.g. `1000850000`) that is a member of **GID 0**, and
is **not** the file owner. That imposes two rules, both satisfied here:

- **`USER 1001`** is numeric — there is no dependency on a matching entry in
  `/etc/passwd`, so an arbitrary UID starts fine.
- **Everything Openfire writes is group-0 writable.** `/opt/openfire` is created
  `chown 1001:0 chmod 775`, and the tree is copied with
  `COPY --chown=1001:0 --chmod=775`. The `embedded-db/` and `logs/` directories
  are pre-created in the builder stage so they inherit that mode too — otherwise
  `VOLUME` would auto-create `embedded-db` at `0755` (owner-only write) and the
  server would `CrashLoopBackOff` under a random UID.

Everything the server writes stays under `/opt/openfire` (config, embedded DB,
plugins, security stores, logs) — all mounted volumes in a real deployment — so
the image is also compatible with `readOnlyRootFilesystem: true` (opt-in in the
gitops chart).

## Non-root, minimal, no SUID

- Final stage runs as **`USER 1001`**, never root.
- **Multi-stage build** — the builder (with `tar`, shell scripting) is discarded;
  the runtime is the minimal `openjdk-17-runtime` base plus one application layer.
- The bundled JRE and documentation are **stripped**, shrinking attack surface.
- No SUID/SGID binaries are added.

## Supply chain (pinned inputs)

Every external input is pinned by **sha256** and verified during the build:

- The **Openfire tarball** — verified *inside* the build: `OPENFIRE_SHA256` is
  a mandatory build arg checked with `sha256sum -c` in the builder stage, so
  CI, local, and airgapped builds all refuse unverified bytes.
- **Plugins and libs** — `plugins.txt` / `lib.txt` use `name|url|sha256`; each
  download is verified in the loop.
- **Base images** — pinned by **digest** (`ubi9/ubi:9.8@sha256:…`,
  `openjdk-17-runtime:1.24@sha256:…`) — Red Hat rebuilds tags in place, the
  digest makes the build reproducible. Digests are bumped deliberately (see
  [openfire-gitops › upgrading](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/upgrading.md)).

Because the pins are **content-addressed**, the URL is not trusted — only the
bytes. This means:

- A mirror (including an airgapped internal mirror) is a drop-in with **no loss
  of assurance** — tampered bytes fail the checksum.
- The GitLab CI download blocks use `set -euo pipefail` so a checksum failure on
  *any* artifact aborts the build (GitLab otherwise reports only the last exit
  code of a multi-line block).

## No secrets in the image

The image contains **no credentials at all**. The baked-in `conf/openfire.xml`
has no `<autosetup>` block and no admin password — first boot serves the setup
wizard, where the admin password is chosen. Unattended setups mount their own
config (local dev: an `<autosetup>` file, see
[configuration.md](configuration.md#first-boot); production: the gitops chart
injects credentials from Kubernetes secrets). Nothing sensitive is `COPY`'d or
set via `ENV`.

## Vulnerability scanning & rebuild policy

Both pipelines end with a **trivy gate** that fails the build on **fixable**
CRITICAL/HIGH CVEs in the pushed image (`--ignore-unfixed`: CVEs without a
released Red Hat fix are reported but not blocking — a rebuild cannot help).
Temporary exceptions live in [`.trivyignore`](../.trivyignore) with a dated
comment (fix released, pinned base not yet rebuilt) — the file must shrink to
empty with every base-digest bump. The scanner runs as a **digest-pinned
container** (`aquasec/trivy:0.72.0@sha256:cffe3f51…`), not via the
`trivy-action` — the March 2026 tag-hijack of that action is exactly the
mutable-tag risk this repo avoids. Independently of the pipeline, Quay scans
every pushed image with Clair — the security tab in the Quay UI is a second
opinion from a different scanner.

The runtime base (`openjdk-17-runtime`) is rebuilt by Red Hat when CVEs land;
this image only picks that up on rebuild. Policy:

- **Rebuild at least monthly**: bump the base-image digests (they're pinned —
  see the upgrading runbook) and empty `.trivyignore`, then push. The build
  job prints the new image **digest**; deploy it by pinning `image.digest` in
  openfire-gitops `envs/*.yaml` (dev picks up the rolled `main` tag by itself).
- **Rebuild immediately** when the trivy gate starts failing or a base-image /
  Openfire security advisory lands — the emergency path is the
  [CVE response runbook](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/upgrading.md#cve-response-log4shell-class).
- Version bumps follow [openfire-gitops › upgrading](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/upgrading.md).

## JVM security hardening

`JAVA_OPTS` in the image sets, among the container-tuning flags:

- `-Dlog4j2.formatMsgNoLookups=true` — **Log4Shell (CVE-2021-44228) mitigation**
  (belt-and-suspenders alongside the container log4j2 config).
- `-Djava.security.egd=file:/dev/urandom` — non-blocking entropy for TLS
  handshakes.
- `-XX:+ExitOnOutOfMemoryError` — fail fast instead of running degraded.

## Health

`HEALTHCHECK` curls `http://localhost:9090/login.jsp`. It works as the
non-root user (curl needs no privileges). On Kubernetes/OpenShift the image
`HEALTHCHECK` is ignored in favour of the chart's startup/liveness/readiness
probes — it's there for plain Podman runs. The build uses
`buildah --format docker` so the instruction is preserved (the OCI format drops
it).

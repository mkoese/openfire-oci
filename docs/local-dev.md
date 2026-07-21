# Local developer environment

Build, run, and iterate on the image locally with Podman (Docker works the same).

## Prerequisites

- `podman` (or `docker`) — `buildah`/`skopeo` optional but handy
- `curl`, `shasum` (macOS) / `sha256sum` (Linux)
- ~2 GB free disk for base images + tarball

## One-shot build

See [build.md › Local build](build.md#1-local-build) for the canonical steps
(fetch pinned inputs, `podman build`). TL;DR:

```bash
VERSION=5.1.1
SHA256=d930be11c93c995ee0a045118d0539629bd27d983ad99e6f174ded6453612a0d  # official tarball sha256
VERSION_FILE=$(echo "$VERSION" | tr '.' '_')
curl -fsSL -o "openfire_${VERSION_FILE}.tar.gz" \
  "https://github.com/igniterealtime/Openfire/releases/download/v${VERSION}/openfire_${VERSION_FILE}.tar.gz"
podman build --build-arg OPENFIRE_VERSION=$VERSION --build-arg OPENFIRE_SHA256=$SHA256 \
  -t openfire-oci:$VERSION .
```

Plugins/libs are optional for a local build — an empty `plugins/` and `lib/` are
fine. To test with the PostgreSQL driver / auth provider, fetch them first (the
`for list in plugins lib` loop in build.md).

## Run and iterate

```bash
podman run -d --name openfire -p 127.0.0.1:9090:9090 -p 5222:5222 openfire-oci:5.1.1
podman logs -f openfire
# → http://localhost:9090  (setup wizard on first boot — choose the admin password there)
```

For an unattended first boot (no wizard), mount a config with an `<autosetup>`
block — see [configuration.md › First boot](configuration.md#first-boot).

**Enable debug/trace logging locally** — the same env vars used in the cluster
work with `podman -e` (no rebuild):

```bash
podman run -d --name openfire -p 127.0.0.1:9090:9090 \
  -e OPENFIRE_LOG_LEVEL=debug \
  -e OPENFIRE_LOG_LEVEL_AUTH=trace \
  openfire-oci:5.1.1
podman logs -f openfire | grep -i "com.mkoese\|DEBUG"
```

Full level reference: [logging.md](logging.md).

Fast edit loop:

```bash
podman rm -f openfire
podman build --build-arg OPENFIRE_VERSION=$VERSION --build-arg OPENFIRE_SHA256=$SHA256 \
  -t openfire-oci:$VERSION .
podman run -d --name openfire -p 127.0.0.1:9090:9090 -p 5222:5222 openfire-oci:5.1.1
```

## Test a config / plugin / lib change

- **Custom `openfire.xml`** — mount over the baked-in one:
  ```bash
  podman run -d --name openfire -p 127.0.0.1:9090:9090 \
    -v "$(pwd)/conf/openfire.xml:/opt/openfire/conf/openfire.xml:Z" openfire-oci:5.1.1
  ```
- **A new plugin** — add a `name|url|sha256` line to `plugins.txt`, refetch, rebuild.
- **A server-classpath JAR** (JDBC driver, auth provider) — add to `lib.txt`,
  refetch, rebuild. Confirm it landed:
  ```bash
  podman run --rm openfire-oci:5.1.1 ls /opt/openfire/lib | grep -E 'postgresql|authprovider'
  ```

## Simulate the OpenShift arbitrary UID locally

Rootless Podman remaps `--user` to the owner, which **hides** arbitrary-UID
permission bugs. To reproduce the OpenShift `restricted-v2` behavior (random UID,
GID 0, not the owner):

```bash
podman run --rm --user 1234:0 openfire-oci:5.1.1 \
  sh -c 'id && touch /opt/openfire/embedded-db/test && echo "writable OK"'
```

See [security.md › arbitrary UID](security.md#runs-as-an-arbitrary-non-root-uid).

## Lint the Containerfile

```bash
podman run --rm -i docker.io/hadolint/hadolint < Containerfile
```

## Clean up

```bash
podman rm -f openfire
podman rmi openfire-oci:5.1.1
rm -f openfire_*.tar.gz && rm -rf plugins lib
```

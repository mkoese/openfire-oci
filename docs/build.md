# Image build

How the image is assembled, layer by layer, and the three ways to build it.

## Multi-stage architecture

The [`Containerfile`](../Containerfile) has two stages so no build tooling ends
up in the shipped image:

### Stage 1 — builder (`ubi9/ubi:9.8`)

Assembles a ready-to-run `/opt/openfire` tree:

1. **Validate + extract** the `openfire_<version>.tar.gz` from the build context.
   The tarball is a **bind mount** (`--mount=type=bind`), not a `COPY`, so the
   ~100 MB archive never becomes an image layer.
2. **Strip** the bundled JRE (`/opt/openfire/jre`) and `documentation/` — the
   runtime base already provides OpenJDK 17, and docs have no place in a server
   image.
3. **Overlay config** — replace `lib/log4j2.xml` with the container variant
   (logs to stdout) and drop in the default `conf/openfire.xml`.
4. **Overlay plugins/libs** — copy any JARs staged in `plugins/` and `lib/`
   (see [Pinned inputs](#pinned-inputs)).
5. **Pre-create writable dirs** — `embedded-db/` and `logs/` are made here so the
   later `COPY --chmod` grants them group-0 write (see
   [security › arbitrary UID](security.md#runs-as-an-arbitrary-non-root-uid)).

All of the above is a **single `RUN`** — one layer for the whole assembly step,
and `/tmp` is cleaned in the same layer so nothing leaks into it.

### Stage 2 — runtime (`ubi9/openjdk-17-runtime:1.24`)

Almost pure metadata on top of the base. The **only filesystem layer added** is
one `COPY --from=builder`:

```dockerfile
COPY --from=builder --chown=1001:0 --chmod=775 /opt/openfire/ ${OPENFIRE_HOME}/
```

Everything else — `LABEL`, `ENV`, `VOLUME`, `EXPOSE`, `HEALTHCHECK`, `USER`,
`WORKDIR`, `ENTRYPOINT` — is metadata, so the runtime image is base + one layer.

## Pinned inputs

Build inputs are pinned in two `name|url|sha256` lists, verified during every
build. Because they are **content-addressed**, a mirror URL is fine as long as
the bytes match — the `sha256sum -c` doubles as tamper detection (see
[security › supply chain](security.md#supply-chain-pinned-inputs)).

| List | Destination | Purpose |
|------|-------------|---------|
| [`plugins.txt`](../plugins.txt) | `/opt/openfire/plugins/` | Openfire plugins ([browse](https://www.igniterealtime.org/projects/openfire/plugins.jsp)) |
| [`lib.txt`](../lib.txt) | `/opt/openfire/lib/` | server classpath: JDBC drivers, custom auth providers |
| [`exclude.txt`](../exclude.txt) | removed from `/opt/openfire/lib/` | bundled JARs dropped at build time (unused DB drivers — PostgreSQL-only) |

> Custom `AuthProvider`s must live in `lib/`, **not** a plugin — providers load
> before plugins. See [openfire-authprovider](https://gitlab.com/mkoese/openfire-authprovider).

## Build args

| Arg | Default | Purpose |
|-----|---------|---------|
| `OPENFIRE_VERSION` | `5.1.1` | selects the tarball filename `openfire_<v>.tar.gz` and the image version label |
| `OPENFIRE_SHA256` | *(none — required)* | sha256 of the tarball, verified inside the build; a missing or wrong value fails the build |
| `OPENFIRE_DOWNLOAD_BASE_URL` | GitHub releases | only used in the "download it first" error hint |

---

## 1. Local build

On a machine with internet, fetch the pinned inputs, then build with Podman:

```bash
VERSION=5.1.1
SHA256=d930be11c93c995ee0a045118d0539629bd27d983ad99e6f174ded6453612a0d  # official tarball sha256
VERSION_FILE=$(echo "${VERSION}" | tr '.' '_')

# Openfire tarball (the build itself verifies it against OPENFIRE_SHA256)
curl -fsSL -o "openfire_${VERSION_FILE}.tar.gz" \
  "https://github.com/igniterealtime/Openfire/releases/download/v${VERSION}/openfire_${VERSION_FILE}.tar.gz"

# Plugins + server-classpath JARs (optional -- build succeeds without them)
for list in plugins lib; do
  mkdir -p "$list"
  while IFS='|' read -r name url sha256; do
    [ -z "$name" ] && continue
    curl -fsSL -o "${list}/${name}.jar" "$url"
    echo "${sha256}  ${list}/${name}.jar" | shasum -a 256 -c -
  done < "${list}.txt"
done

podman build --platform linux/amd64 \
  --build-arg OPENFIRE_VERSION=${VERSION} \
  --build-arg OPENFIRE_SHA256=${SHA256} \
  -t openfire-oci:${VERSION} .
```

## 2. GitLab CI (with internet)

[`.gitlab-ci.yml`](../.gitlab-ci.yml) runs on push to the default branch, any
tag, or a manual run: downloads + sha256-verifies plugins/libs, `buildah build`
(`--format docker` so `HEALTHCHECK` survives — the tarball checksum is verified
*inside* the build via `OPENFIRE_SHA256`), pushes to the registry, then a
`scan-image` job (digest-pinned trivy, `--ignore-unfixed` + [`.trivyignore`](../.trivyignore))
fails the pipeline on fixable CRITICAL/HIGH CVEs.

**Setup** — *Settings › CI/CD › Variables*:
- `QUAY_USERNAME` — registry robot/username
- `QUAY_PASSWORD` — token/password (**masked**)

Image tags follow the **UBI model** — tags for humans, digests for clusters:
every build pushes a unique `<version>-<iid>-<jobid>` tag (write-only; keeps
the digest referenced, Quay garbage-collects untagged digests) and **rolls**
`<version>` (e.g. `5.1.1`) to the newest build; branch builds also roll
`main` (dev follows it). Deployments pin the **digest** the build job prints
(`image.digest` in openfire-gitops `envs/*.yaml`) — rolling a tag can never
change what prod runs. A GitHub Actions mirror
(`.github/workflows/build.yml`) pushes its own unique tags against a `quay`
environment holding the two secrets.

## 3. Airgapped GitLab (self-hosted, no internet)

The runner has no internet; everything comes from your internal registry and
GitLab. See **[airgapped-setup.md](airgapped-setup.md)** for the full procedure
(mirror base images + pinned artifacts, registry push, private CA).

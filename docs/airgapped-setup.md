# Airgapped image build

Building the image where the CI runner has **no internet** — everything is
served from your internal registry and GitLab. Do the mirroring once on a
connected host, then wire the internal pipeline.

Related: [openfire-authprovider airgapped setup](https://gitlab.com/mkoese/openfire-authprovider/-/blob/main/docs/airgapped-setup.md)
(the JAR that goes into `lib.txt`) and
[openfire-gitops airgapped setup](https://gitlab.com/mkoese/openfire-gitops/-/blob/main/docs/airgapped-setup.md)
(deploying it).

## 1. Mirror the base images

```bash
skopeo copy docker://registry.access.redhat.com/ubi9/ubi:9.8 \
  docker://registry.internal/ubi9/ubi:9.8
skopeo copy docker://registry.access.redhat.com/ubi9/openjdk-17-runtime:1.24 \
  docker://registry.internal/ubi9/openjdk-17-runtime:1.24
skopeo copy docker://registry.access.redhat.com/ubi9/buildah:9.8 \
  docker://registry.internal/ubi9/buildah:9.8    # the CI builder image itself
```

Resolve the internal copies **without editing the `Containerfile`** (keeps
`FROM` pinned to the upstream names) via the runner's
`containers-registries.conf`:

```toml
[[registry]]
location = "registry.access.redhat.com"
[[registry.mirror]]
location = "registry.internal"
```

## 2. Mirror the pinned artifacts

Mirror the Openfire tarball and the plugin/lib JARs to an internal HTTP host or
the GitLab **generic package registry**, then commit an internal-URL variant of
`plugins.txt` / `lib.txt`.

- The **sha256 values do not change** — the lists are content-addressed, so
  mirrored bytes are verified automatically and the download loop is unchanged.
  A tampered mirror fails the `sha256sum -c` check.
- For the tarball, override `OPENFIRE_DOWNLOAD_BASE_URL` in CI variables instead
  of editing anything.

Example — pushing a JAR to the GitLab generic package registry:

```bash
curl --header "JOB-TOKEN: ${CI_JOB_TOKEN}" --upload-file postgresql-42.7.13.jar \
  "${CI_API_V4_URL}/projects/<id>/packages/generic/deps/1/postgresql-42.7.13.jar"
```

## 3. Registry push

Point the push at the internal registry: set `REPOSITORY`, `QUAY_USERNAME`,
`QUAY_PASSWORD` CI variables accordingly. For an internal registry with a
private CA, **mount the CA** into the buildah image rather than disabling TLS
verification.

## Why airgapping doesn't weaken security

Every build input — base images (explicit tags), Openfire tarball
(`OPENFIRE_SHA256`), plugins/libs (`sha256` per line) — is pinned and verified.
The URL is never trusted, only the bytes. An airgapped mirror is therefore a
**drop-in with no loss of assurance**. See [security.md](security.md#supply-chain-pinned-inputs).

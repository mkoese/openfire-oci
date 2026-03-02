# Openfire OCI

Openfire XMPP server on Red Hat UBI9 OpenJDK 17.

## Overview

| | |
|---|---|
| **Base image** | `ubi9/openjdk-17-runtime:1.24` |
| **Image size** | ~478 MB (89% efficiency) |
| **Openfire** | 4.8.2 |
| **Java** | OpenJDK 17 |
| **User** | 1001:0 (OpenShift arbitrary UID compatible) |

**Build options:**

| Method | Target registry | Trigger |
|--------|----------------|---------|
| [Podman (local)](#podman-local) | Local | Manual |
| [GitHub Actions](#github-actions) | Quay.io | Push to `main`, tag, manual |
| [GitLab CI](#gitlab-ci) | Quay.io | Push to default branch, tag, manual |
| [OpenShift Pipelines](#openshift-pipelines-tekton) | Internal registry | Manual (`oc create`) |

**Deploy options:**

| Method | Use case |
|--------|----------|
| [Podman](#podman) | Local development / testing |
| [Quadlet (systemd)](#quadlet-systemd-single-node) | Single-node production |
| [OpenShift / Kubernetes](#openshift--kubernetes) | Cluster deployment |

## Ports

| Port | Description                       |
|------|-----------------------------------|
| 5222 | XMPP client (STARTTLS)            |
| 5223 | XMPP client (Direct TLS)          |
| 5269 | Server-to-server (STARTTLS)       |
| 5270 | Server-to-server (Direct TLS)     |
| 5275 | External components (STARTTLS)    |
| 5276 | External components (Direct TLS)  |
| 7070 | BOSH / WebSocket (HTTP)           |
| 7443 | BOSH / WebSocket (HTTPS)          |
| 7777 | File transfer proxy               |
| 9090 | Admin console (HTTP)              |
| 9091 | Admin console (HTTPS)             |

## Configuration

The image ships with `conf/openfire.xml` using Openfire's `<autosetup>` feature -- embedded H2 database, domain `localhost`, admin `admin`/`admin`. On first start it initializes the DB, creates the admin account, and is ready to go.

> **Default credentials are for development only. Always mount your own config for production.**

For production, mount your own `openfire.xml` containing either:

- `<autosetup>` block -- first-run automatic setup (see `conf/openfire.xml` for the full example)
- `<setup>true</setup>` -- already-configured instance (DB schema must exist)

Helm chart users can control outbound update checks via values:

```yaml
update:
  serviceEnabled: false
  notifyAdmins: false
  rssEnabled: false
```

These settings are written into the generated `openfire.xml` secret. On Openfire `4.8.x`, this maps to the hyphenated runtime properties `update.service-enabled` and `update.notify-admins`.
If Openfire was already initialized with persistent data, the existing DB properties may still apply until you reset/update those stored properties.

To auto-enable the REST API plugin at startup (when the REST API plugin JAR is present), set:

```yaml
restApi:
  autoEnable: true
  allowWildcardsInExcludes: true
  httpAuth: basic # or "secret"
  # secret: "replace-me-when-using-secret-auth"
  # allowedIPs:
  #   - 10.0.0.10
  serviceLoggingEnabled: false
```

This writes `plugin.restapi.*` properties into `openfire.xml`, including `plugin.restapi.enabled=true`.

---

## Build

Three pipeline approaches are available. All produce the same image.

### Prerequisites

Download the Openfire tarball and plugins before building. CI/CD pipelines (GitHub Actions, GitLab CI, Tekton) handle this automatically using `plugins.txt`.

```bash
# Openfire tarball
VERSION=4.8.2
VERSION_FILE=$(echo "${VERSION}" | tr '.' '_')
PRIMARY_URL="https://github.com/igniterealtime/Openfire/releases/download/v${VERSION}/openfire_${VERSION_FILE}.tar.gz"
FALLBACK_URL="https://www.igniterealtime.org/downloadServlet?filename=openfire/openfire_${VERSION_FILE}.tar.gz"
curl -fsSL -o "openfire_${VERSION_FILE}.tar.gz" "${PRIMARY_URL}" || \
  curl -fsSL -o "openfire_${VERSION_FILE}.tar.gz" "${FALLBACK_URL}"

# Plugins (optional -- build succeeds without them)
mkdir -p plugins
while IFS='|' read -r name url; do
  [ -z "$name" ] && continue
  curl -fsSL -o "plugins/${name}.jar" "$url"
done < plugins.txt
```

`plugins.txt` format is `name|url` per line. Empty lines and lines starting with `#` are ignored:

```
# Optional plugins for local and CI builds
userstatus|https://igniterealtime.org/projects/openfire/plugins/1.3.0/userstatus.jar
```

Browse available plugins at https://www.igniterealtime.org/projects/openfire/plugins.jsp. Plugin JARs are git-ignored.

### Makefile (local OpenShift development)

For local development workflows against a local OpenShift cluster (for example CRC), use the repository `Makefile`.
It mirrors pipeline plugin download logic (`plugins.txt` format `name|url`) and is intended for local interaction only.

```bash
# Download plugins from plugins.txt (name|url)
make download-plugins

# Download Openfire tarball for OPENFIRE_VERSION
make download-openfire

# Download both plugins and tarball
make prepare

# Build locally (prefers Podman, falls back to Docker)
make build

# Build and push image to the local OpenShift registry (openfire-build namespace)
make push-local-image

# Clean local build artifacts (downloaded plugins/tarball and local image)
make clean

# Deploy to local OpenShift
make deploy-local

# Reset Openfire PVCs (destructive: removes embedded DB/plugins data)
make clean-local

# Reset Openfire PVCs and deploy clean
make deploy-local-clean

# Destroy Openfire + Postgres namespaces (destructive)
make destroy-local-all

# Deploy Openfire with PostgreSQL (creates postgres via Helm, deploys Openfire, applies postgres openfire-conf)
make deploy-local-postgres

# Re-apply PostgreSQL openfire-conf and restart Openfire (if deploy-local was run afterwards)
make openfire-conf-postgres
```

#### Deployment goal chains

Use these `make` chains for predictable local deployments:

```bash
# Openfire with embedded DB (no Postgres)
make push-local-image && make deploy-local-clean

# Openfire with PostgreSQL
make destroy-local-all && make push-local-image && make deploy-local-postgres
```

Notes:
- `make deploy-local` applies the chart default `openfire-conf` (embedded DB).
- For PostgreSQL deployments, use `make deploy-local-postgres` (or run `make openfire-conf-postgres` after `make deploy-local`).

Optionally pre-pull base images to speed up local builds:

```bash
podman pull registry.access.redhat.com/ubi9/ubi:9.5
podman pull registry.access.redhat.com/ubi9/openjdk-17-runtime:1.24
```

For air-gapped environments, download all artifacts on a connected machine:

```bash
# Base images (skopeo -- no daemon required)
skopeo copy docker://registry.access.redhat.com/ubi9/ubi:9.5 docker-archive:ubi9.tar
skopeo copy docker://registry.access.redhat.com/ubi9/openjdk-17-runtime:1.24 docker-archive:ubi9-openjdk-17-runtime.tar

# Openfire tarball and plugins (same curl commands as above)
```

Transfer all files to the air-gapped machine, then load into a local registry:

```bash
skopeo login --tls-verify=false registry.example.com
skopeo copy --dest-tls-verify=false docker-archive:ubi9.tar docker://registry.example.com/ubi9/ubi:9.5
skopeo copy --dest-tls-verify=false docker-archive:ubi9-openjdk-17-runtime.tar docker://registry.example.com/ubi9/openjdk-17-runtime:1.24
```

### Podman (local)

```bash
podman build --platform linux/amd64 \
  --build-arg OPENFIRE_VERSION=${VERSION} \
  -t openfire-oci:${VERSION} .
```

### GitHub Actions

Triggers automatically on push to `main`, any tag, or manual dispatch. Builds and pushes to Quay.io.

**Setup:**

1. Create environment `quay` under **Settings > Environments**
2. Add secrets `QUAY_USERNAME` and `QUAY_PASSWORD` to the `quay` environment

**Manual trigger with custom tag:**

Go to **Actions > Build and Push > Run workflow** and optionally provide an image tag (defaults to `OPENFIRE_VERSION`).

### GitLab CI

Triggers automatically on push to default branch, any tag, or manual run. Builds and pushes to Quay.io.

**Setup:**

Add CI/CD variables under **Settings > CI/CD > Variables**:
- `QUAY_USERNAME` -- Quay.io robot account or username
- `QUAY_PASSWORD` -- Quay.io robot account token or password (masked)

### OpenShift Pipelines (Tekton)

In-cluster build using the Tekton Pipelines Operator. Builds and pushes to the internal OpenShift registry.

> **Prerequisite:** [OpenShift Pipelines Operator](https://docs.openshift.com/container-platform/4.16/cicd/pipelines/installing-pipelines.html) must be installed.

```bash
# Apply build namespace, ImageStream, Pipeline, and plugin ConfigMap
helm template openfire-build ./deploy/charts/openfire-build | oc apply -f -

# Allow pipeline SA to push images to the internal registry
oc policy add-role-to-user system:image-builder \
  system:serviceaccount:openfire-build:pipeline -n openfire-build

# Trigger a pipeline run
helm template openfire-build ./deploy/charts/openfire-build \
  --set pipelineRun.enabled=true \
  --show-only templates/pipelinerun.yaml | oc create -f -
```

---

## Deploy

### Podman

```bash
podman run -d --name openfire \
  -p 9090:9090 -p 9091:9091 \
  -p 5222:5222 -p 5223:5223 \
  -v $(pwd)/deploy/quadlet/conf:/opt/openfire/conf:Z \
  openfire-oci:4.8.2
```

Open http://localhost:9090 and log in with `admin` / `admin`.

### Quadlet (systemd, single-node)

```bash
sudo cp deploy/quadlet/openfire.container /etc/containers/systemd/
sudo mkdir -p /var/lib/openfire/{conf,embedded-db,plugins,security}
sudo cp deploy/quadlet/conf/openfire.xml /var/lib/openfire/conf/
sudo systemctl daemon-reload
sudo systemctl start openfire.service
```

Firewall:

```bash
sudo firewall-cmd --zone=internal --add-port={9090,9091,5222,5223}/tcp --permanent
sudo firewall-cmd --reload
```

### OpenShift / Kubernetes

```bash
# Allow openfire namespace to pull images from openfire-build
oc policy add-role-to-group system:image-puller system:serviceaccounts:openfire -n openfire-build

# Apply openfire namespace and deployment resources
helm template openfire ./deploy/charts/openfire \
  -f ./deploy/charts/openfire/values-openshift.yaml | oc apply -f -
```

---

## Operations

### Podman

| Action | Command |
|--------|---------|
| Logs | `podman logs -f openfire` |
| Stop | `podman stop openfire` |
| Start | `podman start openfire` |
| Restart | `podman restart openfire` |
| Redeploy (new image) | `podman stop openfire && podman rm openfire` then `podman run ...` (see Deploy above) |

### Quadlet (systemd)

| Action | Command |
|--------|---------|
| Logs | `journalctl -u openfire.service -f` |
| Stop | `sudo systemctl stop openfire.service` |
| Start | `sudo systemctl start openfire.service` |
| Restart | `sudo systemctl restart openfire.service` |
| Redeploy (new image) | `sudo systemctl stop openfire.service && podman pull openfire-oci:4.8.2 && sudo systemctl start openfire.service` |

### OpenShift / Kubernetes

| Action | Command |
|--------|---------|
| Logs | `oc logs -f deployment/openfire-openfire -n openfire` |
| Init container logs | `oc logs deployment/openfire-openfire -n openfire -c init-conf` |
| Stop (scale down) | `oc scale deployment/openfire-openfire -n openfire --replicas=0` |
| Start (scale up) | `oc scale deployment/openfire-openfire -n openfire --replicas=1` |
| Restart | `oc rollout restart deployment/openfire-openfire -n openfire` |
| Rollout status | `oc rollout status deployment/openfire-openfire -n openfire` |
| Rollback | `oc rollout undo deployment/openfire-openfire -n openfire` |
| Redeploy (re-trigger build) | `helm template openfire-build ./deploy/charts/openfire-build --set pipelineRun.enabled=true --show-only templates/pipelinerun.yaml \| oc create -f -` |
| Pipeline logs | `tkn pipelinerun logs <run-name> -n openfire-build -f` |

---

## License

This project is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Mikail Koese.

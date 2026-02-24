# 🔥 Openfire OCI

Openfire XMPP server on Red Hat UBI9 OpenJDK 17.

## 🚀 Quick Start

```bash
podman build -t openfire-oci:5.0.3 .
podman run -d --name openfire -p 9090:9090 openfire-oci:5.0.3
```

Open http://localhost:9090 and log in with `admin` / `admin`. No setup wizard — the image auto-configures on first start.

## 📦 Ports

| Container | Host (example) | Description                       |
|-----------|----------------|-----------------------------------|
| 5222      | 15222          | XMPP client (STARTTLS)            |
| 5223      | 15223          | XMPP client (Direct TLS)          |
| 5269      | 5269           | Server-to-server (STARTTLS)       |
| 5270      | 5270           | Server-to-server (Direct TLS)     |
| 5275      | 5275           | External components (STARTTLS)    |
| 5276      | 5276           | External components (Direct TLS)  |
| 7070      | 7070           | Web binding (BOSH/WebSocket)      |
| 7443      | 7443           | Web binding (BOSH/WebSocket, TLS) |
| 7777      | 7777           | File transfer proxy               |
| 9090      | 19090          | Admin console (HTTP)              |
| 9091      | 19091          | Admin console (HTTPS)             |

## ⚙️ Configuration

The image ships with `conf/openfire.xml` using Openfire's `<autosetup>` feature — embedded H2 database, domain `localhost`, admin `admin`/`admin`. On first start it initializes the DB, creates the admin account, and is ready to go.

> ⚠️ **Default credentials are for development only. Always mount your own config for production.**

For production, mount your own `openfire.xml` containing either:

- `<autosetup>` block — first-run automatic setup (see `conf/openfire.xml` for the full example)
- `<setup>true</setup>` — already-configured instance (DB schema must exist)

### 🐳 Podman / Quadlet

Bind-mount a directory with your config:

```bash
podman run -d --name openfire \
  -v /path/to/your/conf:/opt/openfire/conf:Z \
  openfire-oci:5.0.3
```

### ☸️ Kubernetes / OpenShift

Config lives in a Secret. An initContainer copies it to a writable `emptyDir` before Openfire starts (K8s Secret volumes are read-only). Config changes require a pod restart:

```bash
oc rollout restart deployment/<release>-openfire
```

## Plugins

Plugins can be baked into the image at build time. Download `.jar` files into the `plugins/` directory before building:

```bash
# Example: User Status plugin
curl -fsSL -o plugins/userstatus.jar \
  https://igniterealtime.org/projects/openfire/plugins/1.3.0/userstatus.jar
```

Any `.jar` files in `plugins/` are copied into the image during build. If the directory is empty, the build still succeeds. Plugin jars are git-ignored so they won't be committed.

Browse available plugins at https://www.igniterealtime.org/projects/openfire/plugins.jsp.

## 🛠️ Build

```bash
# Download Openfire
curl -fsSL -o openfire_5_0_3.tar.gz \
  https://github.com/igniterealtime/Openfire/releases/download/v5.0.3/openfire_5_0_3.tar.gz

# Build
podman build --platform linux/amd64 -t openfire-oci:5.0.3 .

# Different version
podman build --platform linux/amd64 \
  --build-arg OPENFIRE_VERSION=5.1.0 \
  --build-arg OPENFIRE_VERSION_FILE=5_1_0 \
  -t openfire-oci:5.1.0 .
```

### 🔒 Air-Gapped

```bash
# On connected machine
podman pull registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
podman save -o ubi9-openjdk-17-runtime.tar registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
curl -fsSL -o openfire_5_0_3.tar.gz \
  https://github.com/igniterealtime/Openfire/releases/download/v5.0.3/openfire_5_0_3.tar.gz

# Transfer files to air-gapped machine

# On air-gapped machine — build
podman load -i ubi9-openjdk-17-runtime.tar
podman build --platform linux/amd64 -t openfire-oci:5.0.3 .

# Push built image to an internal registry
podman save -o openfire-oci-5.0.3.tar openfire-oci:5.0.3
skopeo copy docker-archive:openfire-oci-5.0.3.tar \
  docker://internal-registry.local/openfire-oci:5.0.3
```

## 🖥️ Deploy

### Podman

```bash
podman run -d --name openfire \
  -p 19090:9090 -p 19091:9091 \
  -p 15222:5222 -p 15223:5223 \
  -v $(pwd)/deploy/quadlet/conf:/opt/openfire/conf:Z \
  openfire-oci:5.0.3
```

### Quadlet (systemd)

```bash
sudo cp deploy/quadlet/openfire.container /etc/containers/systemd/
sudo mkdir -p /var/lib/openfire/{conf,embedded-db,plugins,security}
sudo cp deploy/quadlet/conf/openfire.xml /var/lib/openfire/conf/
sudo systemctl daemon-reload
sudo systemctl start openfire.service
```

Firewall:

```bash
sudo firewall-cmd --zone=internal --add-port={19090,19091,15222,15223}/tcp --permanent
sudo firewall-cmd --reload
```

Logs: `journalctl -u openfire.service -f`

### OpenShift

#### 1. Build pipeline (Tekton)

```bash
# Apply namespace, ImageStream, and Pipeline
helm template openfire-build ./deploy/charts/openfire-build | oc apply -f -

# Create registry credentials for pushing to the internal registry
oc create secret docker-registry openfire-registry-credentials \
  --docker-server=image-registry.openshift-image-registry.svc:5000 \
  --docker-username=$(oc whoami) \
  --docker-password=$(oc whoami -t) \
  -n openfire-build

# Trigger a build (uses oc create because of generateName)
helm template openfire-build ./deploy/charts/openfire-build \
  --set pipelineRun.enabled=true \
  --show-only templates/pipelinerun.yaml | oc create -f -
```

#### 2. Deploy Openfire

```bash
# Allow openfire namespace to pull images from openfire-build
oc policy add-role-to-group system:image-puller \
  system:serviceaccounts:openfire -n openfire-build

# Deploy with OpenShift values (internal registry image, Route enabled)
helm template openfire ./deploy/charts/openfire \
  -f ./deploy/charts/openfire/values-openshift.yaml | oc apply -f -
```

#### 3. Manage

```bash
# Check status
oc get pods -n openfire
oc get route -n openfire

# Restart after config changes
oc rollout restart deployment/openfire-openfire -n openfire

# Re-trigger a build
helm template openfire-build ./deploy/charts/openfire-build \
  --set pipelineRun.enabled=true \
  --show-only templates/pipelinerun.yaml | oc create -f -
```

## 📄 License

This project is licensed under the [GPL-3.0 License](LICENSE). Copyright © 2026 Mikail Koese.

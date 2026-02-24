# Openfire OCI

Openfire XMPP server on Red Hat UBI9 OpenJDK 17.

| Metric | Value |
|--------|-------|
| Image size | ~478 MB |
| Efficiency | 89% |
| Wasted space | ~90 MB |

The base image (`ubi9/openjdk-17-runtime`) accounts for most of the size. The Openfire layer adds a single `COPY` from the multi-stage builder. This is the practical minimum for a UBI9 + OpenJDK 17 runtime -- further reduction would require switching to a distroless or Alpine base.

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

The image ships with `conf/openfire.xml` using Openfire's `<autosetup>` feature — embedded H2 database, domain `localhost`, admin `admin`/`admin`. On first start it initializes the DB, creates the admin account, and is ready to go.

> **Default credentials are for development only. Always mount your own config for production.**

For production, mount your own `openfire.xml` containing either:

- `<autosetup>` block — first-run automatic setup (see `conf/openfire.xml` for the full example)
- `<setup>true</setup>` — already-configured instance (DB schema must exist)

## Build

### 1. Pull required base images

```bash
podman pull registry.access.redhat.com/ubi9/ubi:9.5
podman pull registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
```

### 2. Prepare plugins (optional)

Download `.jar` files into the `plugins/` directory before building. Any JARs found there are baked into the image. The build succeeds even if the directory is empty.

```bash
curl -fsSL -o plugins/userstatus.jar \
  https://igniterealtime.org/projects/openfire/plugins/1.3.0/userstatus.jar
```

Browse available plugins at https://www.igniterealtime.org/projects/openfire/plugins.jsp. Plugin JARs are git-ignored.

### 3. Build the image

```bash
# Download Openfire tarball
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

#### Air-gapped build

```bash
# On connected machine
podman pull registry.access.redhat.com/ubi9/ubi:9.5
podman pull registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
podman save -o ubi9.tar registry.access.redhat.com/ubi9/ubi:9.5
podman save -o ubi9-openjdk-17-runtime.tar registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
curl -fsSL -o openfire_5_0_3.tar.gz \
  https://github.com/igniterealtime/Openfire/releases/download/v5.0.3/openfire_5_0_3.tar.gz

# Transfer files to air-gapped machine, then:
podman load -i ubi9.tar
podman load -i ubi9-openjdk-17-runtime.tar
podman build --platform linux/amd64 -t openfire-oci:5.0.3 .
```

## Podman

### Run

```bash
podman run -d --name openfire \
  -p 9090:9090 -p 9091:9091 \
  -p 5222:5222 -p 5223:5223 \
  -v $(pwd)/deploy/quadlet/conf:/opt/openfire/conf:Z \
  openfire-oci:5.0.3
```

Open http://localhost:9090 and log in with `admin` / `admin`.

### Stop

```bash
podman stop openfire
```

### Logs

```bash
podman logs -f openfire
```

### Restart with latest build

```bash
podman stop openfire && podman rm openfire
podman run -d --name openfire \
  -p 9090:9090 -p 9091:9091 \
  -p 5222:5222 -p 5223:5223 \
  -v $(pwd)/deploy/quadlet/conf:/opt/openfire/conf:Z \
  openfire-oci:5.0.3
```

## Quadlet (systemd, single-node)

### Create systemd service

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

### Restart

```bash
sudo systemctl restart openfire.service
```

### Logs

```bash
journalctl -u openfire.service -f
```

### Pull new image from latest build

```bash
sudo systemctl stop openfire.service
podman pull openfire-oci:5.0.3   # or your registry path
sudo systemctl start openfire.service
```

## OpenShift

> **Prerequisite:** The [OpenShift Pipelines Operator](https://docs.openshift.com/container-platform/4.16/cicd/pipelines/installing-pipelines.html) (Tekton) is required for in-cluster builds. If it is not installed, you can build locally and push the image to the cluster instead (see step 4).

### 1. Create namespaces and RBAC

```bash
# Apply build namespace, ImageStream, Pipeline, and plugin ConfigMap
helm template openfire-build ./deploy/charts/openfire-build | oc apply -f -

# Apply openfire namespace and deployment resources
helm template openfire ./deploy/charts/openfire \
  -f ./deploy/charts/openfire/values-openshift.yaml | oc apply -f -

# Allow openfire namespace to pull images from openfire-build
oc policy add-role-to-group system:image-puller \
  system:serviceaccounts:openfire -n openfire-build
```

### 2. Create registry credentials

```bash
oc create secret docker-registry openfire-registry-credentials \
  --docker-server=image-registry.openshift-image-registry.svc:5000 \
  --docker-username=$(oc whoami) \
  --docker-password=$(oc whoami -t) \
  -n openfire-build
```

### 3. Build with OpenShift Pipelines (requires Pipelines Operator)

```bash
# Trigger a pipeline run
helm template openfire-build ./deploy/charts/openfire-build \
  --set pipelineRun.enabled=true \
  --show-only templates/pipelinerun.yaml | oc create -f -

# Watch pipeline progress
oc -n openfire-build get pipelinerun -w
```

### 4. Push local image to OpenShift (alternative, no Pipelines Operator needed)

Expose the internal registry (one-time):

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge -p '{"spec":{"defaultRoute":true}}'
```

Login and push:

```bash
REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
podman login -u $(oc whoami) -p $(oc whoami -t) $REGISTRY
podman tag openfire-oci:5.0.3 $REGISTRY/openfire-build/openfire-oci:5.0.3
podman push $REGISTRY/openfire-build/openfire-oci:5.0.3
```

### 5. Rollout and manage

```bash
# Restart after config or image changes
oc rollout restart deployment/openfire-openfire -n openfire

# Watch rollout progress
oc rollout status deployment/openfire-openfire -n openfire

# Rollback to previous revision
oc rollout undo deployment/openfire-openfire -n openfire

# Re-trigger a pipeline build
helm template openfire-build ./deploy/charts/openfire-build \
  --set pipelineRun.enabled=true \
  --show-only templates/pipelinerun.yaml | oc create -f -
```

### 6. Logs

```bash
# Follow openfire pod logs
oc logs -f deployment/openfire-openfire -n openfire

# Check init container logs
oc logs deployment/openfire-openfire -n openfire -c init-conf

# Check pipeline task logs
oc -n openfire-build logs <pipelinerun-pod-name> -c step-download-plugins
```

## License

This project is licensed under the [GPL-3.0 License](LICENSE). Copyright 2026 Mikail Koese.

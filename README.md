# Openfire UBI Container

Openfire XMPP server on Red Hat UBI9 OpenJDK 17.

## Ports

| Port  | Protocol | Description              |
|-------|----------|--------------------------|
| 15222 | TCP      | XMPP client connections  |
| 15223 | TCP      | XMPP client (legacy SSL) |
| 5269  | TCP      | XMPP server-to-server    |
| 7070  | TCP      | HTTP binding (BOSH)      |
| 7443  | TCP      | HTTPS binding (BOSH)     |
| 19090 | TCP      | Admin console (HTTP)     |
| 19091 | TCP      | Admin console (HTTPS)    |

---

## 1. Local Development (Podman)

### Build

```bash
# Download Openfire
curl -fsSL -o openfire_5_0_3.tar.gz \
  https://github.com/igniterealtime/Openfire/releases/download/v5.0.3/openfire_5_0_3.tar.gz

# Build image
podman build --platform linux/amd64 -t openfire-ubi:5.0.3 .
```

### Run

```bash
podman run -d --name openfire \
  -p 19090:19090 \
  -p 19091:19091 \
  -p 15222:15222 \
  -v $(pwd)/deploy/quadlet/conf:/opt/openfire/conf:Z \
  openfire-ubi:5.0.3
```

### Air-Gapped Build

```bash
# On connected machine
podman pull registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
podman save -o ubi9-openjdk-17-runtime.tar registry.access.redhat.com/ubi9/openjdk-17-runtime:1.20
curl -fsSL -o openfire_5_0_3.tar.gz \
  https://github.com/igniterealtime/Openfire/releases/download/v5.0.3/openfire_5_0_3.tar.gz

# Transfer: ubi9-openjdk-17-runtime.tar, openfire_5_0_3.tar.gz, this repo

# On air-gapped machine
podman load -i ubi9-openjdk-17-runtime.tar
podman build --platform linux/amd64 -t openfire-ubi:5.0.3 .
```

---

## 2. Single Node Production (Quadlet)

Quadlet runs containers as systemd services — ideal for single-node deployments.

### Install

```bash
# Copy quadlet files
sudo cp deploy/quadlet/openfire.container /etc/containers/systemd/

# Create data directories and copy config
sudo mkdir -p /var/lib/openfire/{conf,embedded-db,plugins,security}
sudo cp deploy/quadlet/conf/openfire.xml /var/lib/openfire/conf/

# Reload and start
sudo systemctl daemon-reload
sudo systemctl start openfire.service
sudo systemctl enable openfire.service
```

### Firewall

```bash
sudo firewall-cmd --zone=internal --add-port=19090/tcp --permanent
sudo firewall-cmd --zone=internal --add-port=19091/tcp --permanent
sudo firewall-cmd --zone=internal --add-port=15222/tcp --permanent
sudo firewall-cmd --zone=internal --add-port=15223/tcp --permanent
sudo firewall-cmd --reload
```

### Logs

```bash
journalctl -u openfire.service -f
```

---

## 3. Cloud Native (OpenShift + Tekton)

### Build with Tekton

```bash
# Create pipeline resources
oc apply -f deploy/tekton/

# Start pipeline run
oc create -f deploy/tekton/pipelinerun.yaml
```

### Deploy with Helm

```bash
helm template openfire ./deploy/charts/openfire | oc apply -f -
```

With custom image registry:

```bash
helm template openfire ./deploy/charts/openfire \
  --set image.repository=image-registry.openshift-image-registry.svc:5000/openfire/openfire-ubi \
  | oc apply -f -
```

### Air-Gapped Image Transfer

```bash
# Export
podman save -o openfire-ubi-5.0.3.tar openfire-ubi:5.0.3

# Import to internal registry
skopeo copy \
  docker-archive:openfire-ubi-5.0.3.tar \
  docker://internal-registry.local/openfire-ubi:5.0.3
```

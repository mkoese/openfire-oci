# Local development helpers for a local OpenShift cluster (for example CRC).
# This Makefile is intentionally not used by CI/CD pipelines.

OPENFIRE_VERSION ?= 5.0.3
OPENFIRE_DOWNLOAD_BASE_URL ?= https://github.com/igniterealtime/Openfire/releases/download

IMAGE_NAME ?= openfire-oci
IMAGE_TAG ?= $(OPENFIRE_VERSION)
IMAGE ?= $(IMAGE_NAME):$(IMAGE_TAG)
CONTAINER_ENGINE ?= $(shell if command -v podman >/dev/null 2>&1; then echo podman; elif command -v docker >/dev/null 2>&1; then echo docker; fi)

.PHONY: download-plugins download-openfire prepare docker-build deploy-local

download-plugins:
	@sh ./scripts/download-plugins.sh plugins.txt plugins

download-openfire:
	@VERSION_FILE=$$(echo "$(OPENFIRE_VERSION)" | tr '.' '_'); \
	echo "Downloading Openfire $(OPENFIRE_VERSION)"; \
	curl -fsSL -o "openfire_$${VERSION_FILE}.tar.gz" \
		"$(OPENFIRE_DOWNLOAD_BASE_URL)/v$(OPENFIRE_VERSION)/openfire_$${VERSION_FILE}.tar.gz"

prepare: download-plugins download-openfire

docker-build: prepare
	@if [ -z "$(CONTAINER_ENGINE)" ]; then \
		echo "ERROR: neither podman nor docker is available in PATH."; \
		exit 1; \
	fi
	@echo "Building image with $(CONTAINER_ENGINE): $(IMAGE)"
	@$(CONTAINER_ENGINE) build --platform linux/amd64 \
		--build-arg OPENFIRE_VERSION="$(OPENFIRE_VERSION)" \
		-t "$(IMAGE)" .

deploy-local:
	@helm template openfire ./deploy/charts/openfire \
		-f ./deploy/charts/openfire/values-openshift.yaml | oc apply -f -

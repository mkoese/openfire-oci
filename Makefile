# Local development helpers for a local OpenShift cluster (for example CRC).
# This Makefile is intentionally not used by CI/CD pipelines.

OPENFIRE_VERSION ?= 5.0.3
OPENFIRE_DOWNLOAD_BASE_URL ?= https://github.com/igniterealtime/Openfire/releases/download

IMAGE_NAME ?= openfire-oci
IMAGE_TAG ?= $(OPENFIRE_VERSION)
IMAGE ?= $(IMAGE_NAME):$(IMAGE_TAG)
CONTAINER_ENGINE ?= $(shell if command -v podman >/dev/null 2>&1; then echo podman; elif command -v docker >/dev/null 2>&1; then echo docker; fi)
REGISTRY_HOST ?= $(shell oc registry info 2>/dev/null)
IMAGE_NAMESPACE ?= openfire-build
CLUSTER_IMAGE ?= $(REGISTRY_HOST)/$(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: download-plugins download-openfire prepare build push-local-image deploy-local

download-plugins:
	@sh ./scripts/download-plugins.sh plugins.txt plugins

download-openfire:
	@VERSION_FILE=$$(echo "$(OPENFIRE_VERSION)" | tr '.' '_'); \
	echo "Downloading Openfire $(OPENFIRE_VERSION)"; \
	curl -fsSL -o "openfire_$${VERSION_FILE}.tar.gz" \
		"$(OPENFIRE_DOWNLOAD_BASE_URL)/v$(OPENFIRE_VERSION)/openfire_$${VERSION_FILE}.tar.gz"

prepare: download-plugins download-openfire

build: prepare
	@if [ -z "$(CONTAINER_ENGINE)" ]; then \
		echo "ERROR: neither podman nor docker is available in PATH."; \
		exit 1; \
	fi
	@echo "Building image with $(CONTAINER_ENGINE): $(IMAGE)"
	@$(CONTAINER_ENGINE) build -f Containerfile --platform linux/amd64 \
		--build-arg OPENFIRE_VERSION="$(OPENFIRE_VERSION)" \
		-t "$(IMAGE)" .

push-local-image: build
	@if [ -z "$(REGISTRY_HOST)" ]; then \
		echo "ERROR: could not detect OpenShift registry host via 'oc registry info'."; \
		exit 1; \
	fi
	@echo "Preparing image stream $(IMAGE_NAMESPACE)/$(IMAGE_NAME)"
	@oc get project "$(IMAGE_NAMESPACE)" >/dev/null 2>&1 || oc new-project "$(IMAGE_NAMESPACE)"
	@oc get is/"$(IMAGE_NAME)" -n "$(IMAGE_NAMESPACE)" >/dev/null 2>&1 || oc create imagestream "$(IMAGE_NAME)" -n "$(IMAGE_NAMESPACE)"
	@echo "Logging into registry $(REGISTRY_HOST) with $(CONTAINER_ENGINE)"
	@oc whoami -t | $(CONTAINER_ENGINE) login -u "$$(oc whoami)" --password-stdin "$(REGISTRY_HOST)"
	@echo "Pushing $(CLUSTER_IMAGE)"
	@$(CONTAINER_ENGINE) tag "$(IMAGE)" "$(CLUSTER_IMAGE)"
	@$(CONTAINER_ENGINE) push "$(CLUSTER_IMAGE)"
	@oc policy add-role-to-group system:image-puller system:serviceaccounts:openfire -n "$(IMAGE_NAMESPACE)"

deploy-local:
	@helm template openfire ./deploy/charts/openfire \
		-f ./deploy/charts/openfire/values-openshift.yaml | oc apply -f -

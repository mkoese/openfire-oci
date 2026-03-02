# Local development helpers for a local OpenShift cluster (for example CRC).
# This Makefile is intentionally not used by CI/CD pipelines.

OPENFIRE_VERSION ?= 4.8.2
OPENFIRE_DOWNLOAD_BASE_URL ?= https://github.com/igniterealtime/Openfire/releases/download

IMAGE_NAME ?= openfire-oci
IMAGE_TAG ?= $(OPENFIRE_VERSION)
IMAGE ?= $(IMAGE_NAME):$(IMAGE_TAG)
CONTAINER_ENGINE ?= $(shell if command -v podman >/dev/null 2>&1; then echo podman; elif command -v docker >/dev/null 2>&1; then echo docker; fi)
REGISTRY_HOST ?= $(shell oc registry info 2>/dev/null)
IMAGE_NAMESPACE ?= openfire-build
CLUSTER_IMAGE ?= $(REGISTRY_HOST)/$(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)
OPENFIRE_NAMESPACE ?= openfire
RELEASE_NAME ?= openfire
POSTGRES_NAMESPACE ?= postgres-test
POSTGRES_RELEASE ?= postgres-test
POSTGRES_USER ?= openfire
POSTGRES_PASSWORD ?= openfire
POSTGRES_DATABASE ?= openfire

.PHONY: download-plugins download-openfire prepare build push-local-image clean clean-local deploy-local deploy-local-clean destroy-local-all postgres-local-setup openfire-conf-postgres deploy-local-postgres

download-plugins:
	@sh ./scripts/download-plugins.sh plugins.txt plugins

download-openfire:
	@VERSION_FILE=$$(echo "$(OPENFIRE_VERSION)" | tr '.' '_'); \
	PRIMARY_URL="$(OPENFIRE_DOWNLOAD_BASE_URL)/v$(OPENFIRE_VERSION)/openfire_$${VERSION_FILE}.tar.gz"; \
	FALLBACK_URL="https://www.igniterealtime.org/downloadServlet?filename=openfire/openfire_$${VERSION_FILE}.tar.gz"; \
	echo "Downloading Openfire $(OPENFIRE_VERSION)"; \
	curl -fsSL -o "openfire_$${VERSION_FILE}.tar.gz" "$${PRIMARY_URL}" || \
		curl -fsSL -o "openfire_$${VERSION_FILE}.tar.gz" "$${FALLBACK_URL}"

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

clean:
	@rm -f plugins/*.jar
	@rm -f openfire_*.tar.gz
	@if [ -n "$(CONTAINER_ENGINE)" ]; then \
		$(CONTAINER_ENGINE) image rm "$(IMAGE)" >/dev/null 2>&1 || true; \
	fi

clean-local:
	@oc scale deployment/"$(RELEASE_NAME)"-openfire -n "$(OPENFIRE_NAMESPACE)" --replicas=0 >/dev/null 2>&1 || true
	@oc wait --for=delete pod -l app.kubernetes.io/instance="$(RELEASE_NAME)" -n "$(OPENFIRE_NAMESPACE)" --timeout=60s >/dev/null 2>&1 || true
	@oc delete pvc -n "$(OPENFIRE_NAMESPACE)" \
		"$(RELEASE_NAME)"-openfire-data \
		"$(RELEASE_NAME)"-openfire-plugins \
		--ignore-not-found=true

deploy-local-clean: clean-local deploy-local

destroy-local-all:
	@oc delete namespace "$(OPENFIRE_NAMESPACE)" --ignore-not-found=true
	@oc delete namespace "$(POSTGRES_NAMESPACE)" --ignore-not-found=true

postgres-local-setup:
	@helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install "$(POSTGRES_RELEASE)" bitnami/postgresql \
		--namespace "$(POSTGRES_NAMESPACE)" \
		--create-namespace \
		--set auth.username="$(POSTGRES_USER)" \
		--set auth.password="$(POSTGRES_PASSWORD)" \
		--set auth.database="$(POSTGRES_DATABASE)" \
		--set primary.persistence.size=5Gi

wait-postgres-ready:
	@oc rollout status statefulset/"$(POSTGRES_RELEASE)"-postgresql -n "$(POSTGRES_NAMESPACE)" --timeout=300s

openfire-conf-postgres:
	@oc create secret generic openfire-conf -n "$(OPENFIRE_NAMESPACE)" \
		--from-file=openfire.xml=./conf/openfire-postgres.xml \
		--from-file=security.xml=./conf/security.xml \
		--dry-run=client -o yaml | oc apply -f -
	@oc rollout restart deployment/"$(RELEASE_NAME)"-openfire -n "$(OPENFIRE_NAMESPACE)"

deploy-local-postgres: postgres-local-setup wait-postgres-ready deploy-local openfire-conf-postgres

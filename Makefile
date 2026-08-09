# Build + vulnerability-scan the hardened network-debug-toolbox image.
#
#   make             # build (native) + scan + verify-caps + SBOM   — local dev
#   make publish     # build amd64 + scan + verify-caps + push + attach SBOM
#   make build
#   make scan
#   make verify      # full report, all severities, never fails (for review)
#   make verify-caps # assert tcpdump file caps (so non-root capture works)
#   make sbom
#   make chart       # lint + render (incl. reserved 'global') + kubeconform the Helm chart
#   make push IMAGE=<registry>/<user>/network-debug-toolbox TAG=YYYYMMDD

IMAGE    ?= network-debug-toolbox
TAG      ?= local
REF      := $(IMAGE):$(TAG)
SBOM     := network-debug-toolbox.cdx.json
# Local builds are native (e.g. arm64 on Apple Silicon) for speed; `make publish`
# overrides PLATFORM to linux/amd64 so the pushed image matches your target nodes.
PLATFORM ?=
PLATFORM_FLAG = $(if $(strip $(PLATFORM)),--platform=$(PLATFORM))
SEVERITY ?= HIGH,CRITICAL

# Trivy via Docker — no local install needed. Mounts the docker socket (to read the
# built image), a persistent DB cache, and this dir (for `config` + SBOM output).
# Override with a local binary: make TRIVY=trivy scan
TRIVY ?= docker run --rm \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-v $(HOME)/.cache/trivy:/root/.cache/ \
	-v $(CURDIR):/work -w /work \
	aquasec/trivy:latest

# oras (host binary) attaches the SBOM to the pushed image as an OCI referrer. It uses
# your Docker credential helper, so a plain `docker login <registry>` is enough.
# Install: brew install oras.
ORAS ?= oras

CHART_DIR ?= helm
HELM      ?= helm
# kubeconform via Docker — validates rendered manifests against the Kubernetes schemas.
KUBECONFORM ?= docker run --rm -i ghcr.io/yannh/kubeconform:latest

.PHONY: all publish build scan scan-config verify verify-caps sbom attach-sbom push clean help \
        chart chart-lint chart-render chart-validate

# `all` runs the full local pipeline. `push` is intentionally excluded — pushing is
# a deliberate, outward action you run explicitly, not on every build.
all: build scan-config scan verify-caps sbom chart ## build, scan (config + image), verify caps, SBOM, chart

# Publish: force amd64 for the whole pipeline (match typical Linux nodes), then push.
# The target-specific PLATFORM propagates to the `all` and `push` prerequisites.
publish: PLATFORM := linux/amd64
publish: all push attach-sbom ## build amd64 + scan + verify-caps + push + attach SBOM

build: ## build the image (native arch; set PLATFORM=linux/amd64 to cross-build)
	docker build $(PLATFORM_FLAG) -t $(REF) .

scan: build ## fail on fixed HIGH/CRITICAL vulns in the freshly built image
	$(TRIVY) image --scanners vuln --severity $(SEVERITY) --ignore-unfixed --exit-code 1 $(REF)

scan-config: ## scan the Dockerfile for misconfigurations (helm/ intentional posture skipped)
	$(TRIVY) config --severity $(SEVERITY) --exit-code 1 --skip-dirs helm .

verify: build ## full vuln report (all severities, never fails) — for review
	$(TRIVY) image --scanners vuln --severity LOW,MEDIUM,HIGH,CRITICAL $(REF)

verify-caps: build ## assert tcpdump carries file caps so it captures non-root (regression guard)
	@out=$$(docker run --rm $(REF) sh -c 'getcap "$$(command -v tcpdump)"'); \
	echo "$$out"; \
	echo "$$out" | grep -q cap_net_raw || { echo "FAIL: tcpdump missing file caps — rebuild"; exit 1; }; \
	echo "OK: tcpdump file caps present (non-root capture works with the debug profile)"

sbom: build ## generate a CycloneDX SBOM ($(SBOM))
	$(TRIVY) image --format cyclonedx --output $(SBOM) $(REF)

attach-sbom: ## attach the SBOM to the pushed image as an OCI referrer (needs oras + docker login)
	@command -v $(ORAS) >/dev/null 2>&1 || { echo "oras not found — run: brew install oras"; exit 1; }
	@test -f $(SBOM) || { echo "no SBOM — run 'make sbom' first"; exit 1; }
	@digest=$$(docker buildx imagetools inspect $(REF) | awk '/^Digest:/{print $$2; exit}'); \
	case "$$digest" in sha256:*) ;; *) echo "could not resolve digest for $(REF): $$digest"; exit 1;; esac; \
	ref="$(IMAGE)@$$digest"; \
	echo "Attaching SBOM to $$ref"; \
	$(ORAS) attach "$$ref" \
	  --artifact-type application/vnd.cyclonedx+json \
	  $(SBOM):application/vnd.cyclonedx+json

chart: chart-lint chart-render chart-validate ## lint + render + kubeconform the Helm chart

chart-lint: ## helm lint (also runs values.schema.json against default values)
	$(HELM) lint $(CHART_DIR)

chart-render: ## render defaults AND a reserved-key set, so values.schema.json can't over-restrict
	$(HELM) template test $(CHART_DIR) >/dev/null
	$(HELM) template test $(CHART_DIR) --set global.smoke=true >/dev/null
	@echo "OK: chart renders (schema accepts defaults + reserved 'global')"

chart-validate: ## validate rendered manifests against Kubernetes schemas (kubeconform)
	$(HELM) template test $(CHART_DIR) | $(KUBECONFORM) -strict -summary

push: ## push the image (set IMAGE=<registry>/<user>/network-debug-toolbox)
	docker push $(REF)

clean: ## remove the local image
	-docker rmi $(REF)

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

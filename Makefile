include .env
export

PIOSS_URL     ?= https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz
PIOSS_XZ      := img/raspios-lite.img.xz
PIOSS_IMG     := img/raspios-lite.img
PXE_IMG       := img/pi-pxe-ready.img
LOOP_DEV      := /dev/loop0
MOUNT_BOOT    := /mnt/pxe-boot

.PHONY: all download pxe-image flash clean check-env ntfy-secret pagerduty-secret newrelic-secret grafana-secret

all: pxe-image

check-env:
	@test -f .env || (echo "ERROR: .env not found — copy .env.example and fill in secrets" && exit 1)
	@test -n "$(TAILSCALE_AUTH_KEY)" || (echo "ERROR: TAILSCALE_AUTH_KEY not set in .env" && exit 1)
	@test -n "$(K3S_TOKEN)"          || (echo "ERROR: K3S_TOKEN not set in .env" && exit 1)

# The ntfy.sh topic name is the only access control, so it lives in .env and a Secret, never in the repo
ntfy-secret:
	@printf '%s' "$$NTFY_TOPIC" | grep -Eq '^[A-Za-z0-9_-]+$$' || (echo "ERROR: NTFY_TOPIC must be set in .env using only letters, digits, - or _ (openssl rand -hex 8)" && exit 1)
	@kubectl -n monitoring create secret generic ntfy-webhook \
		--from-literal=url="https://ntfy.sh/$$NTFY_TOPIC?template=alertmanager" \
		--dry-run=client -o yaml | kubectl apply -f -

# A PagerDuty Events API v2 integration key: 32 letters and digits
pagerduty-secret:
	@printf '%s' "$$PAGERDUTY_ROUTING_KEY" | grep -Eq '^[A-Za-z0-9]{32}$$' || (echo "ERROR: PAGERDUTY_ROUTING_KEY must be set in .env to the 32 character Events API v2 integration key" && exit 1)
	@kubectl -n monitoring create secret generic pagerduty-routing-key \
		--from-literal=key="$$PAGERDUTY_ROUTING_KEY" \
		--dry-run=client -o yaml | kubectl apply -f -

# A New Relic license key: 40 characters ending in NRAL
newrelic-secret:
	@printf '%s' "$$NEW_RELIC_LICENSE_KEY" | LC_ALL=C grep -Eq '^[A-Za-z0-9]{36}NRAL$$' || (echo "ERROR: NEW_RELIC_LICENSE_KEY must be set in .env to the 40 character license key ending in NRAL" && exit 1)
	@kubectl create namespace newrelic --dry-run=client -o yaml | kubectl apply -f -
	@printf '%s' "$$NEW_RELIC_LICENSE_KEY" | kubectl -n newrelic create secret generic newrelic-license \
		--from-file=licenseKey=/dev/stdin \
		--dry-run=client -o yaml | kubectl apply -f -

# Grafana reads the admin env only when its DB is first created, so a running Grafana also gets a reset
grafana-secret:
	@test $${#GRAFANA_ADMIN_PASSWORD} -ge 16 || (echo "ERROR: GRAFANA_ADMIN_PASSWORD must be set in .env to at least 16 characters (openssl rand -base64 30)" && exit 1)
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@kubectl -n monitoring create secret generic grafana-admin \
		--from-literal=admin-user=admin \
		--from-literal=admin-password="$$GRAFANA_ADMIN_PASSWORD" \
		--dry-run=client -o yaml | kubectl apply -f -
	@if kubectl -n monitoring get deploy kube-prometheus-stack-grafana >/dev/null 2>&1; then \
		kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
			grafana cli admin reset-admin-password "$$GRAFANA_ADMIN_PASSWORD" >/dev/null && echo "Grafana admin password reset"; \
	else \
		echo "Grafana deployment not found, skipped the password reset (fine before the first install)"; \
	fi

download: $(PIOSS_IMG)

$(PIOSS_XZ):
	mkdir -p img
	curl -L --progress-bar -o $@ $(PIOSS_URL)

$(PIOSS_IMG): $(PIOSS_XZ)
	xz -dk $<
	mv $(dir $<)$(notdir $(PIOSS_XZ:.xz=)) $@

pxe-image: check-env $(PIOSS_IMG)
	cp $(PIOSS_IMG) $(PXE_IMG)
	$(eval LOOP := $(shell sudo losetup -f --show -P $(PXE_IMG)))
	mkdir -p $(MOUNT_BOOT)
	sudo mount $(LOOP)p1 $(MOUNT_BOOT)
	sed \
		-e 's|__TAILSCALE_AUTH_KEY__|$(TAILSCALE_AUTH_KEY)|g' \
		-e 's|__K3S_TOKEN__|$(K3S_TOKEN)|g' \
		-e 's|__PXE_SERVER_IP__|$(PXE_SERVER_IP)|g' \
		cloud-init/pxe-server/user-data > /tmp/pxe-user-data
	sudo cp /tmp/pxe-user-data $(MOUNT_BOOT)/user-data
	sudo cp cloud-init/pxe-server/meta-data $(MOUNT_BOOT)/meta-data
	sudo touch $(MOUNT_BOOT)/ssh
	sudo umount $(MOUNT_BOOT)
	sudo losetup -d $(LOOP)
	rm -f /tmp/pxe-user-data
	@echo "Built: $(PXE_IMG) — flash with: make flash DEVICE=/dev/diskN"

flash: check-env
	@test -n "$(DEVICE)" || (echo "Usage: make flash DEVICE=/dev/diskN" && exit 1)
	scripts/pi-flash-sd $(PXE_IMG) $(DEVICE)

clean:
	rm -f $(PXE_IMG) /tmp/pxe-user-data
	sudo umount $(MOUNT_BOOT) 2>/dev/null || true

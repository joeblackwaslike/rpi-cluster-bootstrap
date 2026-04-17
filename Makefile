include .env
export

PIOSS_URL     ?= https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz
PIOSS_XZ      := img/raspios-lite.img.xz
PIOSS_IMG     := img/raspios-lite.img
PXE_IMG       := img/pi-pxe-ready.img
LOOP_DEV      := /dev/loop0
MOUNT_BOOT    := /mnt/pxe-boot

.PHONY: all download pxe-image flash clean check-env

all: pxe-image

check-env:
	@test -f .env || (echo "ERROR: .env not found — copy .env.example and fill in secrets" && exit 1)
	@test -n "$(TAILSCALE_AUTH_KEY)" || (echo "ERROR: TAILSCALE_AUTH_KEY not set in .env" && exit 1)
	@test -n "$(K3S_TOKEN)"          || (echo "ERROR: K3S_TOKEN not set in .env" && exit 1)

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

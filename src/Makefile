SUBDIRS = proxmox-boot bin

.PHONY: all
all: $(SUBDIRS)
	set -e && for i in $(SUBDIRS); do $(MAKE) -C $$i; done

.PHONY: install
install: $(SUBDIRS)
	set -e && for i in $(SUBDIRS); do $(MAKE) -C $$i $@; done

.PHONY: check
check:
	test/run-tests.sh

.PHONY: clean
clean: $(SUBDIRS)
	set -e && for i in $(SUBDIRS); do $(MAKE) -C $$i $@; done

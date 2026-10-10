PACKER ?= packer

# Every image builds from resolute-base, so never build them in parallel with it.
.NOTPARALLEL:

.PHONY: all base pihole apt-cacher-ng distcc validate

all: base pihole apt-cacher-ng distcc

validate:
	$(PACKER) fmt -check .
	$(PACKER) validate .

base:
	$(PACKER) build -force -only='base.*' .

pihole:
	$(PACKER) build -force -only='pihole.*' .

apt-cacher-ng:
	$(PACKER) build -force -only='apt-cacher-ng.*' .

distcc:
	$(PACKER) build -force -only='distcc.*' .

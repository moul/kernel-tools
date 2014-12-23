CONFIG ?=		.config-3.18-std
KERNEL_VERSION ?=	$(shell echo $(CONFIG) | cut -d- -f2)
KERNEL_FLAVOR ?=	$(shell echo $(CONFIG) | cut -d- -f3)
KERNEL_FULL ?=		$(KERNEL_VERSION)-$(KERNEL_FLAVOR)
NAME ?=			moul/kernel-builder:$(KERNEL_VERSION)-cross-armhf
ARCH_CONFIG ?=		mvebu_v7
CONCURRENCY_LEVEL ?=	$(shell grep -m1 cpu\ cores /proc/cpuinfo 2>/dev/null | sed 's/[^0-9]//g' | grep '[0-9]' || sysctl hw.ncpu | sed 's/[^0-9]//g' | grep '[0-9]')
J ?=			-j $(CONCURRENCY_LEVEL)
S3_TARGET ?=		s3://$(shell whoami)/$(KERNEL_FULL)/

DOCKER_ENV ?=		-e LOADADDR=0x8000 \
			-e CONCURRENCY_LEVEL=$(CONCURRENCY_LEVEL)

DOCKER_VOLUMES ?=	-v $(PWD)/$(CONFIG):/tmp/.config \
			-v $(PWD)/dist/$(KERNEL_FULL):/usr/src/linux/build/ \
			-v $(PWD)/ccache:/ccache
DOCKER_RUN_OPTS ?=	-it --rm


all:	build


run:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(NAME) \
		/bin/bash


menuconfig:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(NAME) \
		/bin/bash -c 'cp /tmp/.config .config && make menuconfig && cp .config /tmp/.config'


defconfig:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(NAME) \
		/bin/bash -c "cp /tmp/.config .config && make $(ARCH_CONFIG)_defconfig && cp .config /tmp/.config"


build:	local_assets
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(NAME) \
		/bin/bash -xc ' \
			cp /tmp/.config .config && \
			make $(J) uImage && \
			make $(J) modules && \
			make headers_install INSTALL_HDR_PATH=build && \
			make modules_install INSTALL_MOD_PATH=build && \
			make uinstall INSTALL_PATH=build && \
			cp arch/arm/boot/uImage build/uImage-`cat include/config/kernel.release` \
		'
	$(MAKE) dist/$(KERNEL_FULL)/build.txt


publish_all: dist/$(KERNEL_FULL)/lib.tar.gz dist/$(KERNEL_FULL)/include.tar.gz
	s3cmd put --acl-public dist/$(KERNEL_FULL)/lib.tar.gz $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/include.tar.gz $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/uImage* $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/config* $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/vmlinuz* $(S3_TARGET)
	s3cmd put --acl-public dist/$(KERNEL_FULL)/build.txt $(S3_TARGET)


dist/$(KERNEL_FULL)/lib.tar.gz: dist/$(KERNEL_FULL)/lib
	tar -C dist/$(KERNEL_FULL) -cvzf $@ lib


dist/$(KERNEL_FULL)/include.tar.gz: dist/$(KERNEL_FULL)/include
	tar -C dist/$(KERNEL_FULL) -cvzf $@ include


dist/$(KERNEL_FULL)/build.txt: dist/$(KERNEL_FULL)
	echo "=== $(KERNEL_FULL) - built on $(shell date)" > $@
	echo "=== gcc version" >> $@
	gcc --version >> $@
	echo "=== file listing" >> $@
	cd dist/$(KERNEL_FULL) && find . -type f -ls >> build.txt
	echo "=== sizes" >> $@
	cd dist/$(KERNEL_FULL) && du -sh * >> build.txt


ccache_stats:
	docker run $(DOCKER_RUN_OPTS) $(DOCKER_ENV) $(DOCKER_VOLUMES) $(NAME) \
		ccache -s


qemu:
	qemu-system-arm \
		-M versatilepb \
		-m 256 \
		-initrd ./dist/$(KERNEL_FULL)/initrd.img-* \
		-kernel ./dist/$(KERNEL_FULL)/uImage-* \
		-append "console=tty1"

clean:
	rm -rf dist/$(KERNEL_FULL)


fclean:	clean
	rm -rf dist ccache


local_assets: $(CONFIG) dist/$(KERNEL_FULL)/ ccache


$(CONFIG):
	touch $(CONFIG)


dist/$(KERNEL_FULL) ccache:
	mkdir -p $@


.PHONY:	all build run menuconfig build clean fclean ccache_stats dist/$(KERNEL_FULL)/build.txt

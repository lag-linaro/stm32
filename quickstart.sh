#!/bin/bash

# Set this to your chosen install destination
TOPDIR=""
# Set this to the location of your kernel source
KERNELDIR=""
# Either uncomment one of the boards below, or add your own"
BOARD=""
#BOARD="stm32f429discovery"
#BOARD="stm32f469discovery"


startupchecks()
{
    if [ ! -f /etc/lsb-release ]; then
	echo "This does not appear to be a Debian machine"
	echo "Please install the OSELAS toolchain manually"
	exit
    fi

    lsusb | grep STMicroelectronics
    if [ $? -ne 0 ]; then
	echo "Board not found. Is it plugged in?"
	exit
    fi

    if [ "$TOPDIR" == "" ]; then
	echo "Please set TOPDIR in $0"
	exit
    fi

    if [ "$KERNELDIR" == "" ]; then
	echo "Set the KERNELDIR in $0"
	exit
    fi

    if [ "$BOARD" == "" ]; then
	echo "Uncomment or set BOARD in $0"
	exit
    fi
}

init()
{
    if [ "$BOARD" == "stm32f429discovery" ]; then
	BOARDAFBOOT=stm32f429i-disco
	BOARDDTB=stm32f429-disco
    elif [ "$BOARD" == "stm32f469discovery" ]; then
	echo "###################################################"
	echo "Don't forget to make the kernel changes detailed at"
	echo "  http://elinux.org/STM32#Mainline_Kernel"
	echo "###################################################"
	echo "Hit return to acknowledge"
	read

	BOARDAFBOOT=stm32f469i-disco
	BOARDDTB=stm32f429-disco
	#   BOARDDTB=stm32f469-disco  future
    else
	echo "$BOARD is not supported by $0 - please add support"
	exit
    fi

    mkdir -p $TOPDIR
    cd $TOPDIR
}

openocd()
{
    SELFOPENOCDDIR="/usr/local/share/openocd"
    DISTROOPENOCDDIR="/usr/share/openocd"
    SELFOPENOCDCFG=$SELFOPENOCDDIR/scripts/board/$BOARD.cfg
    DISTROOPENOCDCFG=$DISTROOPENOCDDIR/scripts/board/$BOARD.cfg

    if [ "$(which openocd)" == "" ] && [ ! -d openocd ]; then
	echo "Installing OpenOCD from source"
	git clone git://git.code.sf.net/p/openocd/code openocd
	cd openocd
	./bootstrap && ./configure && make && sudo make install
	cd ..
    elif [ ! -f $DISTROOPENOCDCFG ] && [ ! -f $SELFOPENOCDCFG ]; then
	echo "$OPENOCDCFG not found. Perhaps installed OpenOCD is out of date"
	exit
    else
	echo "OpenOCD is already installed and appears to support your hardware"
    fi
}

stlink()
{
    if [ "$(which st-flash)" == "" ] && [ ! -d openocd ]; then
	echo "Building STLink from source"
	git clone https://github.com/texane/stlink.git stlink
	cd stlink

	./autogen.sh
	./configure
	make
	echo "Installing STLink"
	make install 

	echo "Installing STLink udev rules"
	sudo cp 49-stlinkv*.rules /etc/udev/rules.d
	sudo udevadm control --reload-rules
	sudo udevadm trigger
	cd ..
    else
	echo "STLink is already installed"
    fi
}

bmcompiler()
{
    # Bare Metal compiler
    if [ ! -d gcc-arm-none-eabi-4_9-2014q4 ]; then
	echo "Installing the Bare Metal compliler [for building Bootloader and Kernel]"
	BAREMETALTAR=gcc-arm-none-eabi-4_9-2014q4-20141203-linux.tar.bz2
	URL=https://launchpad.net/gcc-arm-embedded/4.9/4.9-2014-q4-major/+download/$BAREMETALTAR
	wget $URL
	tar -xf $BAREMETALTAR
	rm $BAREMETALTAR
	PATH=$PATH:$PWD/gcc-arm-none-eabi-4_9-2014q4/bin
    else
	echo "Bare metal complier already installed"
    fi
}

bootloader()
{
    if [ ! -d afboot-stm32 ]; then
	echo "Downloading bootloader"
	git clone https://github.com/mcoquelin-stm32/afboot-stm32.git
    else
	echo "Bootloader already downloaded"
    fi
    echo "Building and flashing bootloader"
    cd afboot-stm32
    make $BOARDAFBOOT
    make flash_$BOARDAFBOOT
    cd ..
}

cpio()
{
    # Pre-built userspace
    CPIO=$PWD/Stm32_mini_rootfs.cpio
    if [ ! -f Stm32_mini_rootfs.cpio ]; then
	echo "Downloading a pre-built userspace CPIO (RAMFS)"
	wget http://elinux.org/images/5/51/$CPIO.bz2
	bunzip2 $CPIO.bz2
    else
	echo "Already have the desired CPIO"
    fi
}

kernel()
{
    KERNELBUILDDIR=build-stm32
    echo "Building the kernel - output will be in $KERNELDIR/$KERNELBUILDDIR"
    cd $KERNELDIR
    BRANCH=`git branch | grep "*" | sed 's/* //'`
    echo -e "\nIf $BRANCH is not the correct branch Ctrl+C now, else hit return"
    read
    CFLAGS="ARCH=arm CROSS_COMPILE=arm-none-eabi- KBUILD_OUTPUT=$KERNELBUILDDIR"
    make $CFLAGS stm32_defconfig
    yes "" | make $CFLAGS oldconfig
    ./scripts/config --file $KERNELBUILDDIR/.config \
	--set-str INITRAMFS_ROOT_UID 0 \
	--enable BLK_DEV_INITRD \
	--set-str INITRAMFS_SOURCE $CPIO \
	--enable RD_GZIP \
	--enable INITRAMFS_COMPRESSION_GZIP
    make $CFLAGS
    cd ..
}

flash()
{
    DTB=$KERNELDIR/$KERNELBUILDDIR/arch/arm/boot/dts/$BOARDDTB.dtb
    echo "Flashing DTB ($DTB)"
    st-flash --reset write $KERNELDIR/$KERNELBUILDDIR/arch/arm/boot/dts/$BOARDDTB.dtb 0x08004000

    KERNEL=$KERNELDIR/$KERNELBUILDDIR/arch/arm/boot/xipImage
    echo "Flashing Kernel ($KERNEL)"
    st-flash --reset write $KERNEL 0x08008000
}

startupchecks
init
openocd
stlink
bmcompiler
bootloader
cpio
kernel
flash

echo "################################################################################"
echo "Install OSELAS toolchain if you wish to build your own userspace rootfs/apps"
echo "  echo \"deb http://debian.pengutronix.de/debian/ sid main contrib non-free\" | \\"
echo "    sudo tee /etc/apt/sources.list.d/pengutronix.list"
echo "  sudo apt-get update"
echo "  sudo apt-get install \\"
echo "    oselas.toolchain-2012.12.1-arm-cortexm3-uclinuxeabi-\\"
echo "    gcc-4.7.2-uclibc-0.9.33.2-binutils-2.22-kernel-3.6-sanitized"
echo "################################################################################"
echo "Add the following to your ~/.bashrc file to run manually"
echo "  export PATH=\$PATH:$PWD/gcc-arm-none-eabi-4_9-2014q4/bin"
echo "################################################################################"

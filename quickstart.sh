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

    lsusb | grep STMicroelectronics > /dev/null 2>&1
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
	BOARDDTB=stm32f469-disco
	CONFIGFRAGMENTS=dram_0x00000000.config
	for fragment in $CONFIGFRAGMENTS; do
	    file=$KERNELDIR/arch/arm/configs/$fragment
	    if [ ! -f $file ]; then
		echo "###################################################"
		echo "$file is missing -- this may break your board"
		echo "###################################################"
		echo "Hit return to acknowledge"
		read
	    fi
	done
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
	echo "###################################################"
	echo "Installing OpenOCD from source"
	echo "###################################################"
	git clone git://git.code.sf.net/p/openocd/code openocd
	cd openocd
	./bootstrap && ./configure && make && sudo make install
	cd ..
    elif [ ! -f $DISTROOPENOCDCFG ] && [ ! -f $SELFOPENOCDCFG ]; then
	echo "$OPENOCDCFG not found. Perhaps installed OpenOCD is out of date"
	exit
    else
	echo "###################################################"
	echo "OpenOCD is already installed and appears to support your hardware"
	echo "###################################################"
    fi
}

stlink()
{
    if [ "$(which st-flash)" == "" ] && [ ! -d stlink ]; then
	echo "###################################################"
	echo "Building STLink from source"
	echo "###################################################"
	git clone https://github.com/texane/stlink.git stlink
	cd stlink

	./autogen.sh
	./configure
	make
	echo "###################################################"
	echo "Installing STLink"
	echo "###################################################"
	sudo make install

	echo "###################################################"
	echo "Installing STLink udev rules"
	echo "###################################################"
	sudo cp 49-stlinkv*.rules /etc/udev/rules.d
	sudo udevadm control --reload-rules
	sudo udevadm trigger
	cd ..
    else
	echo "###################################################"
	echo "STLink is already installed"
	echo "###################################################"
    fi
}

bmcompiler()
{
    # Bare Metal compiler
    if [ ! -d gcc-arm-none-eabi-4_9-2014q4 ]; then
	echo "###################################################"
	echo "Installing the Bare Metal compliler [for building Bootloader and Kernel]"
	echo "###################################################"
	BAREMETALTAR=gcc-arm-none-eabi-4_9-2014q4-20141203-linux.tar.bz2
	URL=https://launchpad.net/gcc-arm-embedded/4.9/4.9-2014-q4-major/+download/$BAREMETALTAR
	wget $URL
	tar -xf $BAREMETALTAR
	rm $BAREMETALTAR
	PATH=$PATH:$PWD/gcc-arm-none-eabi-4_9-2014q4/bin
    else
	echo "###################################################"
	echo "Bare metal complier already installed"
	echo "###################################################"
    fi
}

bootloader()
{
    if [ ! -d afboot-stm32 ]; then
	echo "###################################################"
	echo "Downloading bootloader"
	echo "###################################################"
	git clone https://github.com/mcoquelin-stm32/afboot-stm32.git
    else
	echo "###################################################"
	echo "Bootloader already downloaded"
	echo "###################################################"
    fi
    echo "###################################################"
    echo "Building and flashing bootloader"
    echo "###################################################"
    cd afboot-stm32
    make $BOARDAFBOOT
    make flash_$BOARDAFBOOT
    cd ..
}

cpio()
{
    # Pre-built userspace
    CPIO=Stm32_mini_rootfs.cpio
    CPIO_FILE=$PWD/$CPIO
    if [ ! -f $CPIO ]; then
	echo "###################################################"
	echo "Downloading a pre-built userspace CPIO (RAMFS)"
	echo "###################################################"
	wget http://elinux.org/images/5/51/$CPIO.bz2
	bunzip2 $CPIO.bz2
    else
	echo "###################################################"
	echo "Already have the desired CPIO"
	echo "###################################################"
    fi
}

kernel()
{
    KERNELBUILDDIR=build-stm32
    echo "###################################################"
    echo "Building the kernel - output will be in $KERNELDIR/$KERNELBUILDDIR"
    echo "###################################################"
    cd $KERNELDIR
    BRANCH=`git branch | grep "*" | sed 's/* //'`

    echo "################################################################"
    echo "If $BRANCH is not the correct branch Ctrl+C now, else hit return"
    echo "################################################################"
    read

    CFLAGS="ARCH=arm CROSS_COMPILE=arm-none-eabi- KBUILD_OUTPUT=$KERNELBUILDDIR"
    make $CFLAGS stm32_defconfig $CONFIGFRAGMENTS
    yes "" | make $CFLAGS oldconfig
    ./scripts/config --file $KERNELBUILDDIR/.config \
	--set-val INITRAMFS_ROOT_UID 0 \
	--set-val INITRAMFS_ROOT_GID 0 \
	--enable BLK_DEV_INITRD \
	--set-str INITRAMFS_SOURCE $CPIO_FILE \
	--enable RD_GZIP \
	--enable INITRAMFS_COMPRESSION_GZIP
    make $CFLAGS
    cd ..
}

flash()
{
    DTB=$KERNELDIR/$KERNELBUILDDIR/arch/arm/boot/dts/$BOARDDTB.dtb
    echo "###################################################"
    echo "Flashing DTB ($DTB)"
    echo "###################################################"
    st-flash --reset write $KERNELDIR/$KERNELBUILDDIR/arch/arm/boot/dts/$BOARDDTB.dtb 0x08004000

    KERNEL=$KERNELDIR/$KERNELBUILDDIR/arch/arm/boot/xipImage
    echo "###################################################"
    echo "Flashing Kernel ($KERNEL)"
    echo "###################################################"
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

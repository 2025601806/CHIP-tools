#!/bin/bash

FEL=sunxi-fel

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $SCRIPTDIR/common.sh

IMAGESDIR="$1"
ERASEMODE="$2"
PLATFORM="$3"
SPLMEMADDR=0x43000000
UBOOTMEMADDR=0x4a000000
UBOOTSCRMEMADDR=0x43100000
nand_erasesize=400000
nand_writesize=4000
nand_oobsize=680

detect_nand() {
  local tmpdir=`mktemp -d -t chip-uboot-script-XXXXXX`
  local ubootcmds=$tmpdir/uboot.cmds
  local ubootscr=$tmpdir/uboot.scr

  echo "nand info
env export -t -s 0x100 0x7c00 nand_erasesize nand_writesize nand_oobsize
reset" > $ubootcmds
  mkimage -A arm -T script -C none -n "detect NAND" -d $ubootcmds $ubootscr

  if ! wait_for_fel; then
    echo "ERROR: please make sure CHIP is connected and jumpered in FEL mode"
  fi

  $FEL spl $IMAGESDIR/sunxi-spl.bin
  # wait for DRAM initialization to complete
  sleep 1

  $FEL write $UBOOTMEMADDR $IMAGESDIR/u-boot-dtb.bin
  $FEL write $UBOOTSCRMEMADDR $ubootscr
  $FEL exe $UBOOTMEMADDR

  if ! wait_for_fel; then
    echo "ERROR: please make sure CHIP is connected and jumpered in FEL mode"
  fi

  $FEL read 0x7c00 0x100 $tmpdir/nand-info

  echo "NAND detected:"
  cat $tmpdir/nand-info
  source $tmpdir/nand-info

  rm -rf $tmpdir
}

flash_images() {
  local tmpdir=`mktemp -d -t chip-uboot-script-XXXXXX`
  local ubootcmds=$tmpdir/uboot.cmds
  local ubootscr=$tmpdir/uboot.scr
  local ubootsize=`filesize $IMAGESDIR/uboot-$nand_erasesize.bin | xargs printf "0x%08x"`
  local pagespereb=`echo $((nand_erasesize/nand_writesize)) | xargs printf "%x"`
  local sparseubi=$tmpdir/ubi.sparse

  if [ "x$ERASEMODE" = "xscrub" ]; then
    echo "nand scrub.chip -y" > $ubootcmds
  else
    echo "nand erase.chip" > $ubootcmds
  fi

  echo "nand write.raw.noverify $SPLMEMADDR 0x0 $pagespereb" >> $ubootcmds
  echo "nand write.raw.noverify $SPLMEMADDR 0x400000 $pagespereb" >> $ubootcmds
  echo "nand write $UBOOTMEMADDR 0x800000 $ubootsize" >> $ubootcmds
  echo "setenv mtdparts mtdparts=sunxi-nand.0:4m(spl),4m(spl-backup),4m(uboot),4m(env),-(UBI)" >> $ubootcmds
  echo "setenv bootargs root=ubi0:rootfs rootfstype=ubifs rw earlyprintk ubi.mtd=4" >> $ubootcmds
  echo "setenv bootcmd 'gpio set PB2; if test -n \${fel_booted} && test -n \${scriptaddr}; then echo '(FEL boot)'; source \${scriptaddr}; fi; mtdparts; ubi part UBI; ubifsmount ubi0:rootfs; ubifsload \$fdt_addr_r /boot/sun5i-r8-chip.dtb; ubifsload \$kernel_addr_r /boot/zImage; bootz \$kernel_addr_r - \$fdt_addr_r'" >> $ubootcmds
  echo "setenv fel_booted 0" >> $ubootcmds

  echo "echo Enabling Splash" >> $ubootcmds
  echo "setenv stdout serial" >> $ubootcmds
  echo "setenv stderr serial" >> $ubootcmds
  echo "setenv splashpos m,m" >> $ubootcmds

  echo "echo Configuring Video Mode" >> $ubootcmds
  if [ "$PLATFORM" = "PocketCHIP" ]; then
    echo "setenv video-mode" >> $ubootcmds
  else
    echo "setenv video-mode sunxi:640x480-24@60,monitor=composite-ntsc,overscan_x=40,overscan_y=20" >> $ubootcmds
  fi

  echo "saveenv" >> $ubootcmds

  echo "echo going to fastboot mode" >> $ubootcmds
  echo "fastboot 0" >> $ubootcmds
  echo "reset" >> $ubootcmds

  mkimage -A arm -T script -C none -n "flash $PLATFORM" -d $ubootcmds $ubootscr

  if ! wait_for_fel; then
    echo "ERROR: please make sure CHIP is connected and jumpered in FEL mode"
  fi

  img2simg $IMAGESDIR/chip-$nand_erasesize-$nand_writesize.ubi $sparseubi $((4*1024*1024))

  $FEL spl $IMAGESDIR/sunxi-spl.bin
  # wait for DRAM initialization to complete
  sleep 1

  $FEL write $UBOOTMEMADDR $IMAGESDIR/uboot-$nand_erasesize.bin
  $FEL write $SPLMEMADDR $IMAGESDIR/spl-$nand_erasesize-$nand_writesize-$nand_oobsize.bin
  $FEL write $UBOOTSCRMEMADDR $ubootscr
  $FEL exe $UBOOTMEMADDR

  if wait_for_fastboot; then
    fastboot -i 0x1f3a -u flash UBI $IMAGESDIR/chip-$nand_erasesize-$nand_writesize.ubi.sparse
  else
    echo "failed to flash the UBI image"
  fi

  rm -rf $tmpdir
}

detect_nand
flash_images

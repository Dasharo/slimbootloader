#!/bin/bash

set -Eeuo pipefail

trap 'echo "Build failed."' ERR

usage() {
  echo "${0} CMD"
  echo "Available CMDs:"
  echo -e "\todroid_h4              - build Dasharo compatible with Hardkernel ODROID H4"
  echo -e "\tqemu                   - build Dasharo compatible with QEMU Q35"
}

DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/dasharo/dasharo-sdk}
DOCKER_IMAGE_VER=${DOCKER_IMAGE_VER:-v1.7.0}
SBL_KEY_DIR=${SBL_KEY_DIR:-"${PWD}/SblTestKeys"}

EDK2_FLAGS="-D CRYPTO_PROTOCOL_SUPPORT=TRUE -D SIO_BUS_ENABLE=TRUE \
    -D PERFORMANCE_MEASUREMENT_ENABLE=TRUE \
    -D MULTIPLE_DEBUG_PORT_SUPPORT=TRUE -D BOOTSPLASH_IMAGE=TRUE \
    -D BOOT_MANAGER_ESCAPE=TRUE"

build_odroid_h4() {
  local blobs_rev="cbfff4d06009bc342b8638a9749fd0e286d5dcb3"

  build_edk2 "edk2-stable202505" "$EDK2_FLAGS"
  build_slimbootloader odroid_h4

  if [ -f Outputs/odroid_h4/descriptor.bin ]; then
    rm Outputs/odroid_h4/descriptor.bin
  fi
  wget https://github.com/Dasharo/dasharo-blobs/raw/$blobs_rev/hardkernel/odroid-h4/descriptor.bin \
     -O Outputs/odroid_h4/descriptor.bin > /dev/null
  if [ -f Outputs/odroid_h4/me.bin ]; then
    rm Outputs/odroid_h4/me.bin
  fi
  wget https://github.com/Dasharo/dasharo-blobs/raw/$blobs_rev/hardkernel/odroid-h4/me.bin \
    -O Outputs/odroid_h4/me.bin > /dev/null
  dd if=/dev/zero of=image.bin bs=16M count=1 > /dev/null 2>&1
  cat Outputs/odroid_h4/descriptor.bin Outputs/odroid_h4/me.bin | \
    dd of=image.bin conv=notrunc > /dev/null 2>&1

  stitch_loader odroid_h4 image.bin AlderlakeBoardPkg 0xAAFFFF0C
  rm image.bin

  echo "Result binary placed in $PWD/Outputs/odroid_h4/ifwi-release.bin"
  sha256sum Outputs/odroid_h4/ifwi-release.bin > Outputs/odroid_h4/ifwi-release.bin.sha256
}

build_qemu() {
  build_edk2 "edk2-stable202505" "$EDK2_FLAGS"
  build_slimbootloader qemu
  echo "Result binary placed in $PWD/Outputs/qemu/SlimBootloader.bin"
  sha256sum Outputs/qemu/SlimBootloader.bin > Outputs/qemu/SlimBootloader.bin.sha256
}

build_edk2() {
  local edk2_ver="$1"
  local flags="$2"

  rm -rf edk2
  mkdir edk2
  cd edk2
  # clone one commit only
  git init
  git remote remove origin 2>/dev/null || true
  git remote add origin https://github.com/tianocore/edk2.git
  git fetch --depth 1 origin "$edk2_ver"
  git checkout FETCH_HEAD --force
  git submodule update --init --checkout --recursive --depth 1

  # Copy Dasharo logo
  cp ../Platform/CommonBoardPkg/Logo/Logo.bmp MdeModulePkg/Logo/Logo.bmp

  docker run --rm -i -u "$UID" -v "$PWD":/edk2 -w /edk2\
    $DOCKER_IMAGE:$DOCKER_IMAGE_VER /bin/bash <<EOF
    source edksetup.sh
    make -C BaseTools
    python ./UefiPayloadPkg/UniversalPayloadBuild.py -t GCC5 -o Dasharo -b RELEASE \
      $flags
EOF
  cd ..
}

stitch_loader() {
  local platform="$1"
  local ifwi_image="$2"
  local platform_pkg="$3"
  local platform_data="$4"

  docker run --rm -i -u $UID -v "$PWD":/home/docker/slimbootloader \
    -w /home/docker/slimbootloader $DOCKER_IMAGE:$DOCKER_IMAGE_VER /bin/bash <<EOF
      python Platform/$platform_pkg/Script/StitchLoader.py \
        -i $ifwi_image \
        -s Outputs/$platform/SlimBootloader.bin \
        -o Outputs/$platform/ifwi-release.bin \
        -p $platform_data
EOF

}

build_slimbootloader() {
  local platform="$1"

  git submodule update --init --checkout --recursive --depth 1

  mkdir -p PayloadPkg/PayloadBins/
  cp edk2/Build/UefiPayloadPkgX64/UniversalPayload.elf PayloadPkg/PayloadBins/
  docker run --rm -i -u $UID -v "$PWD":/home/docker/slimbootloader \
    -v "$SBL_KEY_DIR":/home/docker/slimbootloader/SblKeys \
    -w /home/docker/slimbootloader $DOCKER_IMAGE:$DOCKER_IMAGE_VER /bin/bash <<EOF
      set -e
      export SBL_KEY_DIR=/home/docker/slimbootloader/SblKeys
      export BUILD_NUMBER=0
      python BuildLoader.py clean
      python BuildLoader.py build "$platform" -r \
        -p "OsLoader.efi:LLDR:Lz4;UniversalPayload.elf:UEFI:Lzma"
EOF

}

if [ $# -ne 1 ]; then
  usage
  echo ""
  echo "Error: missing CMD"
  exit 1
fi

CMD="$1"

case "$CMD" in
    "odroid_h4" | "odroid_H4" | "ODROID_H4" )
        build_odroid_h4 ""
        ;;
    "qemu" | "QEMU" )
        build_qemu ""
        ;;
    *)
        echo "Invalid command: \"$CMD\""
        usage
        ;;
esac

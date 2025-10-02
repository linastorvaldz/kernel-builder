#!/usr/bin/env bash
set -e

# Constants
KERNEL_NAME="QuartiX"
BUILD_DEVICE="wayne"
USER="eraselk"
HOST="gacorprjkt"
TIMEZONE="Asia/Makassar"
ANYKERNEL_REPO="https://github.com/linastorvaldz/anykernel"
ANYKERNEL_BRANCH="wayne"
KERNEL_REPO="https://github.com/linastorvaldz/android_kernel_xiaomi_sdm660"
KERNEL_BRANCH="master"
KERNEL_DEFCONFIG="quartix_defconfig"
RELEASES_REPO="https://github.com/linastorvaldz/quartix-wayne-releases"
CLANG_URL="https://github.com/linastorvaldz/idk/releases/download/clang-r547379/clang.tgz"
CLANG_BRANCH=""
AK3_ZIP_NAME="$KERNEL_NAME-$BUILD_DEVICE-VARIANT-BUILD_DATE.zip"
WORKDIR="$(pwd)"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"

# Handle error
exec > >(tee $WORKDIR/build.log) 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

# Import functions
source $WORKDIR/functions.sh

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

# Clone kernel source
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC

cd $KSRC
LINUX_VERSION=$(make kernelversion)
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
cd $WORKDIR

# Set Kernel variant
log "Setting Kernel variant..."
case "$KSU" in
  "Suki") VARIANT="SUKISU" ;;
  "None") VARIANT="VNL" ;;
esac
susfs_is_included && VARIANT+="+SuSFS"

# Replace Placeholder in zip name
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  wget -qO clang-archive "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.*|*.tgz)
      tar -xf clang-archive -C "$CLANG_DIR"
      ;;
    *.7z)
      7z x clang-archive -o${CLANG_DIR}/ -bd -y > /dev/null
      ;;
    *)
      error "Unsupported file format"
      ;;
  esac
  rm clang-archive

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv $SINGLE_DIR/* $CLANG_DIR/
    rm -rf $SINGLE_DIR
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

export PATH="${CLANG_BIN}:$PATH"

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd $KSRC

## KernelSU setup
if ksu_is_included; then
  # Install kernelsu
  case "$KSU" in
    "Suki") install_ksu SukiSU-Ultra/SukiSU-Ultra $(if susfs_is_included; then echo "susfs-main"; elif ksu_manual_hook; then echo "nongki"; else echo "main"; fi) ;;
  esac
  config --enable CONFIG_KSU
fi

# SUSFS
if susfs_is_included; then
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

# KSU Manual Hooks
if ksu_manual_hook; then
  config --enable CONFIG_KSU_MANUAL_HOOK
  config --disable CONFIG_KSU_KPROBES_HOOK
  config --disable CONFIG_KSU_SUSFS_SUS_SU # Conflicts with manual hook
fi

# set localversion
if [[ $TODO == "kernel" ]]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  config --set-str CONFIG_LOCALVERSION "-${KERNEL_NAME}/$LATEST_COMMIT_HASH"
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(date)
MAKE_ARGS=(-j$(nproc --all) O="$OUTDIR" ARCH=arm64 CC=clang AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip LD=ld.lld HOSTLD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-)
KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image.gz-dtb"

text=$(
  cat << EOF
*$KERNEL_NAME CI*
🐧 *Linux Version*: $LINUX_VERSION
📅 *Build Date*: $KBUILD_BUILD_TIMESTAMP
📛 *KernelSU*: ${KSU}
ඞ *SuSFS*: $(susfs_is_included && echo "$SUSFS_VERSION" || echo "None")
🔰 *Compiler*: $COMPILER_STRING
EOF
)
MESSAGE_ID=$(send_msg "$text" 2>&1 | jq -r .result.message_id)

## Build GKI
log "Generating config..."
make ${MAKE_ARGS[@]} $KERNEL_DEFCONFIG

# Upload defconfig if we are doing defconfig
if [[ $TODO == "defconfig" ]]; then
  log "Uploading defconfig..."
  upload_file $OUTDIR/.config
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make ${MAKE_ARGS[@]}

if ! [ -f "$KERNEL_IMAGE" ]; then
  error "Kernel Image is not found, build aborted."
fi

## Post-compiling stuff
cd $WORKDIR

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Set kernel string in anykernel
BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
AK3_ZIP_NAME=${AK3_ZIP_NAME//BUILD_DATE/$BUILD_DATE}
sed -i \
  "s/kernel.string=.*/kernel.string=${KERNEL_NAME} for ${BUILD_DEVICE} (${BUILD_DATE}) ${VARIANT}/g" \
  $WORKDIR/anykernel/anykernel.sh

# Zip the anykernel
cd anykernel
log "Zipping anykernel..."
cp $KERNEL_IMAGE .
zip -r9 $WORKDIR/$AK3_ZIP_NAME ./*
cd $OLDPWD

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
  mkdir -p $WORKDIR/artifacts
  mv $WORKDIR/*.zip $WORKDIR/artifacts
fi

if [[ $LAST_BUILD == "true" && $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/raw/gki-android15-6.6/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "BUILD_DEVICE=$BUILD_DEVICE"
    echo "RELEASE_TAG=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d")"
    echo "RELEASE_REPO=$(simplify_gh_url "$RELEASES_REPO")"
  ) >> $WORKDIR/artifacts/info.txt
fi

if [[ $STATUS == "BETA" ]]; then
  reply_file "$MESSAGE_ID" "$WORKDIR/$AK3_ZIP_NAME"
  reply_file "$MESSAGE_ID" "$WORKDIR/build.log"
else
  reply_msg "$MESSAGE_ID" "✅ Build Succeeded"
fi

exit 0

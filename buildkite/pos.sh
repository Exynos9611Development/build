#!/bin/bash
set -eo pipefail

devices=("a51" "f41" "m31s" "m31" "m21")
lineage_ver=("22.1")
build_date=$(date -u +%Y%m%d)

rm -rf /tmp/android-*.log || true

function telegram() {
  result=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/$1" \
    -d "chat_id=@$TELEGRAM_GROUP_ID" \
    -d "parse_mode=markdown" \
    -d "text=$2")
}

install_deps() {
  DEBIAN_FRONTEND=noninteractive apt update
  DEBIAN_FRONTEND=noninteractive apt install -y bc netcat bison build-essential ccache curl flex g++-multilib gcc-multilib git gh git-lfs gnupg gperf imagemagick libncurses5-dev lib32ncurses5-dev lib32readline-dev lib32z1-dev libbz2-dev liblz4-tool libncurses5 libncurses5-dev libreadline-dev libsdl1.2-dev libsqlite3-dev libssl-dev libxml2 libxml2-utils llvm lzop openjdk-8-jdk pngcrush rsync s3cmd schedtool squashfs-tools wget zip zlib1g-dev python3 python3-pip libc6-dev-i386 x11proto-core-dev libx11-dev gnupg flex bison build-essential zip curl zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev xsltproc unzip fontconfig

  # repo
  curl -sLo /usr/local/bin/repo https://commondatastorage.googleapis.com/git-repo-downloads/repo 
  chmod +x /usr/local/bin/repo
}

notify_telegram() {
  echo "Sending message to Telegram"
  telegram sendmessage "Build $BUILDKITE_MESSAGE: [See progress]($BUILDKITE_BUILD_URL)"
}

setup_git() {
  echo "Setting up git"
  gh auth login --with-token "$GITHUB_TOKEN"
  git config --global user.email "$GITHUB_EMAIL"
  git config --global user.name "$GITHUB_USERNAME"
}

init() {
  check_storage
  setup_zram
}

check_storage() {
  local total_storage available_storage
  total_storage=$(df -h | awk '/\/$/ {print $4}')
  available_storage=${total_storage%G}
  if [ "$available_storage" -lt 250 ]; then
    echo "You need at least 250 GB of free storage to build ROM!"
    exit 1
  fi
}

setup_zram() {
  if ! grep -q -e 'zram' -e 'swap' /proc/swaps; then
    local total_ram zram_size
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    zram_size=$((total_ram * 2))M
    echo "Setting up ZRAM"
    modprobe zram num_devices=1
    zramctl --find --size "$zram_size"
    mkswap /dev/zram0
    swapon /dev/zram0
  else
    echo "ZRAM is already enabled."
  fi
}

repo_init() {
  if [ ! -d /pos ]; then
    mkdir /pos
    cd /pos
    repo init -u https://github.com/pixelos/android.git -b 15 --git-lfs --depth=1  | tee /tmp/android-sync.log
    git clone https://github.com/Exynos9611Development/local_manifests .repo/local_manifests -b lineage-"${lineage_ver[0]}" --depth=1 | tee /tmp/android-sync.log
  else
    cd /pos
  fi
}

sync_repo() {
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log
  repo forall -c "git lfs pull"
}

setup_signing() {
  echo "Setting up signing"
  git clone git@github.com:Exynos9611Development/android_vendor_lineage-priv.git vendor/lineage-priv -b pixelos | tee /tmp/android-sync.log
}

setup_ccache() {
  local ccache_size
  ccache_size=$(echo "$available_storage * 0.5 - 250" | bc -l)
  ccache_size=$(echo "$ccache_size < 0 ? 0 : $ccache_size" | bc -l)
  if (( $(echo "$ccache_size > 0" | bc -l) )); then
    echo "Setting up ccache" | tee /tmp/android-build.log
    export USE_CCACHE=1
    export CCACHE_EXEC=/usr/bin/ccache
    ccache -M "${ccache_size}G" | tee /tmp/android-build.log
  fi
}

adapt_for_aosp() {
  echo "Adapting common tree for aosp"
  cd device/samsung/universal9611-common
  sed -i '/# Touch HAL/,+2d' common.mk
  sed -i '/# FastCharge/,+2d' common.mk
  cd ../../../
  for device in "${devices[@]}"; do
    echo "Adapting $device for aosp" | tee -a android-build.log
    cd device/samsung/"$device" || { echo "Directory device/samsung/$device not found"; continue; } | tee -a android-build.log
    mv lineage_"$device".mk aosp_"$device".mk
    sed -i 's/lineage_/aosp_/g' AndroidProducts.mk
    sed -i 's/lineage/aosp/g' aosp_"$device".mk
    cd ../../../
  done
}

build_device() {
  local device=$1
  source build/envsetup.sh
  echo "Building ROM for $device" | tee /tmp/android-build.log
  brunch $device user 2>&1 | tee /tmp/android-build.log
}

upload_rom() {
  local tag_name="POS-$build_date" 
  git clone https://github.com/Exynos9611Development/OTA OTA
  for device in "${devices[@]}"; do
    cp out/target/product/"$device"/PixelOS*-"$build_date"-UNOFFICIAL-"$device".zip OTA/
    cp out/target/product/"$device"/recovery.img OTA/recovery-"$device".img
  done
  cd OTA
  gh release create "$tag_name" --title "$tag_name"
  gh release upload "$tag_name" *.zip *.img
}

cleanup() {
  cd ~/
  rm -rf /crdroid ~/.cache ~/.ccache
  DEBIAN_FRONTEND=noninteractive apt autoremove -y
}

post_telegram() {
  telegram sendmessage "Build ${build_display_name} is finished!\n\nDate: $tag_name\nType: UNOFFICIAL\n\nDownload: [Link](https://github.com/Exynos9611Development/OTA/releases/tag/$tag_name)\n\nKnown quirks:\n- IMS" "Markdown"
}

main() {
  install_deps
  notify_telegram
  setup_git
  init
  repo_init
  sync_repo
  setup_signing
  setup_ccache
  adapt_for_aosp
  for device in "${devices[@]}"; do
    build_device "$device"
  done
  upload_rom
  post_telegram
  cleanup
}

main

#!/bin/bash
set -eo pipefail

devices=("a51" "f41" "m31s" "m31" "m21")
build_date=$(date -u +%Y%m%d)
rom_dir="/pixelos"
lineage_ver="22.1"
android_ver="15.0"
pos_ver="fifteen"

source /buildkite/hooks/env

telegram() {
  RESULT=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/$1" \
	  -d "chat_id=@$TELEGRAM_GROUP_ID" \
	  -d "parse_mode=Markdown" \
	  -d "message_id=$(cat .msgid 2>/dev/null)" \
	  -d "text=$2")
  MESSAGE_ID=$(jq '.result.message_id' <<<"$RESULT")
  [[ $MESSAGE_ID =~ ^[0-9]+$ ]] && echo "$MESSAGE_ID" > .msgid
}

install_deps() {
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y bc netcat bison build-essential ccache curl flex g++-multilib gcc-multilib git gh git-lfs gnupg gperf imagemagick libncurses5-dev lib32ncurses5-dev lib32readline-dev lib32z1-dev libbz2-dev liblz4-tool libncurses5 libncurses5-dev libreadline-dev libsdl1.2-dev libsqlite3-dev libssl-dev libxml2 libxml2-utils llvm lzop openjdk-8-jdk pngcrush rsync s3cmd schedtool squashfs-tools wget zip zlib1g-dev python3 python3-pip libc6-dev-i386 x11proto-core-dev libx11-dev gnupg flex bison build-essential zip curl zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev xsltproc unzip fontconfig

  # repo
  curl -sLo /usr/local/bin/repo https://commondatastorage.googleapis.com/git-repo-downloads/repo 
  chmod +x /usr/local/bin/repo
}

setup_git() {
  echo "Setting up git"
  git config --global user.email "$GITHUB_EMAIL"
  git config --global user.name "$GITHUB_USERNAME"
}

init() {
  check_storage
  setup_zram
}

check_storage() {
  local total_storage
  total_storage=$(df -h | awk '/\/$/ {print $4}')
  available_storage=${total_storage%G}
  if [ "$available_storage" -lt 250 ] && [ ! -d "$rom_dir"/ ] && [ ! -d /crdroidandroid ] && [ ! -d /lineage ]; then
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
  if [ ! -d "$rom_dir"/ ] && [ ! -d "$rom_dir"/.repo/ ]; then
    rm -rf /crdroidandroid /lineage
    mkdir "$rom_dir"/
    cd "$rom_dir"/
    repo init -u https://github.com/pixelos-aosp/manifest.git -b "$pos_ver" --git-lfs --depth=1  | tee /tmp/android-sync.log
    git clone https://github.com/Exynos9611Development/local_manifests .repo/local_manifests -b lineage-"$lineage_ver" --depth=1 | tee /tmp/android-sync.log
  else
    cd "$rom_dir"/
  fi
}

notify_telegram() {
  echo "Notifying telegram about job"
  telegram_message="Building $BUILDKITE_PIPELINE_NAME: [See progress]($BUILDKITE_BUILD_URL)
Build status:"
  telegram sendmessage "$telegram_message Started"
}

sync_repo() {
  echo "Syncing"
  telegram editMessageText "$telegram_message Syncing"
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log
  repo forall -c "git lfs pull"
}

setup_signing_and_ota() {
  if [ ! -d "$rom_dir"/vendor/extra ]; then
    echo "Setting up signing and OTA"
    telegram editMessageText "$telegram_message Setuping signing"
    git clone git@github.com:Exynos9611Development/android_vendor_lineage-priv.git vendor/extra -b pixelos | tee /tmp/android-sync.log
  fi
}

setup_ccache() {
  local ccache_size
  ccache_size=$(echo "$available_storage * 0.5 - 250" | bc -l)
  if (( $(echo "$ccache_size > 0" | bc -l) )); then
    echo "Setting up ccache" | tee /tmp/android-build.log
    export USE_CCACHE=1
    export CCACHE_EXEC=/usr/bin/ccache
    ccache -M "${ccache_size}G" | tee -a /tmp/android-build.log
  else
    echo "Insufficient storage for ccache setup" | tee /tmp/android-build.log
  fi
}

adapt_for_aosp() {
  echo "Adapting common tree for aosp"
  telegram editMessageText "$telegram_message Adapting trees for aosp"
  cd "$rom_dir"/device/samsung/universal9611-common
  sed -i 's|vendor/lineage/|vendor/aosp/|g' BoardConfigCommon.mk
  echo "Adapting hardware for aosp"
  cd "$rom_dir"/hardware/samsung
  rm -rf AdvancedDisplay doze
  for device in "${devices[@]}"; do
    echo "Adapting $device for aosp"
    cd "$rom_dir"/device/samsung/"$device"
    if [ -f lineage_"$device".mk ]; then
      mv lineage_"$device".mk aosp_"$device".mk
      sed -i 's/lineage_/aosp_/g' AndroidProducts.mk
      sed -i 's/lineage/aosp/g' aosp_"$device".mk
    else
       echo "Skipping adapting $device"
    fi
    cd "$rom_dir"
  done
}

build_device() {
  local device=$1
  set +u
  telegram editMessageText "$telegram_message Building $device"
  echo "Building ROM for $device" | tee /tmp/android-build.log
  source build/envsetup.sh
  brunch "$device" user -j$(nproc) 2>&1 | tee /tmp/android-build.log
  set -u
}

upload_rom() {
  local out_dir ota_dir
  tag_name="POS-$build_date"
  out_dir="$rom_dir/out"
  ota_dir="$rom_dir/ota"
  telegram editMessageText "$telegram_message Uploading"
  if [ ! -d "$ota_dir" ]; then
  git clone https://github.com/Exynos9611Development/OTA "$ota_dir"
  fi
  cd "$ota_dir"
  git clean -xfd
  for device in "${devices[@]}"; do
    cp "$out_dir"/target/product/"$device"/PixelOS_"$device"-"$android_ver"-"$build_date"-*.zip "$ota_dir"/
    cp "$out_dir"/target/product/"$device"/recovery.img "$ota_dir"/recovery-"$device".img
  done
  gh release create "$tag_name" --title "$tag_name" --generate-notes -p
  gh release upload "$tag_name" ./*.zip ./*.img
  git push
  cd "$rom_dir"/
}

post_telegram() {
  local os_patch_lvl
  os_patch_lvl=$(grep -oP '(?<=\.)\d{6}(?=\.)' build/core/build_id.mk)
  telegram_message_edit="
Devices: ${devices[*]}

Type: UNOFFICIAL
OS patch Level: $os_patch_lvl

Download: [Link](https://github.com/Exynos9611Development/OTA/releases/tag/$tag_name)"
  telegram editMessageText "$telegram_message finished! $telegram_message_edit"
}

cleanup() {
  rm -rf out/ /tmp/* .result.message_id .msgid
  DEBIAN_FRONTEND=noninteractive apt autoremove -y
}

main() {
  install_deps
  setup_git
  init
  repo_init
  notify_telegram
  sync_repo
  setup_signing_and_ota
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

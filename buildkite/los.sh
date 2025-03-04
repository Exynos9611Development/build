#!/bin/bash
set -eo pipefail

devices=("a51" "f41" "m31s" "m31" "m21")
lineage_ver=("22.1")
build_date=$(date -u +%Y%m%d)

source /buildkite/hooks/env

telegram() {
  RESULT=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/$1" \
	  -d "chat_id=@$TELEGRAM_GROUP_ID" \
	  -d "parse_mode=Markdown" \
	  -d "message_id=$(cat .msgid 2>/dev/null)" \
	  -d "text=$2")
  MESSAGE_ID=$(jq '.result.message_id' <<<"$RESULT")
  [[ $MESSAGE_ID =~ ^[0-9]+$ ]] && echo "$MESSAGE_ID" > .msgid

  telegram_message="Building $BUILDKITE_MESSAGE: [See progress]($BUILDKITE_BUILD_URL)
Build status:"
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
  local total_storage available_storage
  total_storage=$(df -h | awk '/\/$/ {print $4}')
  available_storage=${total_storage%G}
  if [ "$available_storage" -lt 250 ] && [ ! -d /lineage/ ]; then
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
  if [ ! -d /lineage/ ] && [ ! -d /lineage/.repo/ ]; then
    mkdir /lineage
    cd /lineage/
    repo init -u https://github.com/lineageos/android.git -b lineage-"${lineage_ver[0]}" --git-lfs --depth=1  | tee /tmp/android-sync.log
    git clone https://github.com/Exynos9611Development/local_manifests .repo/local_manifests -b lineage-"${lineage_ver[0]}" --depth=1 | tee /tmp/android-sync.log
  else
    cd /lineage
  fi
}

notify_telegram() {
  echo "Notifying telegram about job"
  telegram sendmessage "${telegram_message} Started"
}

sync_repo() {
  echo "Syncing"
  telegram editMessageText "${telegram_message} Syncing"
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee -a /tmp/android-sync.log
  repo forall -c "git lfs pull"
}

setup_signing_and_ota() {
  if [ ! -d /lineage/vendor/lineage_priv ] && [ ! -d /lineage/vendor/lineage/OTA ]; then
    telegram editMessageText "${telegram_message} Setuping signing"
    echo "Setting up signing and OTA"
    git clone https://github.com/cat658011/json_ota_generator vendor/lineage/OTA | tee android-sync.log
    sed -i 's/ChangeToYourOwnURL/https:\/\/github.com\/Exynos9611Development\/OTA\/releases\/download\/%s\/%s/g' vendor/lineage/OTA/generate_ota_json.sh
    sed -i "/@echo \"Package Complete: $(LINEAGE_TARGET_PACKAGE)\"/i \	$(hide) ./vendor/lineage/OTA/generate_ota_json.sh $(LINEAGE_TARGET_PACKAGE)" vendor/lineage/build/tasks/bacon.mk
    git clone git@github.com:Exynos9611Development/android_vendor_lineage-priv.git vendor/lineage-priv -b lineage-"${lineage_ver[0]}" | tee /tmp/android-sync.log
    for device in "${devices[@]}"; do
      echo "lineage.updater.uri=https://raw.githubusercontent.com/Exynos9611Development/OTA/lineage/${device}/ota.json" >> device/samsung/"$device"/vendor.prop
    done
  fi
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

build_device() {
  local device=$1
  source build/envsetup.sh
  telegram editMessageText "$telegram_message Building $device"
  echo "Building ROM for $device" | tee /tmp/android-build.log
  set +u
  brunch "$device" user -j 2>&1 | tee /tmp/android-build.log
  set -u
}

upload_rom() {
  tag_name="$build_date"
  telegram editMessageText "$telegram_message Uploading"
  if [ ! -d /lineage/OTA ]; then
  git clone https://github.com/Exynos9611Development/OTA OTA
  fi
  for device in "${devices[@]}"; do
    cp out/target/product/"$device"/lineage-"${lineage_ver[0]}"-"$build_date"-UNOFFICIAL-"$device".zip OTA/
    cp out/target/product/"$device"/recovery.img OTA/recovery-"$device".img
    cp out/target/product/"$device"/ota.json OTA/"$device"/ota.json
  done
  cd OTA
  git clean -xfd
  git add ./*/*.json
  git commit -m "ota: JSON update ${tag_name} LineageOS ${lineage_ver[0]}"
  gh release create "$tag_name" --title "$tag_name" --generate-notes
  gh release upload "$tag_name" ./*.zip ./*.img
  git push
  cd ../
}

post_telegram() {
  os_patch_lvl=$(grep -r RELEASE_PLATFORM_SECURITY_PATCH build/release/build_config/ap*a.scl | tr -d ", \"a-zA-Z()")
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
  for device in "${devices[@]}"; do
    build_device "$device"
  done
  upload_rom
  post_telegram
  cleanup
}

main


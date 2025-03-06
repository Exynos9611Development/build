#!/bin/bash
set -e

devices=("a51" "f41" "m31s" "m31" "m21")

install_deps() {
    local debian_deps=(bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick libncurses5-dev lib32ncurses5-dev lib32readline-dev lib32z1-dev libbz2-dev liblz4-tool libncurses5 libncurses5-dev libreadline-dev libsdl1.2-dev libsqlite3-dev libssl-dev libxml2 libxml2-utils llvm lzop openjdk-8-jdk pngcrush rsync s3cmd schedtool squashfs-tools wget zip zlib1g-dev python3 python3-pip libc6-dev-i386 x11proto-core-dev libx11-dev gnupg flex bison build-essential zip curl zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev xsltproc unzip fontconfig)
    local arch_deps=(base-devel ccache curl flex gcc git git-lfs gnupg gperf imagemagick ncurses lib32-ncurses lib32-readline lib32-zlib bzip2 lz4 ncurses readline sdl libsqlite3 openssl libxml2 llvm lzop jdk8-openjdk pngcrush rsync s3cmd schedtool squashfs-tools wget zip zlib python3 python-pip libc6-compat xorgproto libx11)
    local fedora_deps=(ccache curl flex gcc git git-lfs gnupg gperf ImageMagick ncurses-devel readline-devel bzip2 lz4 ncurses readline SDL-devel sqlite-devel openssl-devel libxml2 libxml2-utils llvm lzop java-1.8.0-openjdk pngcrush rsync s3cmd schedtool squashfs-tools wget zip zlib-devel python3 python3-pip glibc-devel.i686)
    local centos_deps=(ccache curl flex gcc git git-lfs gnupg gperf ImageMagick ncurses-devel readline-devel bzip2 lz4 ncurses readline SDL-devel sqlite-devel openssl-devel libxml2 libxml2-utils llvm lzop java-1.8.0-openjdk pngcrush rsync s3cmd schedtool squashfs-tools wget zip zlib-devel python3 python3-pip glibc-devel.i686)

    if command -v apt &> /dev/null; then
        if ! apt list --installed 2>/dev/null | grep -q "^$(printf "%s\s\[" "${debian_deps[@]}")"; then
            sudo apt update
            sudo apt install -y "${debian_deps[@]}"
        fi
    elif command -v pacman &> /dev/null; then
        if ! pacman -Qq | grep -q "^$(printf "%s\s\[" "${arch_deps[@]}")"; then
            sudo pacman -Syu --needed "${arch_deps[@]}"
        fi
    elif command -v dnf &> /dev/null; then
        if ! rpm -q "${fedora_deps[@]}" &>/dev/null; then
            sudo dnf install -y "${fedora_deps[@]}"
        fi
    elif command -v yum &> /dev/null; then
        if ! rpm -q "${centos_deps[@]}" &>/dev/null; then
            sudo yum install -y "${centos_deps[@]}"
        fi
    else
        echo "Unsupported distribution"
        exit 1
    fi

    # repo
    sudo curl -sLo /usr/local/bin/repo https://commondatastorage.googleapis.com/git-repo-downloads/repo 
    sudo chmod +x /usr/local/bin/repo
}

init() {
  check_storage
  setup_zram
}

check_storage() {
  local total_storage
  total_storage=$(df -h | awk '/\/$/ {print $4}')
  available_storage=${total_storage%G}
  if [ "$available_storage" -lt 250 ] && [ ! -d "$rom_dir"/ ]; then
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

select_rom() {
  echo "Which ROM do you want to build?"
  echo "1. LineageOS"
  echo "2. crDroid"
  echo "3. PixelOS"
  read -s -p "" ROM
  case $ROM in
    1) echo "ROM: LineageOS"; ROM_NAME="lineage" ;;
    2) echo "ROM: crDroid"; ROM_NAME="crdroid" ;;
    3) echo "ROM: PixelOS"; ROM_NAME="pixelos" ;;
    *) echo "Invalid option."; exit 1 ;;
  esac
}

repo_init() {
  local dir_name repo_url
  case $ROM_NAME in
    lineage) rom_dir="lineage"; repo_url="https://github.com/LineageOS/android.git" ;;
    crdroid) rom_dir="crdroid"; repo_url="https://github.com/crdroidandroid/android.git" ;;
    pixelos) rom_dir="pixelos"; repo_url="https://github.com/PixelOS/android.git" ;;
  esac

  if [ ! -d "$rom_dir" ] && [ ! -d "$rom_dir/.repo" ]; then
    mkdir "$rom_dir"
    cd "$rom_dir"
    repo init -u "$repo_url" --depth=1 --git-lfs
  else
    cd "$dir_name"
  fi

  if [ ! -d .repo/local_manifests ]; then
    git clone https://github.com/Exynos9611Development/local_manifests .repo/local_manifests --depth=1
  fi
}

sync_repo() {
  echo "Syncing"
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 || true
  repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1
  repo forall -c "git lfs pull"
}

setup_ccache() {
  local ccache_size
  ccache_size=$(echo "$available_storage * 0.5 - 250" | bc -l)
  if (( $(echo "$ccache_size > 0" | bc -l) )); then
    echo "Setting up ccache" | tee /tmp/android-build.log
    export USE_CCACHE=1
    export CCACHE_EXEC=/usr/bin/ccache
    ccache -M "${ccache_size}G" | tee /tmp/android-build.log
  fi
}

adapt_for_aosp() {
  if [ "$ROM_NAME" = "pixelos" ]; then
    echo "Adapting common tree for aosp"
    cd device/samsung/universal9611-common
    sed -i '/# Touch HAL/,+2d' common.mk
    sed -i '/# FastCharge/,+2d' common.mk
    cd "$rom_dir"
    for device in "${devices[@]}"; do
      echo "Adapting $device for aosp" | tee android-build.log
      cd device/samsung/"$device"
      mv lineage_"$device".mk aosp_"$device".mk
      sed -i 's/lineage_/aosp_/g' AndroidProducts.mk
      sed -i 's/lineage/aosp/g' aosp_"$device".mk
      cd "$rom_dir"
    done
  fi
}

device_for_build() {
  echo "Which device/s do you want to build?"
  echo "1. A51"
  echo "2. F41"
  echo "3. M31s"
  echo "4. M31"
  echo "5. M21"
  echo "6. All devices"
  read -r -p "" build_device
  if (( $(echo "$build_device >= 1 && $build_device <= 6" | bc -l) )); then
    if (( $(echo "$build_device == 6" | bc -l) )); then
      echo "Building ROM for all devices!"
      for device in "${devices[@]}"; do
        build_device "$device"
      done
    else
      build_device "${devices[$build_device-1]}"
    fi
  else
    echo "Please choose a valid option."
  fi
}

build_device() {
  local device=$1
  set +u
  source build/envsetup.sh
  brunch "$device" user -j
  set -u
}

main() {
  install_deps
  select_rom
  init
  repo_init
  sync_repo
  setup_ccache
  adapt_for_aosp
  select_device_for_build
}

main

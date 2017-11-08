#!/bin/sh
# shellcheck shell=dash

#
# Build Chromium for Amazon Linux.
# Assumes root privileges. (Or, more likely, Docker)
#
# Requires 
#
# Usage: ./build.sh
#

set -e

BUILD_BASE=$(pwd)
VERSION=${VERSION:-master}
CLEAN_UP=${CLEANUP:-true}

printf "LANG=en_US.utf-8\nLC_ALL=en_US.utf-8" >> /etc/environment

# install dependencies
yum install epel-release -y
yum install -y \
  git redhat-lsb python bzip2 tar pkgconfig atk-devel \
  alsa-lib-devel bison binutils brlapi-devel bluez-libs-devel \
  bzip2-devel cairo-devel cups-devel dbus-devel dbus-glib-devel \
  expat-devel fontconfig-devel freetype-devel gcc-c++ GConf2-devel \
  glib2-devel glibc.i686 gperf glib2-devel gtk2-devel gtk3-devel \
  java-1.*.0-openjdk-devel libatomic libcap-devel libffi-devel \
  libgcc.i686 libgnome-keyring-devel libjpeg-devel libstdc++.i686 \
  libX11-devel libXScrnSaver-devel libXtst-devel \
  libxkbcommon-x11-devel ncurses-compat-libs nspr-devel nss-devel \
  pam-devel pango-devel pciutils-devel pulseaudio-libs-devel \
  zlib.i686 httpd mod_ssl php php-cli python-psutil wdiff --enablerepo=epel

mkdir -p build/chromium

cd build

# install dept_tools
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git

export PATH="/opt/gtk/bin:$PATH:$BUILD_BASE/build/depot_tools"

cd chromium

# fetch chromium source code
# ref: https://www.chromium.org/developers/how-tos/get-the-code/working-with-release-branches
git clone https://chromium.googlesource.com/chromium/src.git

(
  cd src

  # Do a pull because there are usually revisions pushed while we're cloning
  git pull

  # checkout the release tag
  git checkout -b build "$VERSION"
)

# Checkout all the submodules at their branch DEPS revisions
gclient sync --with_branch_heads --jobs 16

cd src

# tweak to disable use of the tmpfs mounted at /dev/shm
sed -e '/if (use_dev_shm) {/i use_dev_shm = false;\n' -i base/files/file_util_posix.cc

#
# tweak to keep Chrome from crashing after 4-5 Lambda invocations
# see https://github.com/adieuadieu/serverless-chrome/issues/41#issuecomment-340859918
# Thank you, Geert-Jan Brits (@gebrits)!
#
# path of sandbox_ipc_linux.cc differs between chromium 62 and 63+
# this is a temporary workaround to handle both
SANDBOX_IPC_SOURCE_PATH="content/browser/sandbox_ipc_linux.cc"
case "$VERSION" in
  62.*)
   SANDBOX_IPC_SOURCE_PATH="content/browser/renderer_host/sandbox_ipc_linux.cc"
  ;;
esac

sed -e 's/PLOG(WARNING) << "poll";/PLOG(WARNING) << "poll"; failed_polls = 0;/g' -i "$SANDBOX_IPC_SOURCE_PATH"


# specify build flags
mkdir -p out/Headless && \
  echo 'import("//build/args/headless.gn")' > out/Headless/args.gn && \
  echo 'is_debug = false' >> out/Headless/args.gn && \
  echo 'symbol_level = 0' >> out/Headless/args.gn && \
  echo 'is_component_build = false' >> out/Headless/args.gn && \
  echo 'remove_webcore_debug_symbols = true' >> out/Headless/args.gn && \
  echo 'enable_nacl = false' >> out/Headless/args.gn && \
  gn gen out/Headless

# build chromium headless shell
ninja -C out/Headless headless_shell

cp out/Headless/headless_shell "$BUILD_BASE/headless-chromium-unstripped"

cd "$BUILD_BASE"

# strip symbols
strip -o "$BUILD_BASE/headless-chromium" build/chromium/src/out/Headless/headless_shell

# Use UPX to package headless chromium
# this adds 1-1.5 seconds of startup time so generally
# not so great for use in AWS Lambda so we don't actually use it 
# but left here in case someone finds it useful
# yum install -y ucl ucl-devel --enablerepo=epel
# cd build
# git clone https://github.com/upx/upx.git
# cd build/upx
# git submodule update --init --recursive
# make all
# cp "$BUILD_BASE/build/chromium/src/out/Headless/headless_shell" "$BUILD_BASE/headless-chromium-packaged"
# src/upx.out "$BUILD_BASE/headless-chromium-packaged"

if [ "$CLEAN_UP" = "true" ]; then
  rm -Rf build/
  # @TODO: also remove the yum packages we installed?
fi
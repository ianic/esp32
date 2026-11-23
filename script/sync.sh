#!/usr/bin/env bash

set -e
cd $(git rev-parse --show-toplevel)

mkdir -p cmake
mkdir -p include
mkdir -p imports
mkdir -p patches

rsync -av zig-esp-idf-sample/cmake/ cmake/
rsync -av zig-esp-idf-sample/include/ include/
rsync -av zig-esp-idf-sample/imports/ imports/
rsync -av zig-esp-idf-sample/patches/ patches/

exit 0

# to update esp-idf

git clone --recursive https://github.com/espressif/esp-idf.git

# to checkout some tag
git checkout v6.1.1

cd ~/Code/esp32/esp-idf
git pull
git checkout release/v6.1
git submodule sync --recursive
git submodule update --init --recursive

unset IDF_PYTHON_ENV_PATH
./install.sh esp32c3
. ./export.sh



cp -r cmake/* zig-esp-idf-sample/cmake/ 
cp -r include/* zig-esp-idf-sample/include/
cp -r imports/* zig-esp-idf-sample/imports/
cp -r patches/* zig-esp-idf-sample/patches/


rsync -av zig-esp-idf-sample/imports/ imports/
rsync -av zig-esp-idf-sample/patches/ patches/

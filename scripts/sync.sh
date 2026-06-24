#!/usr/bin/env bash

set -e
cd $(git rev-parse --show-toplevel)

mkdir -p cmake
mkdir -p include
mkdir -p imports
mkdir -p patches

rsync -av ../zig-esp-idf-sample/cmake/ cmake/
rsync -av ../zig-esp-idf-sample/include/ include/
rsync -av ../zig-esp-idf-sample/imports/ imports/
rsync -av ../zig-esp-idf-sample/patches/ patches/

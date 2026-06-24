#!/usr/bin/env bash

set -e
cd $(git rev-parse --show-toplevel)

# Initialize a default value for the variable
rebuild=false

if [ ! -d "build" ]; then
    rebuild=true
fi

while getopts "r" opt; do
    case ${opt} in
    r)
        rebuild=true
        ;;
    \?)
        echo "Invalid option: -$OPTARG" 1>&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

. ../esp-idf/export.sh

if [ "$rebuild" = true ]; then
    rm -rf build
    idf.py set-target esp32c3
fi

idf.py build
idf.py -p /dev/ttyUSB0 flash monitor

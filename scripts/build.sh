#!/usr/bin/env bash

set -e
cd $(git rev-parse --show-toplevel)

# Initialize a default value for the variable
rebuild=false
project=main/app.zig

if [ ! -d "build" ]; then
    rebuild=true
fi

while getopts "rp:" opt; do
    case ${opt} in
    r)
        rebuild=true
        ;;
    p)
        project=main/"$OPTARG".zig # Captures the value passed with -p
        ;;
    \?)
        echo "Invalid option: -$OPTARG" 1>&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

echo Building: $project

. ../esp-idf/export.sh

if [ "$rebuild" = true ]; then
    # rm -rf build
    idf.py set-target esp32c3
    idf.py build -DZIG_PROJECT_ROOT=$project
    idf.py -p /dev/ttyUSB0 flash monitor
fi

idf.py app -DZIG_PROJECT_ROOT=$project
idf.py -p /dev/ttyUSB0 app-flash monitor

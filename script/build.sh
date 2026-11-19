#!/usr/bin/env bash

set -e
cd $(git rev-parse --show-toplevel)


# Initialize a default value for the variable
rebuild=false
project=blink
#port=/dev/ttyUSB0
port=/dev/ttyACM0

if [ ! -d "build" ]; then
    rebuild=true
fi

while getopts "rp:" opt; do
    case ${opt} in
    r)
        rebuild=true
        ;;
    p)
        project="$OPTARG" # Captures the value passed with -p
        ;;
    \?)
        echo "Invalid option: -$OPTARG" 1>&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

echo Building: $project

unset IDF_PYTHON_ENV_PATH
. esp-idf/export.sh


if [ "$rebuild" = true ]; then
    rm -rf build
    idf.py fullclean
    rm sdkconfig
    idf.py set-target esp32c3
    
    idf.py build -DZIG_PROJECT=$project #-DZIG_BUILD_TYPE=ReleaseSmall
    idf.py size
    idf.py size-components
    idf.py -p $port flash monitor
    exit 0
fi

idf.py app -DZIG_PROJECT=$project -DZIG_BUILD_TYPE=Debug
idf.py size
idf.py size-components
idf.py -p $port app-flash monitor
# idf.py -p $port monitor

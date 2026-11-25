#!/usr/bin/env bash

set -e
cd $(git rev-parse --show-toplevel)


# Initialize a default value for the variable
rebuild=false
no_deploy=false
project=blink
#port=/dev/ttyUSB0
port=/dev/ttyACM0

# if build folder is not found, first build
if [ ! -d "build" ]; then
    rebuild=true
fi

while getopts "rnp:" opt; do
    case ${opt} in
    r)
        rebuild=true
        ;;
    n)
        no_deploy=true
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

export KCONFIG_REPORT_VERBOSITY=quiet

if [ "$rebuild" = true ]; then
    rm -rf build
    idf.py fullclean
    rm sdkconfig
    idf.py set-target esp32c3
    
    idf.py build -DZIG_PROJECT=$project -DZIG_BUILD_TYPE=ReleaseSmall
    idf.py size
    idf.py size-components
    if [ "$no_deploy" = false ]; then
        idf.py -p $port flash monitor
    fi
    exit 0
fi

idf.py app -DZIG_PROJECT=$project -DZIG_BUILD_TYPE=ReleaseSmall
# idf.py size
# idf.py size-components

if [ "$no_deploy" = false ]; then
    # use flash instead of app-flash when testing/using ota
    # app-flash is flashing to ota_0, but ota_1 can be active
    # flash resets ota config
    idf.py -p $port app-flash monitor
fi
# idf.py -p $port monitor


exit 0

# switch ota partition
otatool.py --port $port switch_ota_partition --name ota_0

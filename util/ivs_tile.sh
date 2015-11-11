#!/usr/bin/env bash

set -o errexit
set -o nounset

export CLAM3_KERNEL=$1
IVS_TEMP_DIR=$2
export CLAM3_CONNECT=$3
export CLAM3_DEVICE=$4
SCREENWIDTH=1920
SCREENHEIGHT=1080
MAX_SCREENCOORDS_X=2
MAX_SCREENCOORDS_Y=4

# Prints a very readable bold message that stands out
function printMessage()
{
    echo "$(tput sgr 0)$(tput bold)== ${BASH_SOURCE} ===> $(tput setaf 1)$@$(tput sgr 0)"
}

cd "${IVS_TEMP_DIR}/build"
SLAVE=$(hostname -s)
case ${SLAVE}_${CLAM3_DEVICE} in
    tile-0-3_0)
        WIN_X=0
        WIN_Y=0
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-3_1)
        WIN_X=2
        WIN_Y=0
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-2_0)
        WIN_X=0
        WIN_Y=1
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-2_1)
        WIN_X=2
        WIN_Y=1
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-1_0)
        WIN_X=0
        WIN_Y=2
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-1_1)
        WIN_X=2
        WIN_Y=2
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-0_0)
        WIN_X=0
        WIN_Y=3
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-0_1)
        WIN_X=2
        WIN_Y=3
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-7_0)
        WIN_X=4
        WIN_Y=0
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-7_1)
        WIN_X=3
        WIN_Y=0
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-6_0)
        WIN_X=4
        WIN_Y=1
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-6_1)
        WIN_X=3
        WIN_Y=1
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-5_0)
        WIN_X=4
        WIN_Y=2
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-5_1)
        WIN_X=3
        WIN_Y=2
        LOC_X=1
        WIN_W=1
        ;;
        
    tile-0-4_0)
        WIN_X=4
        WIN_Y=3
        LOC_X=0
        WIN_W=2
        ;;
    tile-0-4_1)
        WIN_X=3
        WIN_Y=3
        LOC_X=1
        WIN_W=1
        ;;
    *)
        printMessage "Unknown tile location for ${SLAVE}_${CLAM3_DEVICE}"
        ;;
esac
renderposX=$(bc <<< "$SCREENWIDTH * ${WIN_W} * (${WIN_X} - $MAX_SCREENCOORDS_X / 2)")
renderposY=$(bc <<< "$SCREENHEIGHT * (${WIN_Y} - $MAX_SCREENCOORDS_Y / 2)")
winposX=$(bc <<< "$SCREENWIDTH * ${LOC_X}")
export CLAM3_RENDEROFFSET=${renderposX}x${renderposY}
export CLAM3_WINDOWPOS=${SCREENWIDTH}x${SCREENHEIGHT}+${winposX}+0
export DISPLAY=:0
printMessage "Booting ${SLAVE} render process: run ${CLAM3_KERNEL} on GPU${CLAM3_DEVICE} at ${SCREENWIDTH}x${SCREENHEIGHT}+${renderposX}+${renderposY} connect ${CLAM3_CONNECT}"
./clam3

#!/usr/bin/env bash

#############################################################
# Parse command line inputs
USER_INTERACTION=ON


#############################################################
# Various niceties that make the script look pretty

## Colors
BAD="\033[1;31m"
GOOD="\033[1;32m"
WARN="\033[1;35m"
INFO="\033[1;34m"
BOLD="\033[1m"

## Color echo
color_echo() {
	COLOR=$1; shift
	echo -e "${COLOR}$@\033[0m"
}

## Exit with some useful information
quit_if_fail() {
	STATUS=$?
    if [ ${STATUS} -ne 0 ]; then
        cecho ${BAD} 'Failure with exit status:' ${STATUS}
        cecho ${BAD} 'Exit message:' $1
        exit ${STATUS}
    fi
}

#############################################################

color_echo ${BAD} "WOW"
#!/usr/bin/env bash

#############################################################
# Grab the cfg file
if [ -f "candi.cfg" ]; then
  source candi.cfg
else
  color_echo ${BAD} "No configuration file found. Please create a candi.cfg file."
  exit 1
fi

#############################################################
# Grab the date and start a global timer
if builtin command -v gdate >/dev/null; then
  DATE_CMD=$(which gdata)
else
  DATE_CMD=$(which date)
fi
TIC_GLOBAL="$(${DATE_CMD} +%s)"

#############################################################
# Parse command line inputs
JOBS=1
USE_DEFAULT_COMPILER=OFF

while [ -n "$1" ]; do
  input="$1"
  case $input in

  -h | --help)
    echo "deal.II spack packaging for PRISMS-PF"
    echo ""
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --default=<ON/OFF> override to use default spack compiler (default = ${USE_DEFAULT_COMPILER})"
    echo "  -j <N>, -j<N>, --jobs=<N>  compile with N processes in parallel (default = ${JOBS})"
    exit 0
    ;;

  --default=*)
    USE_DEFAULT_COMPILER="${input#*=}"
    if [[ "$USE_DEFAULT_COMPILER" != "ON" && "$USE_DEFAULT_COMPILER" != "OFF" ]]; then
      color_echo ${BAD} "Invalid value for --default: $USE_DEFAULT_COMPILER. Expected ON or OFF."
      exit 2
    fi
    ;;

  --jobs=*)
    JOBS="${input#*=}"
    ;;
  -j)
    shift
    JOBS="${1}"
    ;;
  -j*)
    JOBS="${input#*j}"
    ;;

  *)
    echo "Invalid command line option <$input>. See -h for more information."
    exit 2
    ;;

  esac
  shift
done

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
  COLOR=$1
  shift
  echo -e "${COLOR}$@\033[0m"
}

## Exit with some useful information
quit_if_fail() {
  STATUS=$?
  if [ ${STATUS} -ne 0 ]; then
    color_echo ${BAD} "Failure with exit status:" ${STATUS}
    color_echo ${BAD} "Exit message:" $1
    exit ${STATUS}
  fi
}

#############################################################
install_compilers() {
  if [ "$USE_DEFAULT_COMPILER" == "ON" ]; then
    color_echo ${GOOD} "Using spack's default compiler"
  elif spack find "$COMPILER_TYPE@$COMPILER_VERSION" >/dev/null 2>&1; then
    color_echo ${GOOD} "$COMPILER_TYPE@$COMPILER_VERSION is already installed"
  else
    color_echo ${INFO} "Installing $COMPILER_TYPE@$COMPILER_VERSION"
    spack unload --all
    spack install -j$JOBS "$COMPILER_TYPE@$COMPILER_VERSION"
    quit_if_fail "Failed to install $COMPILER_TYPE@$COMPILER_VERSION"
    spack load "$COMPILER_TYPE@$COMPILER_VERSION"
    spack compiler add
    spack unload --all
    color_echo ${GOOD} "Installed $COMPILER_TYPE@$COMPILER_VERSION"
  fi
}

spack_install_dealii() {
  COMPILER=${COMPILER_TYPE}

  # TODO: Let the user set what PRISMS-PF dependencies they would like  
  # Package list for the dealii dependencies
  packages=("caliper@$CALIPER_VERSION" "dealii@$DEAL_II_VERSION~adol-c~arborx~arpack~assimp~cuda~ginkgo~gmsh~metix~muparser~nanoflann~netcdf~oce~opencascade~petsc~scalapack~simplex~slepc~symengine~trilinos~cgal")
  if [ "$DEAL_II_WITH_CUDA" == "ON" ]; then
    color_echo ${BAD} "PRISMS-PF candi does not support spack installation with cuda"
    exit 1
  fi

  # Install the required and optional dependencies for PRISMS-PF
  echo ""
  spack unload --all
  module purge
  module list
  if [ "$USE_DEFAULT_COMPILER" != "ON" ]; then
    module load ${COMPILER}/${COMPILER_VERSION}
    quit_if_fail "Failed to load $COMPILER_TYPE@$COMPILER_VERSION"

    if [ "$COMPILER" == "intel-oneapi-compilers" ]; then
      COMPILER_TYPE="oneapi"
    elif [ "$COMPILER" == "llvm" ]; then
      COMPILER_TYPE="clang"
    fi

    # Print the spack concretization
    spack spec "${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}" > concretization.txt

    spack install -j$JOBS "${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}"
    quit_if_fail "Failed to install required packages"
    spack load ${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}
  else
    # Print the spack concretization
    spack spec "${packages[@]}" > concretization.txt
    
    spack install -j$JOBS ${packages[@]}
    quit_if_fail "Failed to install required packages"
    spack load ${packages[@]}
  fi

  spack module lmod refresh -y
  spack unload --all
  color_echo ${GOOD} "Required packages installed"
  spack gc -y
}

install_dealii() {
  mkdir tmp

}

#############################################################
# Check for various dependencies
if ! [ -x "$(command -v git)" ]; then
  color_echo ${BAD} "Make sure git is installed and in path."
  exit 1
fi
if ! [ command -v spack >/dev/null 2>&1 ] && [ USE_SPACK == "ON" ]; then
  color_echo ${BAD} "Make sure spack is installed and in path."
  exit 1
fi
if ! [ command -v module >/dev/null 2>&1 ] && [ USE_SPACK == "ON" ]; then
  color_echo ${BAD} "Make sure spack's module system has been setup and in path."
  exit 1
fi
if ! [ command -v wget >/dev/null 2>&1 ]; then
  color_echo ${BAD} "Please make sure wget is installed."
  exit 1
fi

if [ USE_SPACK == "ON" ]; then
  # TODO: If the user desires it we can install spack

  # Install compilers with spack
  install_compilers

  # Install deal.II and other dependencies with the provided compilers
  spack_install_dealii
fi

# Stop the timer
TOC_GLOBAL="$(($(${DATE_CMD} +%s) - TIC_GLOBAL))"

# Summary
echo
color_echo ${GOOD} "Build finished in $((TOC_GLOBAL)) seconds."
echo

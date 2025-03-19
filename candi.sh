#!/usr/bin/env bash

#############################################################
# Grab the date and start a global timer
if builtin command -v gdate > /dev/null; then
  DATE_CMD=$(which gdata)
else
  DATE_CMD=$(which date)
fi
TIC_GLOBAL="$(${DATE_CMD} +%s)"

#############################################################
# Parse command line inputs
JOBS=1
COMPILER_TYPE=gcc
COMPILER_VERSION=10.5.0
USE_DEFAULT_COMPILER=OFF
DEAL_II_VERSION=9.6.2
DEAL_II_WITH_CUDA=OFF
CUDA_ARCH=89

while [ -n "$1" ]; do
  input="$1"
  case $input in
    
    -h|--help)
      echo "deal.II spack packaging for PRISMS-PF"
      echo ""
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --cuda=<ON/OFF> whether to build deal.II with CUDA (default = ${DEAL_II_WITH_CUDA})"
      echo "  --cuda_arch=<number> cuda architecture (default = ${CUDA_ARCH})"
      echo "  --default=<ON/OFF> override to use default spack compiler (default = ${USE_DEFAULT_COMPILER})"
      echo "  -c=<compiler@version>, --compiler=<compiler@version>  set a different compiler and version (default = ${COMPILER_TYPE}@${COMPILER_VERSION})"
      echo "  -v <version>, -v=<version>, --version=<version>  set a different deal.II version (default = ${DEAL_II_VERSION})"
      echo "  -j <N>, -j<N>, --jobs=<N>  compile with N processes in parallel (default = ${JOBS})"
      exit 0
    ;;

    --cuda=*)
      DEAL_II_WITH_CUDA="${input#*=}"
      if [[ "$DEAL_II_WITH_CUDA" != "ON" && "$DEAL_II_WITH_CUDA" != "OFF" ]]; then
        color_echo ${BAD} "Invalid value for --cuda: $DEAL_II_WITH_CUDA. Expected ON or OFF."
        exit 2
      fi
    ;;

    --cuda_arch=*)
      CUDA_ARCH="${input#*=}"
    ;;

    --default=*)
      USE_DEFAULT_COMPILER="${input#*=}"
      if [[ "$USE_DEFAULT_COMPILER" != "ON" && "$USE_DEFAULT_COMPILER" != "OFF" ]]; then
        color_echo ${BAD} "Invalid value for --default: $USE_DEFAULT_COMPILER. Expected ON or OFF."
        exit 2
      fi
    ;;

    -c=*|--compiler=*)
      COMPILER_INPUT="${input#*=}"

      if [[ $COMPILER_INPUT =~ ^([a-zA-Z0-9_]+)@([0-9.]+)$ ]]; then
        COMPILER_TYPE="${BASH_REMATCH[1]}"
        COMPILER_VERSION="${BASH_REMATCH[2]}"
      else
        color_echo ${BAD} "Invalid compiler input: $COMPILER_INPUT. Expected format <compiler@version>."
        exit 2
      fi
    ;;

    --version=*)
      DEAL_II_VERSION="${input#*=}"
    ;;
    -v)
      shift
      DEAL_II_VERSION="${1}"
    ;;
    -v=*)
      DEAL_II_VERSION="${input#*j}"
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
  COLOR=$1; shift
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
  if [ "$USE_DEFAULT_COMPILER" == "ON" ] ; then
    color_echo ${GOOD} "Using spack's default compiler"
  elif spack find "$COMPILER_TYPE@$COMPILER_VERSION" > /dev/null 2>&1; then
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

install_dealii() {
  COMPILER=${COMPILER_TYPE}

  # TODO: Let the user set what dealii packages to install in some config file
  # Package list for the dealii dependencies
  packages=("cmake@3.31.6" "p4est@2.8" "sundials@7.2.1" "openblas@0.3.29" "caliper@2.12.1" "openmpi@5.0.6")
  if [ "$DEAL_II_WITH_CUDA" == "ON" ] ; then
    color_echo ${BAD} "CUDA not implemented"
    exit 1
    packages+=("")
  fi

  # Install the required and optional dependencies for PRISMS-PF
  echo ""
  spack unload --all
  module purge
  module list
  if [ "$USE_DEFAULT_COMPILER" != "ON" ] ; then
    module load ${COMPILER}/${COMPILER_VERSION}
    quit_if_fail "Failed to load $COMPILER_TYPE@$COMPILER_VERSION"

    if [ "$COMPILER" == "intel-oneapi-compilers" ] ; then
      COMPILER_TYPE="oneapi"
    elif [ "$COMPILER" == "llvm" ]; then
      COMPILER_TYPE="clang"
    fi

    spack install -j$JOBS ${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}
    quit_if_fail "Failed to install required packages"
    spack load ${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}
  else
    spack install -j$JOBS ${packages[@]}
    quit_if_fail "Failed to install required packages"
    spack load ${packages[@]}
  fi

  spack module lmod refresh -y
  spack unload --all
  color_echo ${GOOD} "Required packages installed"
  spack gc -y
  
  # Load the dependencies and compile deal.II
  module purge
  module load ${COMPILER}/${COMPILER_VERSION}
  module load cmake/3.31.6-${COMPILER}-${COMPILER_VERSION}
  module load p4est/2.8-${COMPILER}-${COMPILER_VERSION}
  module load sundials/7.2.1-${COMPILER}-${COMPILER_VERSION}
  module load openblas/0.3.29-${COMPILER}-${COMPILER_VERSION}
  module load openmpi/5.0.6-${COMPILER}-${COMPILER_VERSION}

  if [ ! -d "dealii" ]; then
    git clone https://github.com/dealii/dealii.git
    quit_if_fail "Failed to clone dealii"
  fi

  cd dealii
  git checkout tags/v${DEAL_II_VERSION}
  quit_if_fail "Invalid deal.II version number"
  cd ..

  

}
#############################################################
# Check for various dependencies
if ! [ -x "$(command -v git)" ]; then
  color_echo ${BAD} "Make sure git is installed and in path."
  exit 1
fi
if ! command -v spack > /dev/null 2>&1; then
  color_echo ${BAD} "Make sure spack is installed and in path."
  exit 1
fi

# Install compilers with spack
install_compilers

# Install deal.II and other dependencies with the provided compilers
install_dealii

# Stop the timer
TOC_GLOBAL="$(($(${DATE_CMD} +%s)-TIC_GLOBAL))"

# Summary
echo
color_echo ${GOOD} "Build finished in $((TOC_GLOBAL)) seconds."
echo

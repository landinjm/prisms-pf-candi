#!/usr/bin/env bash

#############################################################
# Required packages
PACKAGES="openblas openmpi p4est kokkos zlib"

#############################################################
# Grab the date and start a global timer
if builtin command -v gdate >/dev/null; then
  DATE_CMD=$(which gdata)
else
  DATE_CMD=$(which date)
fi
TIC_GLOBAL="$(${DATE_CMD} +%s)"

#############################################################
# Various niceties that make the script look pretty

# Colors
BAD="\033[1;31m"
GOOD="\033[1;32m"
WARN="\033[1;35m"
INFO="\033[1;34m"
BOLD="\033[1m"

# Color echo
color_echo() {
  COLOR=$1
  shift
  echo -e "${COLOR}$@\033[0m"
}

# Exit with some useful information
quit_if_fail() {
  STATUS=$?
  if [ ${STATUS} -ne 0 ]; then
    color_echo ${BAD} "Failure with exit status:" ${STATUS}
    color_echo ${BAD} "Exit message:" $1
    exit ${STATUS}
  fi
}

#############################################################
# Grab the cfg file
if [ -f "candi.cfg" ]; then
  source candi.cfg
else
  color_echo ${BAD} "No configuration file found. Please create a candi.cfg file."
  exit 1
fi

# A few checks on the cfg file
check_config_value() {
  local var_name=$1
  local var_value=$2
  if [[ "$var_value" != "ON" && "$var_value" != "OFF" ]]; then
    color_echo ${BAD} "Invalid value for $var_name=$var_value. Expected ON or OFF."
    exit 1
  fi
}

version_greater_equal() {
  local version=$1
  local base_version=$2

  # Split the versions into arrays
  IFS='.' read -r -a version_parts <<<"$version"
  IFS='.' read -r -a base_version_parts <<<"$base_version"

  # Compare each part of the version
  for ((i = 0; i < ${#base_version_parts[@]}; i++)); do
    if [[ ${version_parts[i]:-0} -gt ${base_version_parts[i]} ]]; then
      return 0
    elif [[ ${version_parts[i]:-0} -lt ${base_version_parts[i]} ]]; then
      return 1
    fi
  done

  return 0
}

check_config_value "USE_SPACK" "$USE_SPACK"
check_config_value "NATIVE_OPTIMIZATIONS" "$NATIVE_OPTIMIZATIONS"
check_config_value "USE_64BIT_INDICES" "$USE_64BIT_INDICES"
check_config_value "DEAL_II_WITH_CUDA" "$DEAL_II_WITH_CUDA"

if ! version_greater_equal "$DEAL_II_VERSION" "9.6"; then
  color_echo ${BAD} "Invalid value for DEAL_II_VERSION=$DEAL_II_VERSION. Expected version greater than 9.6"
  exit 1
fi

#############################################################
# Parse command line inputs
PREFIX=~/prisms-pf-candi
JOBS=1
USE_DEFAULT_COMPILER=ON

while [ -n "$1" ]; do
  input="$1"
  case $input in

  -h | --help)
    echo "deal.II spack packaging for PRISMS-PF"
    echo ""
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -p <path>, --prefix=<path> set a different prefix path (default = $PREFIX)"
    echo "  --default=<ON/OFF> override to use default spack compiler (default = ${USE_DEFAULT_COMPILER})"
    echo "  -j <N>, -j<N>, --jobs=<N> compile with N processes in parallel (default = ${JOBS})"
    exit 0
    ;;

  -p)
    shift
    PREFIX="${1}"
    ;;
  -p=* | --prefix=*)
    PREFIX="${param#*=}"
    ;;

  --default=*)
    USE_DEFAULT_COMPILER="${input#*=}"
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

# Replace the ~ with the home directory
PREFIX_PATH=${PREFIX/#~\//$HOME\/}
unset PREFIX

# Set other paths
BUILD_PATH=${PREFIX_PATH}/tmp/build
INSTALL_PATH=${PREFIX_PATH}

# Check that inputs are valids
check_config_value "--default" "$USE_DEFAULT_COMPILER"
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  color_echo ${BAD} "Invalid value for --jobs: $JOBS. Expected a positive number."
  exit 1
fi

#############################################################
# Check for various dependencies
if ! [ -x "$(command -v git)" ]; then
  color_echo ${BAD} "Make sure git is installed and in path."
  exit 1
fi
if ! command -v spack >/dev/null 2>&1 && [ $USE_SPACK == "ON" ]; then
  color_echo ${BAD} "Make sure spack is installed and in path."
  exit 1
fi
if ! command -v module >/dev/null 2>&1 && [ $USE_SPACK == "ON" ]; then
  color_echo ${BAD} "Make sure spack's module system has been setup and in path."
  exit 1
fi
if ! command -v wget >/dev/null 2>&1 && [ $USE_SPACK != "ON" ]; then
  color_echo ${BAD} "Please make sure wget is installed."
  exit 1
fi

#############################################################
# Spack installation functions
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

  # Package list for the dealii dependencies
  packages=("dealii@$DEAL_II_VERSION~adol-c~arborx~arpack~assimp~cuda~ginkgo~gmsh~hdf5~metis~muparser~nanoflann~netcdf~oce~opencascade~petsc~scalapack~simplex~slepc~symengine~trilinos~cgal")
  if [ "$DEAL_II_WITH_CUDA" == "ON" ]; then
    color_echo ${BAD} "PRISMS-PF candi does not support spack installation with cuda"
    exit 1
  fi
  if [[ " ${PACKAGES[@]} " =~ " gsl " ]]; then
    packages=("${packages[@]}+gsl")
  fi
  if [[ " ${PACKAGES[@]} " =~ " sundials " ]]; then
    packages=("${packages[@]}+sundials")
  fi
  if [ $USE_64BIT_INDICES == "ON" ]; then
    packages=("${packages[@]}+int64")
  fi
  if [ $NATIVE_OPTIMIZATIONS == "ON" ]; then
    packages=("${packages[@]}+optflags")
  fi
  if [[ " ${PACKAGES[@]} " =~ " caliper " ]]; then
    packages=("${packages[@]}" "caliper")
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
    spack spec "${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}" >concretization.txt

    spack install -j$JOBS "${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}"
    quit_if_fail "Failed to install required packages"
    spack load ${packages[@]/%/%${COMPILER_TYPE}@${COMPILER_VERSION}}
  else
    # Print the spack concretization
    spack spec "${packages[@]}" >concretization.txt

    spack install -j$JOBS ${packages[@]}
    quit_if_fail "Failed to install required packages"
    spack load ${packages[@]}
  fi

  spack module lmod refresh -y
  spack unload --all
  color_echo ${GOOD} "Required packages installed"
}

#############################################################
# Source installation functions
check_compilers() {
  # C
  if [ ! -n "${CC}" ]; then
    if builtin command -v mpicc >/dev/null; then
      color_echo ${WARN} "CC variable not set, but found mpicc."
      export CC=mpicc
    fi
  fi
  if [ -n "${CC}" ]; then
    color_echo ${INFO} "CC = $(which ${CC})"
  else
    color_echo ${BAD} "CC variable not set. Please set it with "export CC = <(MPI) C compiler >""
    exit 1
  fi

  # C++
  if [ ! -n "${CXX}" ]; then
    if builtin command -v mpicxx >/dev/null; then
      color_echo ${WARN} "CXX variable not set, but found mpicxx."
      export CXX=mpicxx
    fi
  fi
  if [ -n "${CXX}" ]; then
    color_echo ${INFO} "CXX = $(which ${CXX})"
  else
    color_echo ${BAD} "CXX variable not set. Please set it with "export CXX = <(MPI) CXX compiler >""
    exit 1
  fi

  # F90
  if [ ! -n "${FC}" ]; then
    if builtin command -v mpif90 >/dev/null; then
      color_echo ${WARN} "FC variable not set, but found mpif90."
      export FC=mpif90
    fi
  fi
  if [ -n "${FC}" ]; then
    color_echo ${INFO} "FC = $(which ${FC})"
  else
    color_echo ${BAD} "FC variable not set. Please set it with "export FC = <(MPI) F90 compiler >""
    exit 1
  fi

  # F77
  if [ ! -n "${FF}" ]; then
    if builtin command -v mpif77 >/dev/null; then
      color_echo ${WARN} "CXX variable not set, but found mpicxx."
      export FF=mpicxx
    fi
  fi
  if [ -n "${FF}" ]; then
    color_echo ${INFO} "FF = $(which ${FF})"
  else
    color_echo ${BAD} "FF variable not set. Please set it with "export FF = <(MPI) F77 compiler >""
    exit 1
  fi

  echo
}

sort_packages() {
  # Sort the packages so that cuda, kokkos, and openmpi are the first three packages installed
  SORTED_PACKAGES=()

  # Add cuda and openmpi to the sorted list if they are in the original list
  for PACKAGE in "cuda" "kokkos" "openmpi"; do
    if [[ " ${PACKAGES[@]} " =~ " ${PACKAGE} " ]]; then
      SORTED_PACKAGES+=("${PACKAGE}")
    fi
  done

  # Add the remaining packages to the sorted list
  for PACKAGE in ${PACKAGES[@]}; do
    if [[ ! " ${SORTED_PACKAGES[@]} " =~ " ${PACKAGE} " ]]; then
      SORTED_PACKAGES+=("${PACKAGE}")
    fi
  done

  # Update the PACKAGES variable with the sorted list
  PACKAGES=("${SORTED_PACKAGES[@]}")
}

install_dealii() {
  check_compilers

  # Create the directories
  mkdir -p ${INSTALL_PATH}
  mkdir -p ${PREFIX_PATH}/tmp
  mkdir -p ${BUILD_PATH}

  # Variables that contain the original directories
  ORIGINAL_INSTALL_PATH=${INSTALL_PATH}
  ORIGINAL_BUILD_PATH=${BUILD_PATH}
  ORIGINAL_DIR=$(pwd)

  # If cuda is enabled, we need to install cuda too
  if [ "$DEAL_II_WITH_CUDA" == "ON" ]; then
    PACKAGES="${PACKAGES} cuda"
  fi
  sort_packages

  for PACKAGE in ${PACKAGES[@]}; do
    # Check if the package file exists
    if [ ! -e packages/${PACKAGE}.package ]; then
      color_echo ${BAD} "Package file ${PACKAGE}.package not found."
      exit 1
    fi

    # Reset variables that are used in the package file
    unset VERSION
    unset NAME
    unset PACKING
    unset SOURCE
    unset EXTRACT_TO
    unset BUILD_DIR
    unset INSTALL_PATH
    INSTALL_PATH=${ORIGINAL_INSTALL_PATH}

    # Reset the install function
    install() {
      color_echo ${BAD} "Install function not defined for ${PACKAGE}"
      exit 1
    }

    # Source the package file
    source packages/${PACKAGE}.package

    # Install
    install
    quit_if_fail "Failed to install ${PACKAGE}"
    color_echo ${GOOD} "Installed ${PACKAGE}"

    # Go back to the original directory
    cd ${ORIGINAL_DIR}
  done
}

#############################################################
# Start the build process

if [ $USE_SPACK == "ON" ]; then
  # TODO: If the user desires it we can install spack

  # Install compilers with spack
  install_compilers

  # Install deal.II and other dependencies with the provided compilers
  spack_install_dealii
else
  # Install deal.II and other dependencies
  install_dealii
fi

# Stop the timer
TOC_GLOBAL="$(($(${DATE_CMD} +%s) - TIC_GLOBAL))"

# Summary
echo
color_echo ${GOOD} "Build finished in $((TOC_GLOBAL)) seconds."
echo

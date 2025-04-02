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

check_config_value "USE_FULL_SPACK" "$USE_FULL_SPACK"
check_config_value "USE_PARTIAL_SPACK" "$USE_PARTIAL_SPACK"
check_config_value "NATIVE_OPTIMIZATIONS" "$NATIVE_OPTIMIZATIONS"
check_config_value "USE_64BIT_INDICES" "$USE_64BIT_INDICES"
check_config_value "DEAL_II_WITH_CUDA" "$DEAL_II_WITH_CUDA"

if ! version_greater_equal "$DEAL_II_VERSION" "9.6"; then
  color_echo ${BAD} "Invalid value for DEAL_II_VERSION=$DEAL_II_VERSION. Expected version greater than 9.6"
  exit 1
fi

if [ "$USE_FULL_SPACK" == "ON" ] && [ "$USE_PARTIAL_SPACK" == "ON" ]; then
  color_echo ${BAD} "USE_FULL_SPACK and USE_PARTIAL_SPACK cannot both be ON"
  exit 1
elif [ "$USE_FULL_SPACK" == "ON" ] || [ "$USE_PARTIAL_SPACK" == "ON" ]; then
  USING_SPACK="ON"
else
  USING_SPACK="OFF"
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
SRC_PATH=${PREFIX_PATH}/tmp/src
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
if ! command -v spack >/dev/null 2>&1 && [ $USING_SPACK == "ON" ]; then
  color_echo ${BAD} "Make sure spack is installed and in path."
  exit 1
fi
if ! command -v module >/dev/null 2>&1 && [ $USING_SPACK == "ON" ]; then
  color_echo ${BAD} "Make sure spack's module system has been setup and in path."
  exit 1
fi
if ! command -v wget >/dev/null 2>&1 && [ $USING_SPACK != "ON" ]; then
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

  if [ "$DEAL_II_WITH_CUDA" == "ON" ]; then
    color_echo ${BAD} "PRISMS-PF candi does not support spack installation with cuda"
    exit 1
  fi

  # Package list for the dealii dependencies
  if [ $USE_FULL_SPACK == "ON" ]; then
    packages=("dealii@$DEAL_II_VERSION~adol-c~arborx~arpack~assimp~cuda~ginkgo~gmsh~hdf5~metis~muparser~nanoflann~netcdf~oce~opencascade~petsc~scalapack~simplex~slepc~symengine~trilinos~cgal")
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
  else
    packages=$PACKAGES
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

  if [ $USE_PARTIAL_SPACK == "ON" ]; then
    if [ ! -d "$SRC_PATH/dealii-v$DEAL_II_VERSION" ]; then
      git clone https://github.com/dealii/dealii.git $SRC_PATH/dealii-v$DEAL_II_VERSION
      quit_if_fail "Failed to clone dealii"
    fi
    cd $SRC_PATH/dealii-v$DEAL_II_VERSION
    git checkout tags/v$DEAL_II_VERSION
    quit_if_fail "Invalid version number"

    if [ "$USE_DEFAULT_COMPILER" != "ON" ]; then
      DEAL_II_BUILD_DIR=$BUILD_PATH/dealii-v$DEAL_II_VERSION-$COMPILER_TYPE-v$COMPILER_VERSION
      DEAL_II_INSTALL_DIR=$INSTALL_PATH/dealii-v$DEAL_II_VERSION-$COMPILER_TYPE-v$COMPILER_VERSION
      DEAL_II_MODULE_NAME="$INSTALL_PATH/modules/dealii-v$DEAL_II_VERSION-$COMPILER_TYPE-v$COMPILER_VERSION.lua"

      OPENBLAS_DIR=$(spack location -i $(spack find -H openblas%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      MPI_DIR=$(spack location -i $(spack find -H openmpi%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      P4EST_DIR=$(spack location -i $(spack find -H p4est%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      KOKKOS_DIR=$(spack location -i $(spack find -H kokkos%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      ZLIB_DIR=$(spack location -i $(spack find -H zlib%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      if [[ " ${PACKAGES[@]} " =~ " gsl " ]]; then
        GSL_DIR=$(spack location -i $(spack find -H gsl%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      fi
      if [[ " ${PACKAGES[@]} " =~ " sundials " ]]; then
        SUNDIALS_DIR=$(spack location -i $(spack find -H sundials%${COMPILER_TYPE}@${COMPILER_VERSION} | head -n 1))
      fi
    else
      DEAL_II_BUILD_DIR=$BUILD_PATH/dealii-v$DEAL_II_VERSION
      DEAL_II_INSTALL_DIR=$INSTALL_PATH/dealii-v$DEAL_II_VERSION
      DEAL_II_MODULE_NAME="$INSTALL_PATH/modules/dealii-v$DEAL_II_VERSION.lua"

      OPENBLAS_DIR=$(spack location -i $(spack find -H openblas | head -n 1))
      MPI_DIR=$(spack location -i $(spack find -H openmpi | head -n 1))
      P4EST_DIR=$(spack location -i $(spack find -H p4est | head -n 1))
      KOKKOS_DIR=$(spack location -i $(spack find -H kokkos | head -n 1))
      ZLIB_DIR=$(spack location -i $(spack find -H zlib | head -n 1))
      if [[ " ${PACKAGES[@]} " =~ " gsl " ]]; then
        GSL_DIR=$(spack location -i $(spack find -H gsl | head -n 1))
      fi
      if [[ " ${PACKAGES[@]} " =~ " sundials " ]]; then
        SUNDIALS_DIR=$(spack location -i $(spack find -H sundials | head -n 1))
      fi
    fi

    if [ ! -d "$DEAL_II_BUILD_DIR" ]; then
      mkdir $DEAL_II_BUILD_DIR
    fi
    cd $DEAL_II_BUILD_DIR
    cmake_cmd="cmake \
    -D CMAKE_C_COMPILER=mpicc \
    -D CMAKE_CXX_COMPILER=mpicxx \
    -D CMAKE_INSTALL_PREFIX=$DEAL_II_INSTALL_DIR \
    -D DEAL_II_FORCE_BUNDLED_TBB=ON \
    -D DEAL_II_WITH_LAPACK=ON \
    -D LAPACK_DIR=$OPENBLAS_DIR \
    -D DEAL_II_WITH_MPI=ON \
    -D MPI_DIR=$MPI_DIR \
    -D DEAL_II_WITH_P4EST=ON \
    -D P4EST_DIR=$P4EST_DIR \
    -D DEAL_II_WITH_KOKKOS=ON \
    -D KOKKOS_DIR=$KOKKOS_DIR \
    -D DEAL_II_WITH_ZLIB=ON \
    -D ZLIB_DIR=$ZLIB_DIR"
    if [[ " ${PACKAGES[@]} " =~ " gsl " ]]; then
      cmake_cmd+="-D DEAL_II_WITH_GSL=ON -D GSL_DIR=$GSL_DIR"
    fi
    if [[ " ${PACKAGES[@]} " =~ " sundials " ]]; then
      cmake_cmd+="-D DEAL_II_WITH_SUNDIALS=ON -D SUNDIALS_DIR=$SUNDIALS_DIR"
    fi
    if [ $USE_64BIT_INDICES == "ON" ]; then
      cmake_cmd+="-D DEAL_II_WITH_64BIT_INDICES=ON"
    fi
    if [ $NATIVE_OPTIMIZATIONS == "ON" ]; then
      cmake_cmd+="-D DEAL_II_CXX_FLAGS=\"-march=native\""
    fi

    cmake_cmd+=" $SRC_PATH/dealii-v$DEAL_II_VERSION"
    eval $cmake_cmd
    quit_if_fail "Invalid cmake configuration"
    make -j$JOBS
    quit_if_fail "Failed to compile with $(make)"
    make -j$JOBS install
    quit_if_fail "Failed to compile with $(make install)"
    color_echo ${GOOD} "deal.II v${DEAL_II_VERSION} installed"

    if [ ! -d "$INSTALL_PATH/modules" ]; then
      mkdir "$INSTALL_PATH/modules"
    fi
    if [ "$USE_DEFAULT_COMPILER" != "ON" ]; then
      CMAKE_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" cmake | head -n 1)
      OPENBLAS_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" openblas | head -n 1)
      MPI_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" openmpi | head -n 1)
      P4EST_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" p4est | head -n 1)
      KOKKOS_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" kokkos | head -n 1)
      ZLIB_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" zlib | head -n 1)
      if [[ " ${PACKAGES[@]} " =~ " gsl " ]]; then
        GSL_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" gsl | head -n 1)
      fi
      if [[ " ${PACKAGES[@]} " =~ " sundials " ]]; then
        SUNDIALS_MODULE=$(spack find --format "{name}/{version}-${COMPILER_TYPE}-${COMPILER_VERSION}" sundials | head -n 1)
      fi

      cat <<EOF >$DEAL_II_MODULE_NAME
  -- Module for deal.II v$DEAL_II_VERSION

  -- Set the root path for the module
  local root = "$DEAL_II_INSTALL_DIR"

  -- Load dependencies
  if not (isloaded("${COMPILER}/${COMPILER_VERSION}")) then
      load("${COMPILER}/${COMPILER_VERSION}")
  end
  if not (isloaded("$CMAKE_MODULE")) then
      load("$CMAKE_MODULE")
  end
  if not (isloaded("$OPENBLAS_MODULE")) then
      load("$OPENBLAS_MODULE")
  end
  if not (isloaded("$P4EST_MODULE")) then
      load("$P4EST_MODULE")
  end
  if not (isloaded("$KOKKOS_MODULE")) then
      load("$KOKKOS_MODULE")
  end
  if not (isloaded("$ZLIB_MODULE")) then
      load("$ZLIB_MODULE")
  end
EOF

      if [[ " ${PACKAGES[@]} " =~ " gsl " ]]; then
        cat <<EOF >>$DEAL_II_MODULE_NAME
  if not (isloaded("$GSL_MODULE")) then
      load("$GSL_MODULE")
  end
EOF
      fi
      if [[ " ${PACKAGES[@]} " =~ " sundials " ]]; then
        cat <<EOF >>$DEAL_II_MODULE_NAME
  if not (isloaded("$SUNDIALS_MODULE")) then
      load("$SUNDIALS_MODULE")
  end
EOF
      fi

      cat <<EOF >>$DEAL_II_MODULE_NAME
  if not (isloaded("$MPI_MODULE")) then
      load("$MPI_MODULE")
  end
    
  -- Set the environment variables
  prepend_path("PATH", root.."/bin")
  prepend_path("LD_LIBRARY_PATH", root.."/lib")
  prepend_path("CMAKE_PREFIX_PATH", root)

  -- Module load instructions
  whatis("Name: deal.II")
  whatis("Version: $DEAL_II_VERSION")
  whatis("Description: deal.II is a C++ library for finite element methods.")
EOF

      color_echo ${INFO} "Module file for deal.II v$DEAL_II_VERSION created at $DEAL_II_MODULE_NAME"
    fi
  else
    color_echo ${WARN} "deal.II custom module with default compiler has not been implemented."
  fi

  spack module lmod refresh -y
  spack unload --all
  color_echo ${GOOD} "Required packages installed"

  if [ "$USE_DEFAULT_COMPILER" != "ON" ]; then
    color_echo ${WARN} "
The module file has been created, but may not be added to your path. 
Try adding the following to your environment:
"
    color_echo ${INFO} "export MODULEPATH=\$MODULEPATH:$INSTALL_PATH/modules"
  fi
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

if [ $USING_SPACK == "ON" ]; then
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

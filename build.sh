#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  RENE-daq-rcterm build script
#  Rocky Linux 9 / GCC 11 / CMake 3.16+ / CERN ROOT
#
#  usage :  ./build.sh [INSTALL_PREFIX]
#           default prefix = <repo>/install
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v root-config >/dev/null 2>&1; then
  echo "ERROR: root-config not found." >&2
  echo "       source /path/to/root/bin/thisroot.sh   (or: module load root)" >&2
  exit 1
fi

echo "ROOT   : $(root-config --version)   prefix=$(root-config --prefix)"
echo "GCC    : $(gcc -dumpversion)"
echo "CMake  : $(cmake --version | head -1)"
if command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3: $(sqlite3 --version | awk '{print $1}')"
else
  echo "sqlite3: NOT FOUND  ->  sudo dnf install -y sqlite"
  echo "         (or run rcterm with --no-db --run <N>)"
fi

PREFIX="${1:-$PWD/install}"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build build -j"$(nproc)"
cmake --install build

echo
echo "------------------------------------------------------------"
echo " built     : $PWD/build/rcterm , $PWD/build/rcsupervisor"
echo " installed : $PREFIX/bin/"
echo "------------------------------------------------------------"
echo " next :"
echo "   cp config/rcterm.params.example       config/rcterm.params"
echo "   cp config/rcsupervisor.params.example config/rcsupervisor.params"
echo "   vi config/rcterm.params"
echo "   $PREFIX/bin/rcterm --params config/rcterm.params --dry-run"

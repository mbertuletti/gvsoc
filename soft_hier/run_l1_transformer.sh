#!/usr/bin/env bash
# l1_transformer on gvsoc: single cluster (tensorpool model) or multi cluster
# (flex_cluster model).
# Usage: [options] ./run_l1_transformer.sh single|multi
#   DEFINES="-DPIPELINED -DTILESHIFT -DREPLICATE_F"  app variant
#   BEAM=128 EMBED=32 TDSAMPLES=32                   shapes
#   NUM_CORES=512 (single) / 256 (multi)             cores per cluster
#   N_CLUSTERS=8                                     multi: clusters used
#   MEMPOOL_DIR=/scratch/mbertuletti/mempool         MemPool software tree
#   BUILD_GVSOC=1                                    rebuild the gvsoc model
#
# Multi cluster: the mesh, cluster and RedMulE parameters come from the gvsoc
# arch file (HW_CFG), which takes the cores per cluster from num_cores. The
# software generates mc_cluster_arch.h and its L1 bank size from the same
# file (MC_ARCH_CONFIG): a mismatch hangs the run right after "DONE: Start".

MODE=$1
case "$MODE" in
single | multi) ;;
*)
  echo "usage: $0 single|multi" >&2
  exit 1
  ;;
esac

SOFTHIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SOFTHIER_DIR/.."
MEMPOOL_DIR=${MEMPOOL_DIR:-/scratch/mbertuletti/mempool}
DEFINES="${DEFINES--DPIPELINED -DTILESHIFT -DREPLICATE_F}"
DEFINES+=" -DBEAM=${BEAM:-128} -DEMBED=${EMBED:-32} -DTDSAMPLES=${TDSAMPLES:-32}"
SHAPE="${BEAM:-128}_${EMBED:-32}_${TDSAMPLES:-32}"
HW_CFG="$ROOT_DIR/pulp/pulp/chips/flex_cluster/configs/arch_tensorpool.py"

if [ "$MODE" = single ]; then
  NUM_CORES=${NUM_CORES:-512}
  APP=l1_transformer_f16
  APP_DIR="$MEMPOOL_DIR/software/apps/nn"
  ELF="$MEMPOOL_DIR/software/bin/nn/$APP"
  TARGET=tensorpool
  LOG="$SOFTHIER_DIR/results/run_$APP/${NUM_CORES}pe_$SHAPE.log"
  MAKE_ARGS=(nn/$APP -C "$MEMPOOL_DIR/software/apps")
  MAKE_ENV=(
  	num_cores=$NUM_CORES 
  	num_redmule_tiles=16 
  	redmule_height=8
    redmule_width=32 
    redmule_regs=3)

  # The single-cluster model size is selected through the environment
  export TENSORPOOL_NUM_CORES=$NUM_CORES
  export TENSORPOOL_REDMULE_TILES=$((NUM_CORES / 16))
  export REDMULE_HEIGHT=8 REDMULE_WIDTH=32 REDMULE_REGS=3

else
  N_CLUSTERS=${N_CLUSTERS:-8}
  # Cores per cluster: the arch file (HW_CFG) reads num_cores from the
  # environment, both in gvsoc and in the software build
  export num_cores=${NUM_CORES:-256}
  DEFINES+=" -DN_CLUSTERS=$N_CLUSTERS"
  APP=l1_transformer_mc_f16
  APP_DIR="$MEMPOOL_DIR/software/apps/multi_cluster"
  ELF="$MEMPOOL_DIR/software/bin/multi_cluster/$APP"
  TARGET=pulp.chips.flex_cluster.flex_cluster
  LOG="$SOFTHIER_DIR/results/run_$APP/${N_CLUSTERS}c_${num_cores}pe_$SHAPE.log"
  MAKE_ARGS=($APP -C "$APP_DIR" MC_ARCH_CONFIG="$HW_CFG")

  MAKE_ENV=()
  rm -f "$MEMPOOL_DIR/software/runtime/multi_cluster/include/mc_cluster_arch.h"
  read -r REDMULE_HEIGHT REDMULE_WIDTH REDMULE_REGS <<<         \
  "$(python3 -c 											    \
    "import sys; sys.path.insert(0, '$(dirname "$HW_CFG")');    \
	 from arch_tensorpool import FlexClusterArch as A; a = A(); \
     print(a.redmule_height, a.redmule_width, a.redmule_regs)")"
  export REDMULE_HEIGHT REDMULE_WIDTH REDMULE_REGS
  
fi

cd "$ROOT_DIR"
source sourceme.sh
source sourceme_systemc.sh

# Compile the gvsoc model (first run, or after model changes)
if [ "${BUILD_GVSOC:-0}" = 1 ]; then
  rm -f build/core/gen_pulp_chips_flex_cluster_*.so
  CCACHE_DISABLE=1 make TARGETS=$TARGET build || exit 1
fi

# Compile the software. The defines are not make dependencies: remove the
# object and the binary to force a rebuild.
rm -f "$APP_DIR/$APP/main.c.o" "$ELF"
env DEFINES="$DEFINES" config=tensorpool COMPILER=llvm "${MAKE_ENV[@]}" \
  make "${MAKE_ARGS[@]}" || exit 1

# Run the simulation (line-buffered so the DONE markers show up live)
mkdir -p "$(dirname "$LOG")"
stdbuf -oL -eL ./install/bin/gvsoc --target=$TARGET --binary="$ELF" run 2>&1 |
  tee "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "gvsoc failed (rc=$rc)"; exit "$rc"; }

python3 "$SOFTHIER_DIR/flex_cluster_utilities/bench_region_stats.py" "$LOG" \
  --csv "${LOG%.log}.csv"

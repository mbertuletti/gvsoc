#!/usr/bin/env bash
# l1_transformer on gvsoc: single cluster (tensorpool model) or multi cluster
# (flex_cluster model).
#
# Usage: [options] ./run_l1_transformer.sh single|multi
#	DEFINES="-DPIPELINED -DTILESHIFT -DREPLICATE_F"  app variant
#	BEAM=128 EMBED=32 TDSAMPLES=32                   shapes
#
#	NUM_CORES=512                                    cores per cluster
#	N_CLUSTERS=8                                     clusters
#	TENSOR_ENGINE=opope/redmule                      TE type used
#	NUM_TE_TILES=16                                  TE engines per cluster
#	HEIGHT=8 WIDTH=32                                TE array shape
#
#	TE_QUEUE_DEPTH									 Depth TE's outst.-queue
#	L1_BANK_HOLD                                     Hold time of banks
#
#	MEMPOOL_DIR=/scratch/mbertuletti/mempool         MemPool software tree
#	BUILD_GVSOC=1                                    rebuild the gvsoc model
#	GVSOC_ARGS="--trace=..."                         extra gvsoc arguments

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
HW_CFG="$ROOT_DIR/pulp/pulp/chips/flex_cluster/configs/arch_tensorpool.py"

DEFINES="${DEFINES--DPIPELINED -DTILESHIFT -DREPLICATE_F}"
DEFINES+=" -DBEAM=${BEAM:-128} -DEMBED=${EMBED:-32} -DTDSAMPLES=${TDSAMPLES:-32}"
SHAPE="${BEAM:-128}_${EMBED:-32}_${TDSAMPLES:-32}"

NUM_CLUSTERS=${NUM_CLUSTERS:-8}
NUM_CORES=${NUM_CORES:-512}

NUM_TE_TILES=${NUM_TE_TILES:-16}
HEIGHT=${HEIGHT:-8}
WIDTH=${WIDTH:-32}

# The script passes the sizes to the two places that need them:
#
# 	The MemPool software build, as make variables (`num_cores`,
#  	`num_redmule_tiles`, ...: `NUM_CORES`, `NUM_REDMULE_TILES` defines and the
#	core-to-RedMulE mapping of `mempool_get_redmule_id()`);
#
#	The gvsoc models, as environment variables, read by 
#   `pulp/pulp/mempool/mempool_system.py`, `redmule_configurations.py`
#	and by `pulp/pulp/chips/flex_cluster/configs/arch_tensorpool.py`

# For MemPool software builds
MAKE_ENV=(
	num_cores=$NUM_CORES 
	num_redmule_tiles=$NUM_TE_TILES 
	redmule_height=$HEIGHT 
	redmule_width=$WIDTH 
	redmule_regs=3)

# For GVSoC builds
export NUM_CORES=$NUM_CORES
export NUM_REDMULE_TILES=$NUM_TE_TILES
export REDMULE_HEIGHT=$HEIGHT 
export REDMULE_WIDTH=$WIDTH 
export REDMULE_REGS=3
export OPOPE_P=$HEIGHT

if [ "$MODE" = single ]; then

  APP=l1_transformer_f16
  APP_DIR="$MEMPOOL_DIR/software/apps/nn"
  ELF="$MEMPOOL_DIR/software/bin/nn/$APP"
  TARGET=tensorpool
  LOG="$SOFTHIER_DIR/results/run_$APP/${TENSOR_ENGINE:-redmule}_${NUM_CORES}pe_${NUM_TE_TILES}rm_${HEIGHT}x${WIDTH}_$SHAPE.log"
  MAKE_ARGS=(nn/$APP -C "$MEMPOOL_DIR/software/apps")

else
  
  DEFINES+=" -DN_CLUSTERS=$NUM_CLUSTERS"
  APP=l1_transformer_mc_f16
  APP_DIR="$MEMPOOL_DIR/software/apps/multi_cluster"
  ELF="$MEMPOOL_DIR/software/bin/multi_cluster/$APP"
  TARGET=pulp.chips.flex_cluster.flex_cluster
  LOG="$SOFTHIER_DIR/results/run_$APP/${TENSOR_ENGINE:-redmule}_${NUM_CLUSTERS}c_${NUM_CORES}pe_${NUM_TE_TILES}rm_${HEIGHT}x${WIDTH}_${SHAPE}.log"
  MAKE_ARGS=($APP -C "$APP_DIR" MC_ARCH_CONFIG="$HW_CFG")
  rm -f "$MEMPOOL_DIR/software/runtime/multi_cluster/include/mc_cluster_arch.h"
  
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
stdbuf -oL -eL ./install/bin/gvsoc --target=$TARGET --binary="$ELF" $GVSOC_ARGS run 2>&1 |
  tee "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "gvsoc failed (rc=$rc)"; exit "$rc"; }

python3 "$SOFTHIER_DIR/flex_cluster_utilities/bench_region_stats.py" "$LOG" \
  --csv "${LOG%.log}.csv"

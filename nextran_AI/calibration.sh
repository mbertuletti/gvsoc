#!/usr/bin/env bash
# Calibration of the gvsoc tensor-engine timing against the MemPool RTL, for
# the configuration of config.mk. Run it with: make calibrate
#
# For every size, builds baremetal/gemm_f16 (DEFINES from the Makefile) and runs
# it on the RTL. Then, for every point of the grid DEPTHS x HOLDS x FIRST_JOBS,
# rebuilds the gvsoc model, runs the same binaries and compares the "TIME:"
# cycles. Results are appended to rtl.csv and gvsoc.csv: the sizes and grid
# points already there are not run again.

set -uo pipefail
unset MAKEFLAGS MAKELEVEL

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP=$MEMPOOL_DIR
OUT=$DIR/results/calibration/${TENSOR_ENGINE}_${NUM_CORES}pe_${NUM_REDMULE_TILES}te_${REDMULE_HEIGHT}x${REDMULE_WIDTH}

# Sizes: batch, M, N, P
BATCH=(64 64 64 64 32 32 128 128 128 128 32 32 32 32 32 32 64 64 64 64)
M=(32 32 32 32 64 64 32 32 32 32 128 128 32 32 32 32 64 64 128 128)
N=(32 32 32 64 32 64 32 32 32 64 32 128 32 32 32 64 32 64 32 128)
P=(32 96 64 32 64 32 32 96 64 32 128 32 32 64 96 32 64 32 128 32)

# gvsoc grid
DEPTHS=${DEPTHS:-"64 128 256"}
HOLDS=${HOLDS:-"4 6 8 10 12"}
FIRST_JOBS=${FIRST_JOBS:-"0 1900"}

# Arguments of the MemPool makes, from the Makefile
read -r -a ARGS <<< "$SW_ARGS"

mkdir -p "$OUT/elf" "$OUT/logs"

###########
# Build   #
###########

for i in "${!BATCH[@]}"; do
  name=b${BATCH[i]}_${M[i]}x${N[i]}x${P[i]}
  echo "build $name"
  python3 "$MP/software/data/gendata_header.py" --app_name gemm_f16 --type float16 \
    --defines "matrix_M=${M[i]},matrix_N=${N[i]},matrix_P=${P[i]},Batch=${BATCH[i]}" \
    --arrays "__fp16:l2_X,__fp16:l2_W,__fp16:l2_Y,__fp16:l2_Z" > "$OUT/logs/build_$name.log" || exit 1
  rm -f "$MP/software/apps/baremetal/gemm_f16/main.c.o" "$MP/software/bin/apps/baremetal/gemm_f16"
  # -o: keep the header generated above (the rule would regenerate it from the hjson)
  make -C "$MP/software/apps/baremetal" "${ARGS[@]}" -o "$MP/software/data/data_gemm_f16.h" \
    gemm_f16 >> "$OUT/logs/build_$name.log" 2>&1 || exit 1
  cp "$MP/software/bin/apps/baremetal/gemm_f16" "$OUT/elf/$name"
done

###########
# RTL     #
###########

BUILD=build_calib_$(basename "$OUT")
[[ -f $OUT/rtl.csv ]] || echo "batch,M,N,P,cycles" > "$OUT/rtl.csv"
for i in "${!BATCH[@]}"; do
  name=b${BATCH[i]}_${M[i]}x${N[i]}x${P[i]}
  grep -q "^${BATCH[i]},${M[i]},${N[i]},${P[i]}," "$OUT/rtl.csv" && continue
  echo "rtl $name"
  timeout 40m make -C "$MP/hardware" "${ARGS[@]}" buildpath=$BUILD app=$name \
    app_path="$OUT/elf" simc > "$OUT/logs/rtl_$name.log" 2>&1
  cyc=$(grep -ao "TIME: [0-9]*" "$MP/hardware/$BUILD/transcript" | grep -o "[0-9]*$" | tail -1)
  echo "${BATCH[i]},${M[i]},${N[i]},${P[i]},${cyc:-NA}" >> "$OUT/rtl.csv"
done

###########
# gvsoc   #
###########

# Appended to across runs; the summary covers every point in it
[[ -f $OUT/gvsoc.csv ]] || echo "depth,hold,first,batch,M,N,P,gvsoc,rtl" > "$OUT/gvsoc.csv"
for d in $DEPTHS; do
  for h in $HOLDS; do
    for f in $FIRST_JOBS; do
      # Sizes not run yet at this point
      todo=()
      for i in "${!BATCH[@]}"; do
        grep -q "^$d,$h,$f,${BATCH[i]},${M[i]},${N[i]},${P[i]}," "$OUT/gvsoc.csv" || todo+=("$i")
      done
      [[ ${#todo[@]} -gt 0 ]] || continue
      export TE_QUEUE_DEPTH=$d L1_BANK_HOLD=$h TE_FIRST_JOB_LATENCY=$f
      echo "gvsoc depth=$d hold=$h first=$f (${#todo[@]} sizes)"
      make -C "$DIR/.." TARGETS=tensorpool build > "$OUT/logs/gvsoc_build.log" 2>&1 || exit 1
      for i in "${todo[@]}"; do
        name=b${BATCH[i]}_${M[i]}x${N[i]}x${P[i]}
        rtl=$(awk -F, -v k="${BATCH[i]},${M[i]},${N[i]},${P[i]}" \
          '$1 "," $2 "," $3 "," $4 == k { print $5 }' "$OUT/rtl.csv")
        gvrun --target tensorpool --work-dir "$OUT/work" \
          --param mempool_soc/binary="$OUT/elf/$name" run > "$OUT/logs/gvsoc.log" 2>&1
        cyc=$(grep -ao "TIME: [0-9]*" "$OUT/logs/gvsoc.log" | grep -o "[0-9]*$" | tail -1)
        echo "$d,$h,$f,${BATCH[i]},${M[i]},${N[i]},${P[i]},${cyc:-NA},$rtl" >> "$OUT/gvsoc.csv"
      done
    done
  done
done

###########
# Summary #
###########

# Mean gvsoc/RTL ratio and mean absolute error per point, best first
awk -F, 'NR > 1 && $8 ~ /^[0-9]+$/ && $9 ~ /^[0-9]+$/ {
    k = $1 "," $2 "," $3; r = $8 / $9; s[k] += r; e[k] += (r > 1 ? r - 1 : 1 - r); n[k]++ }
  END { for (k in n) printf "%s,%d,%.3f,%.3f\n", k, n[k], s[k] / n[k], e[k] / n[k] }' "$OUT/gvsoc.csv" |
  sort -t, -k6,6g | (echo "depth,hold,first,cases,mean_ratio,mae"; cat) > "$OUT/summary.csv"
column -s, -t "$OUT/summary.csv"

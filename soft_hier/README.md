# l1_transformer on GVSoC

`run_l1_transformer.sh` builds and simulates the L1 transformer
(MemPool repo, `software/apps/`):

- `single`: `nn/l1_transformer_f16` on one cluster (`tensorpool` model).
- `multi`: `multi_cluster/l1_transformer_mc_f16` on `NUM_CLUSTERS` clusters
  (mc_pool model). Each cluster runs the convolutions and FFN on
  `BEAM/NUM_CLUSTERS` beams and the attention on `1/NUM_CLUSTERS` of the
  attention batches.

## Run

```bash
cd soft_hier
BUILD_GVSOC=1 ./run_l1_transformer.sh single   # BUILD_GVSOC=1 only on the first run or after model changes
BUILD_GVSOC=1 ./run_l1_transformer.sh multi
```

The log and a per-region CSV go to `results/run_<app>/`, named

- single: `<NUM_CORES>pe_<NUM_TE_TILES>rm_<HEIGHT>x<WIDTH>_<BEAM>_<EMBED>_<TDSAMPLES>`
- multi:  `<NUM_CLUSTERS>c_<NUM_CORES>pe_<NUM_TE_TILES>rm_<HEIGHT>x<WIDTH>_<BEAM>_<EMBED>_<TDSAMPLES>`

The `multi` target is `pulp.chips.mc_pool.configs.mc_pool_tensorpool_target`,
configured by `McPoolArchTensorPool` in
`pulp/pulp/chips/mc_pool/mc_pool_arch_base.py`. Its HBM channels are plain
memories, without the DRAM timing: set `hbm_dramsys = True` there to model them
with DRAMSys, which needs SystemC and makes the simulation much slower.
The script generates the matching architecture headers of the MemPool runtime
(`mc_cluster_arch.h`/`.inc`) with `pulp/pulp/chips/mc_pool/common/utils/config.py`
into `build/mc_pool_arch_tensorpool` and passes them with `MC_ARCH_DIR`.

With the defaults, `multi` takes 94,222 cycles (`TOTAL cycles` in the log).
`single` takes 220,842 cycles (sum of the regions, with the Wf = 3 im2col
of `mempool_conv1d_f16.h`; 271,523 with the scalar one).

Options (environment variables):

| Variable | Default | |
|---|---|---|
| `DEFINES` | `-DPIPELINED -DTILESHIFT -DREPLICATE_F` | multi: add `-DVERIFY` for the checks |
| `BEAM`, `EMBED`, `TDSAMPLES` | `128`, `32`, `32` | shapes |
| `NUM_CORES` | `512` | cores per cluster (multiple of 64, e.g. `256`, `512`) |
| `NUM_TE_TILES` | `16` | tensor engines (TEs) per cluster, independent of `NUM_CORES`: multiple of 16, at most one per tile (`NUM_CORES/4`), not checked by the script |
| `HEIGHT`, `WIDTH` | `8`, `32` | TE array shape; for O-POPE `HEIGHT` and `WIDTH` are equal, `HEIGHT` is used as `OPOPE_P` |
| `TENSOR_ENGINE` | `redmule` | `redmule` or `opope` |
| `NUM_CLUSTERS` | `8` | multi: must divide `BEAM`, `EMBED`, `TDSAMPLES` |
| `MEMPOOL_DIR` | `...` | MemPool software tree |
| `BUILD_GVSOC` | `0` | `1` rebuilds the gvsoc model |
| `GVSOC_ARGS` | empty | extra gvsoc arguments, e.g. `--trace=redmule --trace-level=info` |

## Tensor-engine calibration

Both engine models have one request queue (`TE_QUEUE_DEPTH` entries, default
128): a request holds an entry until the array uses its data, so the array
stalls on the data it needs next. The L1 banks are held `L1_BANK_HOLD`
cycles per tensor-engine access (default 10). Neither default is the
calibrated value; set them in the environment. The engine is selected with
`TENSOR_ENGINE=redmule|opope` (the script sets `OPOPE_P=HEIGHT`).

Best points against RTL (batched `blas/gemm_f16`, cycles of `TIME:`):

| Engine | Cores | Engines | `TE_QUEUE_DEPTH` | `L1_BANK_HOLD` | gvsoc/RTL mean | mean abs. error |
|---|---|---|---|---|---|---|---|
| RedMulE 4x16 | 256 | 16 | 64 | 12 | 0.96 | 3.6% |
| O-POPE 8x8 (`OPOPE_P=8`) | 512 | 32 | 256 | 12 | 0.995 | 3.3% |
| O-POPE 16x16 (`OPOPE_P=16`) | 512 | 16 | 256 | 14 | 0.98 | 6.5% |

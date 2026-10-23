# L1 Transformer on GVSoC

`run_l1_transformer.sh` builds and simulates the L1 transformer
(MemPool repo, `software/apps/`):

- `single`: `nn/l1_transformer_f16` on one cluster (`tensorpool` model).
- `multi`: `multi_cluster/l1_transformer_mc_f16` on `NUM_CLUSTERS` clusters
  (mc_pool model). Each cluster runs the convolutions and FFN on
  `BEAM/NUM_CLUSTERS` beams and the attention on `1/NUM_CLUSTERS` of the
  attention batches.

## Run

```bash
MODE=<single/multi> make build-sw
MODE=<single/multi> make build-gvsoc
MODE=<single/multi> make run-gvsoc
```

The log and a per-region CSV go to `results/run_<app>/`, named

- single: `<NUM_CORES>pe_<NUM_TE_TILES>rm_<HEIGHT>x<WIDTH>_<BEAM>_<EMBED>_<TDSAMPLES>`
- multi:  `<NUM_CORES>pe_<NUM_TE_TILES>rm_<HEIGHT>x<WIDTH>_<BEAM>_<EMBED>_<TDSAMPLES>_<NUM_CLUSTERS>c`

The `multi` target is `pulp.chips.mc_pool.configs.mc_pool_tensorpool_target`,
configured by `McPoolArchTensorPool` in `pulp/pulp/chips/mc_pool/mc_pool_arch_base.py`. 

The script `pulp/pulp/chips/mc_pool/common/utils/config.py` generates the 
matching architecture headers of the MemPool runtime (`mc_cluster_arch.h`/`.inc`) 
into `build/mc_pool_arch_tensorpool` and passes them with `MC_ARCH_DIR`.

Options:

| Variable | Default | |
|---|---|---|
| `MEMPOOL_DIR` | `...` | MemPool software tree |
| `GVSOC_ARGS` | empty | extra gvsoc arguments, e.g. `--trace=redmule --trace-level=info` |
| `DEFINES` | `-DPIPELINED -DTILESHIFT` | multi: add `-DVERIFY` for the checks |
| `BEAM`, `EMBED`, `TDSAMPLES` | `128`, `32`, `32` | shapes |
| `NUM_CLUSTERS` | `8` | multi: must divide `BEAM`, `EMBED`, `TDSAMPLES` |
| `NUM_CORES` | `512` | cores per cluster (multiple of 64, e.g. `256`, `512`) |
| `NUM_CORES_PER_TILE` | `4` | cores per tile |
| `NUM_SUB_GROUPS_PER_GROUP` | `4` | subgroups per group |
| `BANK_FACTOR` | `4` | banking factor |
| `TENSOR_ENGINE` | `redmule` | `redmule` or `opope` |
| `NUM_TE_TILES` | `16` | tensor engines (TEs) per cluster |
| `HEIGHT`, `WIDTH` | `8`, `32` | TE array shape; for O-POPE `HEIGHT` and `WIDTH` are equal |

## Tensor-engine calibration

Both engine models have one request queue (`TE_QUEUE_DEPTH` entries): a
request holds an entry until the array uses its data, so the array stalls on
the data it needs next. The L1 banks are held `L1_BANK_HOLD` cycles per
tensor-engine access. O-POPE also pays `TE_FIRST_JOB_LATENCY` cycles on the
first job of a run only (no effect on RedMulE). The defaults come from the
`_CALIBRATION` table of `pulp/pulp/mempool/redmule_configurations.py`, per
(engine, `NUM_CORES`, shape), and an environment variable overrides them. The
engine is selected with `TENSOR_ENGINE=redmule|opope` (the script sets
`OPOPE_P=HEIGHT`).

Best points against RTL (`make calibrate`: batched `baremetal/gemm_f16`, cycles
of `TIME:`, 20 sizes; results and plot in `results/calibration/`). The `_CALIBRATION`
table does not have these points yet; set them in the environment:

| Engine | Cores | Engines | `TE_QUEUE_DEPTH` | `L1_BANK_HOLD` | `TE_FIRST_JOB_LATENCY` | gvsoc/RTL mean | mean abs. error |
|---|---|---|---|---|---|---|---|
| O-POPE 8x8 (`OPOPE_P=8`) | 1024 | 64 | 256 | 6 | 1900 | 1.007 | 2.5% |
| O-POPE 8x8 (`OPOPE_P=8`) | 512 | 32 | 256 | 6 | 1000 | 1.017 | 3.8% |
| RedMulE 8x32 | 256 | 16 | 256 | 9 | 0 | 1.018 | 9.4% |

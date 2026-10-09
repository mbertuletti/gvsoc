# l1_transformer on GVSoC

`run_l1_transformer.sh` builds and simulates the 4-layer L1 transformer
(MemPool repo, `software/apps/`):

- `single`: `nn/l1_transformer_f16` on one cluster (`tensorpool` model).
- `multi`: `multi_cluster/l1_transformer_mc_f16` on `N_CLUSTERS` clusters
  (flex_cluster model). Each cluster runs the convolutions and FFN on
  `BEAM/N_CLUSTERS` beams and the attention on `1/N_CLUSTERS` of the
  attention batches.

## Run

```bash
cd soft_hier
BUILD_GVSOC=1 ./run_l1_transformer.sh single   # BUILD_GVSOC=1 only on the first run or after model changes
BUILD_GVSOC=1 ./run_l1_transformer.sh multi
```

The log and a per-region CSV go to `results/run_<app>/`. With the defaults,
`single` takes 268,457 cycles (sum of the regions) and `multi` 111,646
(`TOTAL cycles` in the log).

Options (environment variables):

| Variable | Default | |
|---|---|---|
| `DEFINES` | `-DPIPELINED -DTILESHIFT -DREPLICATE_F` | multi: add `-DVERIFY -DREDMULE_ZERO_OUTPUT` for the checks |
| `BEAM`, `EMBED`, `TDSAMPLES` | `128`, `32`, `32` | shapes |
| `NUM_CORES` | `512` single, `256` multi | cores per cluster (multi: multiple of 64, e.g. `256`, `512`) |
| `N_CLUSTERS` | `8` | multi: must divide `BEAM`, `EMBED`, `TDSAMPLES` |
| `MEMPOOL_DIR` | `/scratch/mbertuletti/mempool` | MemPool software tree |

## Architecture (multi)

The mesh, cluster and RedMulE sizes come from 
`pulp/pulp/chips/flex_cluster/configs/arch_tensorpool.py` (2x5 mesh, 
16 RedMulE 8x32 per cluster). The number of cores per cluster is set 
by `NUM_CORES`; the software headers and L1 bank size are generated 
from the same file. A software/model mismatch hangs the run after 
`DONE: Start`. Rebuild the model with `BUILD_GVSOC=1` after editing 
the file.

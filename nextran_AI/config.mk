# TensorPool configuration of the Makefile targets (l1_transformer runs and
# calibration). Every value can be overridden on the make command line.

MEMPOOL_DIR ?= /scratch/mbertuletti/mempool

# TensorPool parameters
NUM_CLUSTERS             ?= 8
NUM_CORES                ?= 1024
NUM_CORES_PER_TILE       ?= 8
NUM_SUB_GROUPS_PER_GROUP ?= 4
BANK_FACTOR              ?= 4
BANK_SIZE                ?= 1024
NUM_TE_TILES             ?= 64
# Remote-group access latency (RTL remote_group_latency_cycles: 7, 9 or 11)
REMOTE_GROUP_LATENCY     ?= 9

# Tensor engine parameters
TENSOR_ENGINE            ?= opope
HEIGHT                   ?= 8
WIDTH                    ?= 8
REGS                     ?= 3

# GVSOC timing of the tensor engine (see make calibrate)
TE_QUEUE_DEPTH           ?= 128
L1_BANK_HOLD             ?= 6
TE_FIRST_JOB_LATENCY     ?= 1900

# l1_transformer on gvsoc: single cluster (tensorpool model) or multi cluster
# (mc_pool model).
#
#   make build-gvsoc                   build the gvsoc model
#   make build-sw   [MODE=single|multi] build the MemPool application
#   make run-gvsoc  [MODE=single|multi] simulate it
#   make calibrate                     fit the gvsoc timing to the RTL
#
# Every parameter below can be overridden on the command line, e.g.
#   make run MODE=multi BEAM=64 EMBED=16 TE_QUEUE_DEPTH=256
#
# The gvsoc model and the MemPool software must describe the same architecture:
# the software gets it as make arguments, the gvsoc model reads it from the
# environment, hence the exports.

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -ec

TARGET_DIR  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR    := $(abspath $(TARGET_DIR)/..)
MC_ARCH_DIR := $(ROOT_DIR)/build/mc_pool_arch_tensorpool
# Architecture, tensor engine, gvsoc timing and calibration settings
CONFIG      ?= config.mk
include $(TARGET_DIR)/$(CONFIG)

MODE ?= single

# Problem size
BEAM                     ?= 128
EMBED                    ?= 32
TDSAMPLES                ?= 32
SHAPE                    := $(BEAM)x$(EMBED)x$(TDSAMPLES)
TE_NAME                  := $(TENSOR_ENGINE)_$(NUM_CORES)pe_$(NUM_TE_TILES)te_$(HEIGHT)x$(WIDTH)
TAG                      := $(TE_NAME)_$(SHAPE)

# Environment of the gvsoc model
GVSOC_ENV := source $(ROOT_DIR)/sourceme.sh && source $(ROOT_DIR)/sourceme_systemc.sh
export NUM_CORES NUM_CORES_PER_TILE NUM_SUB_GROUPS_PER_GROUP BANK_FACTOR BANK_SIZE
export TENSOR_ENGINE TE_QUEUE_DEPTH L1_BANK_HOLD TE_FIRST_JOB_LATENCY
export REMOTE_GROUP_LATENCY
export NUM_REDMULE_TILES := $(NUM_TE_TILES)
export REDMULE_HEIGHT    := $(HEIGHT)
export REDMULE_WIDTH     := $(WIDTH)
export REDMULE_REGS      := $(REGS)
export OPOPE_P           := $(HEIGHT)
# Extra gvrun arguments (e.g. GVSOC_ARGS="--trace=...")
GVSOC_ARGS ?=

# Application variant
DEFINES    ?= -DPIPELINED -DFUSE_CHAIN -DTILESHIFT -DATTENTION_ROUNDS=2 -DLOG_BARRIER=5 -DVFEXP
SW_DEFINES := $(DEFINES) -DBEAM=$(BEAM) -DEMBED=$(EMBED) -DTDSAMPLES=$(TDSAMPLES)

SW_ARGS := COMPILER=llvm config=tensorpool
SW_ARGS += num_cores=$(NUM_CORES)
SW_ARGS += num_cores_per_tile=$(NUM_CORES_PER_TILE)
SW_ARGS += num_sub_groups_per_group=$(NUM_SUB_GROUPS_PER_GROUP)
SW_ARGS += banking_factor=$(BANK_FACTOR)
SW_ARGS += l1_bank_size=$(BANK_SIZE)
SW_ARGS += num_redmule_tiles=$(NUM_TE_TILES)
SW_ARGS += redmule_height=$(HEIGHT)
SW_ARGS += redmule_width=$(WIDTH)
SW_ARGS += redmule_regs=$(REGS)
SW_ARGS += tensor_engine=$(TENSOR_ENGINE)
SW_ARGS += remote_group_latency_cycles=$(REMOTE_GROUP_LATENCY)
# Also used by calibration.sh
export SW_ARGS

ifeq ($(MODE),single)
  APP          := nn/l1_transformer_f16
  GVSOC_TARGET := tensorpool
  BINARY_PARAM := mempool_soc/binary

else ifeq ($(MODE),multi)
  APP          := multi_cluster/l1_transformer_mc_f16
  GVSOC_TARGET := pulp.chips.mc_pool.configs.mc_pool_tensorpool_target
  BINARY_PARAM := system/binary
  TAG          := $(TAG)_$(NUM_CLUSTERS)c
  SW_DEFINES   += -DN_CLUSTERS=$(NUM_CLUSTERS)
  # Architecture headers of the simulated mc_pool configuration
  SW_ARGS      += MC_ARCH_DIR=$(MC_ARCH_DIR)

else
  $(error MODE must be single or multi, not '$(MODE)')
endif

ELF     := $(MEMPOOL_DIR)/software/bin/$(APP)
OUTDIR  ?= $(TARGET_DIR)/results/run_l1_transformer
LOG     := $(OUTDIR)/$(TAG).log
# gvsoc work directory (gvsoc_config.json, ...): next to the logs and CSVs
WORKDIR := $(OUTDIR)

# Do not forward our command-line variables to the MemPool and gvsoc sub-makes:
# a command-line DEFINES would override the architecture macros MemPool appends
MAKEOVERRIDES :=

.PHONY: build-gvsoc build-sw run-gvsoc calibrate info

## BUILD SW

build-sw:
	@echo "DEFINES=\"$(SW_DEFINES)\" $(SW_ARGS)"
	python3 $(ROOT_DIR)/pulp/pulp/chips/mc_pool/common/utils/config.py tensorpool $(MC_ARCH_DIR)
	rm -f $(MEMPOOL_DIR)/software/apps/$(APP)/main.c.o $(ELF)
	DEFINES="$(SW_DEFINES)" $(SW_ARGS) $(MAKE) -C $(MEMPOOL_DIR)/software/apps $(APP)
	test -x $(ELF)

## BUILD GVSOC

build-gvsoc:
	$(GVSOC_ENV) && $(MAKE) -C $(ROOT_DIR) TARGETS=$(GVSOC_TARGET) build

## RUN GVSOC

run-gvsoc: build-sw
	test -x $(ELF) || { echo "missing $(ELF): run make build-sw MODE=$(MODE)"; exit 1; }
	mkdir -p $(OUTDIR) $(WORKDIR)
	$(GVSOC_ENV) && stdbuf -oL -eL gvrun --target $(GVSOC_TARGET) --work-dir $(WORKDIR) \
		--param $(BINARY_PARAM)=$(ELF) $(GVSOC_ARGS) run 2>&1 | tee $(LOG)
	python3 $(TARGET_DIR)/utils/bench_region_stats.py $(LOG) --csv $(LOG:.log=.csv)
	python3 -c 'import csv,sys; print("total mean cycles:", round(sum(float(r["mean_cycles"]) for r in csv.DictReader(open(sys.argv[1])))))' $(LOG:.log=.csv)

## CALIBRATION

# Fit the gvsoc tensor-engine timing to the RTL (see calibration.sh)
calibrate:
	$(GVSOC_ENV) && DEFINES="-DPARALLEL_BATCHED" MEMPOOL_DIR=$(MEMPOOL_DIR) $(TARGET_DIR)/calibration.sh

info:
	@echo "MODE=$(MODE) target=$(GVSOC_TARGET) app=$(APP)"
	@echo "arch: $(TE_NAME) clusters=$(NUM_CLUSTERS) banks=$(BANK_FACTOR)x$(BANK_SIZE)"
	@echo "calib: queue=$(TE_QUEUE_DEPTH) hold=$(L1_BANK_HOLD) first_job=$(TE_FIRST_JOB_LATENCY)"
	@echo "sw: $(SW_DEFINES)"
	@echo "log: $(LOG)"

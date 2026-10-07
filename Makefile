VERILATOR ?= verilator
PYTHON ?= python3.14
# Hardware tests share two Verilator binaries. TEST_JOBS parallelizes the
# runs after the binaries exist; it defaults to the machine's CPU count.
TEST_JOBS ?= $(shell nproc 2>/dev/null || echo 2)
# excore tooling is plain Python 3 (not CPython-3.14-coupled — RV32I
# encodings come from the ISA spec, not from probing a running interpreter).
PYTHON3 ?= python3
BUILD_DIR ?= build
DOCKER_IMAGE ?= python-cpu-sim
DOCKER_CONTAINER_WORKDIR ?= /work
DOCKER_BUILD_FLAGS ?=
DOCKER_RUN_FLAGS ?=

PYCORE_CACHE_EN ?= 1
# CI default is 4 once the RAM model exists (P2); 1-cycle banks ignore it.
PYCORE_MEM_LATENCY ?= 4
PYCORE_MEM_PLUSARGS ?= +CACHE_EN=$(PYCORE_CACHE_EN) +MEM_LATENCY=$(PYCORE_MEM_LATENCY)
# Extra simulator plusargs for every hardware test, placed before each
# test's own so they win (Verilog takes the first match), e.g.
# `make test-hw HW_PLUSARGS=+GC_EN=1` runs the suite with the collector on.
HW_PLUSARGS ?=
# GC acceptance runner (planning/gc_plan.md §10.3): MODE=quick|full.
MODE ?= quick

PYCORE_SOURCE ?= pycore/programs/smoke_return.py
PYCORE_FUNCTION ?= managed_entry
PYCORE_PROGRAM_HEX ?= pycore/programs/program.hex
PYCORE_STRING_HEX ?= pycore/programs/string_mem.hex
PYCORE_TYPES ?= pycore/programs/program.types
PYCORE_CACHE_MAP ?= pycore/programs/cache_map.hex

RUN_SOURCE ?= pycore/programs/demo_exec.py
RUN_FUNCTION ?= managed_entry
# run-file compiles on the device by default. HOST_COMPILE=1 builds the image
# with host CPython instead (the hardware-test path). Empty RUN_MAX_CYCLES /
# RUN_BUILD_DIR let pycore_cli.py pick the per-mode defaults.
HOST_COMPILE ?=
RUN_MAX_CYCLES ?=
RUN_BUILD_DIR ?=

PYCORE_RTL_SRCS := \
	pycore/rtl/pycore_tag_decode.sv \
	pycore/rtl/pycore_promote.sv \
	pycore/rtl/pycore_int_alu.sv \
	pycore/rtl/pycore_mul.sv \
	pycore/rtl/pycore_div.sv \
	pycore/rtl/pycore_fpu.sv \
	pycore/rtl/pycore_complex_alu.sv \
	pycore/rtl/pycore_str_accel.sv \
	pycore/rtl/pycore_exec.sv \
	pycore/rtl/pycore_regfile.sv \
	pycore/rtl/pycore_fetch.sv \
	pycore/rtl/pycore_decode.sv \
	pycore/rtl/pycore_branch.sv \
	pycore/rtl/pycore_trap.sv \
	pycore/rtl/pycore_frame.sv \
	pycore/rtl/pycore_mem_block.sv \
	pycore/rtl/pycore_mem_bank.sv \
	pycore/rtl/pycore_imem.sv \
	pycore/rtl/pycore_code_ram.sv \
	pycore/rtl/pycore_code_mem.sv \
	pycore/rtl/pycore_dmem.sv \
	pycore/rtl/pycore_cache_lru.sv \
	pycore/rtl/pycore_cache.sv \
	pycore/rtl/pycore_codc.sv \
	pycore/rtl/pycore_gic.sv \
	pycore/rtl/pycore_ram.sv \
	pycore/rtl/pycore_mem_xbar.sv \
	pycore/rtl/pycore_mem_hier.sv \
	pycore/rtl/pycore_mem_stage.sv \
	pycore/rtl/pycore_exc_stack.sv \
	pycore/rtl/pycore_gc.sv \
	pycore/rtl/pycore_core.sv \
	pycore/rtl/pycore_system.sv \
	excore/rtl/excore_cpu.sv \
	excore/rtl/excore_mmio.sv \
	excore/rtl/trap_mailbox.sv \
	pycore/rtl/pycore_excore_system.sv

PYCORE_MEM_SRCS := \
	pycore/rtl/pycore_mem_block.sv \
	pycore/rtl/pycore_mem_bank.sv \
	pycore/rtl/pycore_cache_lru.sv \
	pycore/rtl/pycore_cache.sv \
	pycore/rtl/pycore_ram.sv \
	pycore/rtl/pycore_mem_xbar.sv

# ---- excore (Phase B: standalone excore, no pycore integration yet) -------
EXCORE_FW_SRC ?= excore/fw/list_grow.s
EXCORE_FW_HEX ?= $(BUILD_DIR)/excore_fw/list_grow.hex

# Vendored singlecore RV32 sources are pulled in via `include from
# excore_cpu.sv; every Verilator invoke that builds PYCORE_RTL_SRCS /
# EXCORE_RTL_SRCS also needs +incdir+excore/rtl/singlecore (applied below).

EXCORE_RTL_SRCS := \
	pycore/rtl/pycore_mem_block.sv \
	pycore/rtl/pycore_mem_bank.sv \
	excore/rtl/excore_cpu.sv \
	excore/rtl/excore_mmio.sv

.PHONY: help lint-file pycore-preprocess run-file pycore-run-file exec-file \
	shell all-tests pycore-tag-decode pycore-exec pycore-type-pairs \
	pycore-python-tests pycore-size-report pycore-compile-suite pycore-mem \
	pycore-cache-lru pycore-cache pycore-ram pycore-l1d-handoff pycore-fetch \
	pycore-frame pycore-frame-fib pycore-regfile pycore-codc pycore-gic \
	pycore-img-container-call-spike \
	pycore-list-append-fixtures pycore-for-iter-fixtures \
	pycore-list-extend-fixtures pycore-excore-integration-fixtures \
	pycore-excore-grow-oom-fatal pycore-excore-disabled \
	pycore-excore-extend-oom-fatal pycore-excore-extend-disabled \
	pycore-allocator-host pycore-img-allocator-bytes excore-fw excore-asm-tests \
	excore-cpu-test excore-test clean pycore-sim-img pycore-sim-img-twocore \
	pycore-rtl-unit pycore-str-accel pycore-codc pycore-gic docker-build \
	docker-lint-file docker-run-file docker-exec-file docker-shell \
	docker-all-tests test-host test-rtl-modules test-hw test-caching \
	test-compiler-vs-cpython test-compiler-gc test-all test-gc-long $(addprefix test-,$(HW_AREAS)) \
	pycore-gc pycore-gc-mutants pycore-gc-acceptance pycore-gc-baseline pycore-gc-fuzz \
	pycore-gc-bench docker-pycore-gc-fuzz

pycore-preprocess:
	$(PYTHON) pycore/tools/preprocess.py \
		--source "$(PYCORE_SOURCE)" \
		--function "$(PYCORE_FUNCTION)" \
		--program-hex "$(PYCORE_PROGRAM_HEX)" \
		--string-hex "$(PYCORE_STRING_HEX)" \
		--types "$(PYCORE_TYPES)" \
		--cache-map "$(PYCORE_CACHE_MAP)"

help:
	$(PYTHON) pycore/tools/pycore_cli.py help

lint-file:
	$(PYTHON) pycore/tools/pycore_cli.py lint "$(RUN_SOURCE)" --entry "$(RUN_FUNCTION)"

run-file: pycore-run-file

# Hand PyCore the *source*: the on-device compile() builds it, exec() runs it,
# output streams live, then the same file runs on CPython 3.14 and the report
# compares output and compile / run cycles. `make shell` is the interactive
# version (power on once, then type file paths).
EXEC_ARGS ?=

exec-file:
	$(PYTHON) pycore/tools/pycore_cli.py exec "$(RUN_SOURCE)" $(EXEC_ARGS)

shell:
	$(PYTHON) pycore/tools/pycore_cli.py shell $(EXEC_ARGS)

# Run a user Python file on the two-core hart. By default the on-device
# compile() builds it (same as exec-file) and the output is compared with
# CPython 3.14. HOST_COMPILE=1 instead image-boots a host-built image and
# checks managed_entry()'s return against host CPython (lint first with
# `make lint-file`). Both use the shared plusarg tb_container binary.
pycore-run-file:
	$(PYTHON) pycore/tools/pycore_cli.py run "$(RUN_SOURCE)" \
		$(if $(HOST_COMPILE),--host-compile --entry "$(RUN_FUNCTION)") \
		$(if $(RUN_MAX_CYCLES),--max-cycles $(RUN_MAX_CYCLES)) \
		$(if $(RUN_BUILD_DIR),--build-dir "$(RUN_BUILD_DIR)") \
		$(EXEC_ARGS)

# Shared tb_container binaries: hex paths and goldens are plusargs, not -G.
PYCORE_SIM_IMG_BIN := $(BUILD_DIR)/sim_img/Vtb_container
PYCORE_SIM_TWOCORE_BIN := $(BUILD_DIR)/sim_img_twocore/Vtb_container
PYCORE_SIM_DEPS := \
	$(PYCORE_RTL_SRCS) \
	pycore/tb/tb_container.sv \
	pycore/tb/gc_tb_util.svh \
	pycore/tb/gc_shadow_check.sv \
	$(wildcard pycore/rtl/*.svh) \
	$(wildcard excore/rtl/*.svh) \
	$(wildcard excore/rtl/singlecore/*.sv)
# OPT_FAST=-O2: Verilator compiles the model with -Os by default; -O2 runs
# the image simulators about 3.4x faster with identical results and cycles.
PYCORE_SIM_VERILATOR_FLAGS := \
	-sv --binary --timing \
	+incdir+pycore/rtl +incdir+pycore/tb +incdir+excore/rtl/singlecore \
	--top-module tb_container \
	-GPROG_HEX=\"\" \
	-GDMEM_HEX=\"\" \
	-GCODE_RAM_HEX=\"\" \
	-GFW_HEX=\"\" \
	-Wall -Wno-fatal \
	-MAKEFLAGS OPT_FAST=-O2

$(PYCORE_SIM_IMG_BIN): $(PYCORE_SIM_DEPS)
	mkdir -p $(BUILD_DIR)/sim_img
	$(VERILATOR) $(PYCORE_SIM_VERILATOR_FLAGS) \
		-GEXCORE_EN=0 \
		--Mdir $(BUILD_DIR)/sim_img \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv

pycore-sim-img: $(PYCORE_SIM_IMG_BIN)

$(PYCORE_SIM_TWOCORE_BIN): $(PYCORE_SIM_DEPS) $(EXCORE_FW_HEX)
	mkdir -p $(BUILD_DIR)/sim_img_twocore
	$(VERILATOR) $(PYCORE_SIM_VERILATOR_FLAGS) \
		-GEXCORE_EN=1 \
		--Mdir $(BUILD_DIR)/sim_img_twocore \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv

pycore-sim-img-twocore: $(PYCORE_SIM_TWOCORE_BIN)

# ---- Tests ------------------------------------------------------------------
# Every test target is named for what it checks. The hardware tests (one
# program on the simulated hart each) are listed by area in
# pycore/programs/hw_tests.toml and run by pycore/tools/hw_tests.py, which
# builds each image once and reuses it across memory configurations.
#
#   test-host                  Python unit tests of the host tools and compiler
#   test-rtl-modules           per-module RTL testbenches
#   test-<area>                one hardware area, default memory config
#   test-hw                    every hardware area
#   test-caching               memory-system gate: cache off at latency 1/4/30
#                              and cache on at latency 30 (see hw_tests.py)
#   test-compiler-vs-cpython   compile on the hart, run on the hart, compare
#                              with CPython 3.14 (pycore/programs/compile_suite)
#   test-all                   all of the above
#
# The old per-fixture names still work: `make pycore-img-smoke` runs the
# `smoke` test. `python3.14 pycore/tools/hw_tests.py --list` lists them all.
#   test-gc-long               long GC loops (nightly / on demand, not per PR)
HW_AREAS := alu strings containers control-flow calls objects variables \
	exceptions builtins memory excore compiler gc
HW_TESTS = $(PYTHON) pycore/tools/hw_tests.py --jobs $(TEST_JOBS) \
	$(if $(HW_PLUSARGS),--plusargs "$(HW_PLUSARGS)")

test-host: pycore-python-tests pycore-size-report excore-asm-tests \
	pycore-allocator-host

test-rtl-modules: pycore-rtl-unit

$(addprefix test-,$(HW_AREAS)):
	$(HW_TESTS) --area $(patsubst test-%,%,$@)

# The excore area also runs the helper core's own CPU testbench.
test-excore: excore-cpu-test

# The gc area also runs the collector engine's unit testbench (gate G3).
test-gc: pycore-gc

# Long GC loops and soak programs: minutes to hours each, so they are not
# part of test-hw or the per-PR CI matrix (pycore/docs/gc.md, Testing).
test-gc-long:
	$(HW_TESTS) --area gc-long

test-hw:
	$(HW_TESTS) --area all --exclude-area gc-long

test-caching:
	$(HW_TESTS) --caching --exclude-area gc-long

test-compiler-vs-cpython:
	$(PYTHON) pycore/tools/compile_suite.py --jobs $(TEST_JOBS)

# The same suite with the collector on and a 512 KB heap: every program
# collects 3-7 times, several of them in the middle of compile() (the
# largest, cs_program, needs about 400 KB at its peak). The report adds the
# live bytes compile() kept and the longest pause. pycore/docs/gc.md, Testing.
COMPILER_GC_HEAP ?= 524288
test-compiler-gc:
	$(PYTHON) pycore/tools/compile_suite.py --jobs $(TEST_JOBS) --build-dir build/compile_suite_gc \
		--plusargs "+GC_EN=1 +HEAP_DYN_BYTES=$(COMPILER_GC_HEAP)"

test-all:
	$(MAKE) test-host test-rtl-modules
	$(MAKE) test-hw excore-cpu-test pycore-gc
	$(MAKE) test-compiler-vs-cpython test-caching

all-tests: test-all

# ---- Garbage collector -------------------------------------------------------
# GC engine unit testbench (planning/gc_plan.md §10.2 G3): pycore_gc on the
# real memory hierarchy. `make pycore-gc` builds it and runs the seeded
# heaps from pycore/tools/gc_heapgen.py against the gc_model.py oracle.
PYCORE_TB_GC_BIN := $(BUILD_DIR)/tb_gc/Vtb_gc
GC_UNIT_SEEDS ?= 200
GC_UNIT_ARGS ?=

$(PYCORE_TB_GC_BIN): $(PYCORE_MEM_SRCS) pycore/rtl/pycore_mem_hier.sv pycore/rtl/pycore_gc.sv \
		pycore/tb/tb_gc.sv pycore/tb/gc_tb_util.svh pycore/rtl/pycore_defs.svh
	mkdir -p $(BUILD_DIR)/tb_gc
	$(VERILATOR) -sv --binary --timing +incdir+pycore/rtl +incdir+pycore/tb \
		--top-module tb_gc --Mdir $(BUILD_DIR)/tb_gc -Wall -Wno-fatal -MAKEFLAGS OPT_FAST=-O2 \
		$(PYCORE_MEM_SRCS) pycore/rtl/pycore_mem_hier.sv pycore/rtl/pycore_gc.sv pycore/tb/tb_gc.sv

pycore-gc: $(PYCORE_TB_GC_BIN)
	$(PYTHON) tools/gc_unit.py --seeds $(GC_UNIT_SEEDS) --jobs $(TEST_JOBS) $(GC_UNIT_ARGS)

# G10 (planning/gc_plan.md §10.2): the quick gates (G3-G8, then G1) against
# every mutant compiled into the RTL (+GC_MUTANT=<n>), after one run with no
# mutant. MUTANTS=1,5,20 restricts the run. Results: build/gc_mutants/.
pycore-gc-mutants: $(PYCORE_TB_GC_BIN)
	$(PYTHON) tools/gc_mutants.py --jobs $(TEST_JOBS) $(if $(MUTANTS),--only $(MUTANTS))

# GC acceptance (planning/gc_plan.md §10.3): MODE=quick runs G0-G8, MODE=full
# G0-G16; status in build/gc_acceptance/status.json and report.md. The gates'
# test sets and plusargs are the [gate.*] tables of hw_tests.toml.
pycore-gc-acceptance: $(PYCORE_TB_GC_BIN)
	$(PYTHON) tools/gc_acceptance.py --mode $(MODE) --jobs $(TEST_JOBS)

# G0: rerun every hardware test on main (a worktree under build/gc_baseline)
# and rewrite pycore/tests/data/gc_baseline_*. BASELINE_REF picks the commit.
BASELINE_REF ?= origin/main
pycore-gc-baseline:
	$(PYTHON) tools/gc_baseline.py --ref $(BASELINE_REF) --jobs $(TEST_JOBS)

# G8 (planning/gc_plan.md §10.2): randomized differential fuzzing.
# SEEDS=0..49 (quick) or 0..999 (full). TOP=single|twocore.
SEEDS ?= 0..49
TOP ?= single
pycore-gc-fuzz:
	$(PYTHON) pycore/tools/gc_fuzz.py --seeds $(SEEDS) --top $(TOP) --jobs $(TEST_JOBS)

# G13 (planning/gc_plan.md §10.2): bench fixtures + counter table, P3-P7.
# FUZZ_OUT=build/gc_fuzz also scores P8 over a pycore-gc-fuzz corpus.
FUZZ_OUT ?=
pycore-gc-bench:
	$(PYTHON) tools/gc_bench.py --jobs $(TEST_JOBS) $(if $(FUZZ_OUT),--fuzz-out $(FUZZ_OUT))

pycore-img-%:
	$(HW_TESTS) --target $@

pycore-container-%:
	$(HW_TESTS) --target $@

pycore-excore-%:
	$(HW_TESTS) --target $@

pycore-tag-decode:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_tag_decode \
		--Mdir $(BUILD_DIR)/pycore_tag_decode \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_tag_decode.sv pycore/tb/tb_tag_decode.sv
	./$(BUILD_DIR)/pycore_tag_decode/Vtb_tag_decode

pycore-exec:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_exec \
		--Mdir $(BUILD_DIR)/pycore_exec \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_tag_decode.sv \
		pycore/rtl/pycore_promote.sv \
		pycore/rtl/pycore_int_alu.sv \
		pycore/rtl/pycore_mul.sv \
		pycore/rtl/pycore_div.sv \
		pycore/rtl/pycore_fpu.sv \
		pycore/rtl/pycore_complex_alu.sv \
		pycore/rtl/pycore_exec.sv \
		pycore/tb/tb_exec.sv
	./$(BUILD_DIR)/pycore_exec/Vtb_exec

pycore-type-pairs:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_type_pairs \
		--Mdir $(BUILD_DIR)/pycore_type_pairs \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_tag_decode.sv \
		pycore/rtl/pycore_promote.sv \
		pycore/rtl/pycore_int_alu.sv \
		pycore/rtl/pycore_mul.sv \
		pycore/rtl/pycore_div.sv \
		pycore/rtl/pycore_fpu.sv \
		pycore/rtl/pycore_complex_alu.sv \
		pycore/rtl/pycore_exec.sv \
		pycore/tb/tb_type_pairs.sv
	./$(BUILD_DIR)/pycore_type_pairs/Vtb_type_pairs

pycore-mem:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_mem_bank \
		--Mdir $(BUILD_DIR)/pycore_mem \
		-Wall -Wno-fatal \
		$(PYCORE_MEM_SRCS) pycore/tb/tb_mem_bank.sv
	./$(BUILD_DIR)/pycore_mem/Vtb_mem_bank

pycore-cache-lru:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_cache_lru \
		--Mdir $(BUILD_DIR)/pycore_cache_lru \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_cache_lru.sv pycore/tb/tb_cache_lru.sv
	./$(BUILD_DIR)/pycore_cache_lru/Vtb_cache_lru

pycore-cache:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_cache \
		--Mdir $(BUILD_DIR)/pycore_cache \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_cache_lru.sv pycore/rtl/pycore_cache.sv \
		pycore/rtl/pycore_ram.sv pycore/tb/tb_cache.sv
	./$(BUILD_DIR)/pycore_cache/Vtb_cache

pycore-codc:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_codc \
		--Mdir $(BUILD_DIR)/pycore_codc \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_cache_lru.sv pycore/rtl/pycore_codc.sv \
		pycore/tb/tb_codc.sv
	./$(BUILD_DIR)/pycore_codc/Vtb_codc

pycore-gic:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_gic \
		--Mdir $(BUILD_DIR)/pycore_gic \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_cache_lru.sv pycore/rtl/pycore_gic.sv \
		pycore/tb/tb_gic.sv
	./$(BUILD_DIR)/pycore_gic/Vtb_gic

pycore-l1d-handoff:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_l1d_handoff \
		--Mdir $(BUILD_DIR)/pycore_l1d_handoff \
		-Wall -Wno-fatal \
		$(PYCORE_MEM_SRCS) pycore/rtl/pycore_mem_hier.sv \
		pycore/tb/tb_l1d_handoff.sv
	./$(BUILD_DIR)/pycore_l1d_handoff/Vtb_l1d_handoff

# Non-blocking L1D port and pipelined L2 against a shadow memory, at the
# CI latency and at 30 cycles.
pycore-mem-nb:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_mem_nb \
		--Mdir $(BUILD_DIR)/pycore_mem_nb \
		-Wall -Wno-fatal \
		$(PYCORE_MEM_SRCS) pycore/rtl/pycore_mem_hier.sv \
		pycore/tb/tb_mem_nb.sv
	./$(BUILD_DIR)/pycore_mem_nb/Vtb_mem_nb +SEED=1 | tee $(BUILD_DIR)/pycore_mem_nb/run1.log
	grep -q "^PASS" $(BUILD_DIR)/pycore_mem_nb/run1.log
	./$(BUILD_DIR)/pycore_mem_nb/Vtb_mem_nb +SEED=2 +MEM_LATENCY=30 | tee $(BUILD_DIR)/pycore_mem_nb/run2.log
	grep -q "^PASS" $(BUILD_DIR)/pycore_mem_nb/run2.log

pycore-ram:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_ram \
		--Mdir $(BUILD_DIR)/pycore_ram \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_ram.sv pycore/tb/tb_ram.sv
	./$(BUILD_DIR)/pycore_ram/Vtb_ram

pycore-str-accel:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_str_accel \
		--Mdir $(BUILD_DIR)/pycore_str_accel \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_ram.sv pycore/rtl/pycore_str_accel.sv \
		pycore/tb/tb_str_accel.sv
	./$(BUILD_DIR)/pycore_str_accel/Vtb_str_accel
	PYTHONPATH=pycore/tools:$(PYTHONPATH) $(PYTHON) pycore/tools/strgen.py --seed 1 --n 2000
	PYTHONPATH=pycore/tools:$(PYTHONPATH) $(PYTHON) pycore/tools/strgen.py --seed 7 --n 2000

pycore-fetch:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_fetch \
		--Mdir $(BUILD_DIR)/pycore_fetch \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_fetch.sv pycore/tb/tb_fetch.sv
	./$(BUILD_DIR)/pycore_fetch/Vtb_fetch

pycore-frame:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_frame \
		--Mdir $(BUILD_DIR)/pycore_frame \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_frame.sv \
		pycore/tb/tb_frame.sv
	./$(BUILD_DIR)/pycore_frame/Vtb_frame

pycore-frame-fib:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_frame_fib_recursion \
		--Mdir $(BUILD_DIR)/pycore_frame_fib \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_frame.sv \
		pycore/tb/tb_frame_fib_recursion.sv
	./$(BUILD_DIR)/pycore_frame_fib/Vtb_frame_fib_recursion

pycore-regfile:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_regfile \
		--Mdir $(BUILD_DIR)/pycore_regfile \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_regfile.sv \
		pycore/tb/tb_regfile.sv
	./$(BUILD_DIR)/pycore_regfile/Vtb_regfile


# ---- Broad-object-support milestone targets (M6 / M8) ---------------------
# M6 allocator_list is the `allocator-list` hardware test (excore area).
# M8 allocator_bytes still needs bytearray / int.from_bytes; image build
# fails today. Host smoke is pycore-allocator-host (test-host). Add it to
# hw_tests.toml once it builds.
pycore-allocator-host:
	PYTHONPATH=pycore/tools:$$PYTHONPATH $(PYTHON) -c 'from pathlib import Path; import runpy, tempfile; from run_image_test import apply_heap_list_capacity_inject; text=apply_heap_list_capacity_inject(Path("pycore/programs/allocator_list.py").read_text(), filename="allocator_list.py"); p=Path(tempfile.mkdtemp())/"a.py"; p.write_text(text); ns=runpy.run_path(str(p)); assert isinstance(ns["managed_entry"](), int); ns=runpy.run_path("pycore/programs/allocator_bytes.py"); assert isinstance(ns["managed_entry"](), int); print("allocator host smoke ok")'

define PYCORE_IMAGE_RUN_SRC
	$(PYTHON) tools/ensure_sim.py img
	mkdir -p $(BUILD_DIR)/$(1)
	$(PYTHON) pycore/tools/run_image_test.py \
		--source pycore/programs/$(2) \
		--entry managed_entry \
		--program-hex $(BUILD_DIR)/$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/$(1)/dmem.hex \
		--meta $(BUILD_DIR)/$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	CODE_RAM_INIT_SLOT=$$(awk -F= '/^CODE_RAM_INIT_SLOT=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" && test -n "$$CODE_RAM_INIT_SLOT" || exit 1; \
	$(PYCORE_SIM_IMG_BIN) \
		+PROG_HEX=$(BUILD_DIR)/$(1)/program.hex \
		+DMEM_HEX=$(BUILD_DIR)/$(1)/dmem.hex \
		+CODE_RAM_HEX=$(BUILD_DIR)/$(1)/code_ram.hex \
		+BOOT_EN=1 \
		+CHECK_ENTRY_RETURN=1 \
		+HEAP_INIT_PTR=$$HEAP_INIT_PTR \
		+CODE_RAM_INIT_SLOT=$$CODE_RAM_INIT_SLOT \
		+EXPECTED_TAG=$$EXPECTED_TAG \
		+EXPECTED_VALUE=$$EXPECTED_VALUE \
		+MAX_CYCLES=$(3) \
		$(PYCORE_MEM_PLUSARGS)
endef

pycore-img-allocator-bytes:
	$(call PYCORE_IMAGE_RUN_SRC,img_allocator_bytes,allocator_bytes.py,400000)

pycore-python-tests:
	PYTHONPATH=pycore/tools:$(PYTHONPATH) $(PYTHON) -m unittest discover -s pycore/tests -p "test_*.py"

pycore-compile-suite: test-compiler-vs-cpython

# compiler_design.md W-8 / A8: ROM, code-RAM package, and heap vs ceilings.
pycore-size-report:
	PYTHONPATH=pycore/tools:$(PYTHONPATH) $(PYTHON) pycore/tools/size_report.py

# ---- Hand-written hardware test recipes -------------------------------------
# Most hardware tests are data (hw_tests.toml). These few need a recipe of
# their own; hw_tests.toml lists them with kind = "make".

# Synthetic §6.1 spike: the generator rewrites the inner zero-arg CALL to
# GET_ITER while preserving CALL's [callable, NULL] RF layout.  The test-only
# core plusarg launches S_CALL from S_CONTAINER and must resume with LIST.
define PYCORE_CONTAINER_CALL_SPIKE_RUN
	$(PYTHON) tools/ensure_sim.py img
	mkdir -p $(BUILD_DIR)/img_container_call_spike
	$(PYTHON) pycore/tools/gen_container_call_spike.py \
		--source pycore/programs/img_container_call_spike.py \
		--program-hex $(BUILD_DIR)/img_container_call_spike/program.hex \
		--dmem-hex $(BUILD_DIR)/img_container_call_spike/dmem.hex \
		--meta $(BUILD_DIR)/img_container_call_spike/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	CODE_RAM_INIT_SLOT=$$(awk -F= '/^CODE_RAM_INIT_SLOT=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" && test -n "$$CODE_RAM_INIT_SLOT" || exit 1; \
	$(PYCORE_SIM_IMG_BIN) \
		+PROG_HEX=$(BUILD_DIR)/img_container_call_spike/program.hex \
		+DMEM_HEX=$(BUILD_DIR)/img_container_call_spike/dmem.hex \
		+CODE_RAM_HEX=$(BUILD_DIR)/img_container_call_spike/code_ram.hex \
		+BOOT_EN=1 \
		+CHECK_ENTRY_RETURN=1 \
		+CONTAINER_CALL_SPIKE_EN=1 \
		+HEAP_INIT_PTR=$$HEAP_INIT_PTR \
		+CODE_RAM_INIT_SLOT=$$CODE_RAM_INIT_SLOT \
		+EXPECTED_TAG=$$EXPECTED_TAG \
		+EXPECTED_VALUE=$$EXPECTED_VALUE \
		+MAX_CYCLES=100000 \
		$(PYCORE_MEM_PLUSARGS)
endef

pycore-img-container-call-spike:
	$(PYCORE_CONTAINER_CALL_SPIKE_RUN)

# ---- Generated fixtures -----------------------------------------------------
# Hand-built hex images for layouts source compilation cannot express. The
# hardware tests that use them list the generator under `needs`.

# Natural FOR_ITER exhaustion skips END_FOR, so this raw stream executes
# END_FOR directly and verifies its POP_TOP-equivalent stack effect.
pycore-for-iter-fixtures:
	$(PYTHON) pycore/tools/gen_for_iter_fixtures.py

# list_append_fast / list_append_full_fatal (Phase A, LIST_APPEND): hand-
# built fixtures with spare-capacity/full-list layouts that source compilation
# cannot express directly. See
# pycore/tools/gen_list_append_fixtures.py for the generator (imem/dmem hex
# outputs are committed fixtures, like the other list_*.hex files).
pycore-list-append-fixtures:
	$(PYTHON) pycore/tools/gen_list_append_fixtures.py

# list_extend_* (LIST_EXTEND): hand-built fixtures — see
# pycore/tools/gen_list_extend_fixtures.py. Non-empty extend always traps
# code 10 without excore (even with spare capacity). Empty source is a
# no-op on pycore. Unsupported iterable tags are TYPE (code 1).
# Functional spare-capacity extend is covered by pycore-excore-extend-fast-no-trap.
pycore-list-extend-fixtures:
	$(PYTHON) pycore/tools/gen_list_extend_fixtures.py

# ---- Phase C: two-core (pycore + excore) system tests ----------------------
# Hand-built images (gen_excore_integration_fixtures.py) exercising the real
# CONT_LIST_APPEND -> S_TRAP_MARSHAL -> trap_mailbox -> excore -> S_TRAP_WAIT
# round trip, driven by genuine LIST_APPEND traps (not a mocked mailbox --
# that's excore-cpu-test / tb_excore.sv, Phase B).
pycore-excore-integration-fixtures:
	$(PYTHON) pycore/tools/gen_excore_integration_fixtures.py

# HEAP_INIT_PTR overridden near PYCORE_HEAP_LIMIT (0xF00000) so the excore's
# doubled buffer (cap 4 -> 8, 256 bytes) cannot fit -> FATAL(MEM_FAULT).
pycore-excore-grow-oom-fatal: excore-fw pycore-excore-integration-fixtures
	$(PYTHON) tools/ensure_sim.py twocore
	$(PYCORE_SIM_TWOCORE_BIN) \
		+PROG_HEX=pycore/programs/grow_oom_fatal.hex \
		+DMEM_HEX=pycore/programs/grow_oom_fatal_dmem.hex \
		+FW_HEX=$(EXCORE_FW_HEX) \
		+BOOT_EN=1 \
		+CHECK_ENTRY_RETURN=0 \
		+HEAP_INIT_PTR=15728512 \
		+EXPECT_TRAP=1 \
		+EXPECTED_TRAP_CODE=7 \
		$(PYCORE_MEM_PLUSARGS)

# excore_disabled: the same image as grow_from_zero, but EXCORE_EN=0 ->
# legacy fatal behavior preserved (trap code 9), proving EXCORE_EN really
# gates the marshal path rather than pycore_trap_recoverable() alone.
pycore-excore-disabled: pycore-excore-integration-fixtures
	$(PYTHON) tools/ensure_sim.py img
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/grow_from_zero.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(PYCORE_SIM_IMG_BIN) \
		+PROG_HEX=pycore/programs/grow_from_zero.hex \
		+DMEM_HEX=pycore/programs/grow_from_zero_dmem.hex \
		+BOOT_EN=1 \
		+CHECK_ENTRY_RETURN=0 \
		+HEAP_INIT_PTR=$$HEAP_INIT_PTR \
		+EXPECT_TRAP=1 \
		+EXPECTED_TRAP_CODE=9 \
		$(PYCORE_MEM_PLUSARGS)

pycore-excore-extend-oom-fatal: excore-fw pycore-excore-integration-fixtures
	$(PYTHON) tools/ensure_sim.py twocore
	$(PYCORE_SIM_TWOCORE_BIN) \
		+PROG_HEX=pycore/programs/extend_oom_fatal.hex \
		+DMEM_HEX=pycore/programs/extend_oom_fatal_dmem.hex \
		+FW_HEX=$(EXCORE_FW_HEX) \
		+BOOT_EN=1 \
		+CHECK_ENTRY_RETURN=0 \
		+HEAP_INIT_PTR=15728512 \
		+EXPECT_TRAP=1 \
		+EXPECTED_TRAP_CODE=7 \
		$(PYCORE_MEM_PLUSARGS)

# Same image as extend_grow_list, but EXCORE_EN=0 → fatal trap code 10.
pycore-excore-extend-disabled: pycore-excore-integration-fixtures
	$(PYTHON) tools/ensure_sim.py img
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/extend_grow_list.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(PYCORE_SIM_IMG_BIN) \
		+PROG_HEX=pycore/programs/extend_grow_list.hex \
		+DMEM_HEX=pycore/programs/extend_grow_list_dmem.hex \
		+BOOT_EN=1 \
		+CHECK_ENTRY_RETURN=0 \
		+HEAP_INIT_PTR=$$HEAP_INIT_PTR \
		+EXPECT_TRAP=1 \
		+EXPECTED_TRAP_CODE=10 \
		$(PYCORE_MEM_PLUSARGS)

# excore-fw: assemble excore firmware as a build step. Generated hex is
# never committed (see excore/tools/asm_rv32.py) — no external toolchain.
$(EXCORE_FW_HEX): $(EXCORE_FW_SRC) excore/tools/asm_rv32.py
	mkdir -p $(dir $@)
	$(PYTHON3) excore/tools/asm_rv32.py $(EXCORE_FW_SRC) -o $@

excore-fw: $(EXCORE_FW_HEX)

excore-asm-tests:
	$(PYTHON3) -m unittest discover -s excore/tests -p "test_*.py"

excore-cpu-test: excore-fw
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore +incdir+excore/rtl \
		--top-module tb_excore \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		--Mdir $(BUILD_DIR)/excore_cpu_test \
		-Wall -Wno-fatal \
		$(EXCORE_RTL_SRCS) excore/tb/tb_excore.sv
	./$(BUILD_DIR)/excore_cpu_test/Vtb_excore

excore-test: excore-asm-tests excore-cpu-test

pycore-rtl-unit: pycore-tag-decode pycore-exec \
	pycore-type-pairs pycore-mem pycore-cache-lru pycore-cache pycore-ram \
	pycore-str-accel pycore-codc pycore-gic pycore-l1d-handoff pycore-mem-nb \
	pycore-fetch pycore-frame pycore-frame-fib pycore-regfile

DOCKER_MAKE = docker run --rm $(DOCKER_RUN_FLAGS) \
	-v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" \
	-w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE)

docker-build:
	docker build $(DOCKER_BUILD_FLAGS) -t $(DOCKER_IMAGE) .

docker-lint-file: docker-build
	docker run --rm $(DOCKER_RUN_FLAGS) -v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" \
		$(DOCKER_IMAGE) make lint-file \
		RUN_SOURCE="$(RUN_SOURCE)" \
		RUN_FUNCTION="$(RUN_FUNCTION)"

docker-run-file: docker-build
	$(DOCKER_MAKE) make run-file \
		RUN_SOURCE="$(RUN_SOURCE)" \
		RUN_FUNCTION="$(RUN_FUNCTION)" \
		HOST_COMPILE="$(HOST_COMPILE)" \
		RUN_MAX_CYCLES="$(RUN_MAX_CYCLES)" \
		RUN_BUILD_DIR="$(RUN_BUILD_DIR)" \
		EXEC_ARGS="$(EXEC_ARGS)"

docker-exec-file: docker-build
	$(DOCKER_MAKE) make exec-file \
		RUN_SOURCE="$(RUN_SOURCE)" \
		EXEC_ARGS="$(EXEC_ARGS)"

docker-shell: docker-build
	docker run --rm -it $(DOCKER_RUN_FLAGS) \
		-v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" \
		-w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make shell EXEC_ARGS="$(EXEC_ARGS)"

docker-all-tests: docker-build
	$(DOCKER_MAKE) make test-all TEST_JOBS=$(TEST_JOBS)

# `make docker-test-alu` runs `make test-alu` in the image. CI uses these.
docker-test-%: docker-build
	$(DOCKER_MAKE) make test-$* TEST_JOBS=$(TEST_JOBS)

# Nightly GC fuzzing (.github/workflows/gc-nightly.yml): SEEDS and TOP as for
# pycore-gc-fuzz.
docker-pycore-gc-fuzz: docker-build
	$(DOCKER_MAKE) make pycore-gc-fuzz SEEDS=$(SEEDS) TOP=$(TOP) TEST_JOBS=$(TEST_JOBS)

clean:
	rm -rf $(BUILD_DIR)

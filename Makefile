VERILATOR ?= verilator
PYTHON ?= python3.14
# excore tooling is plain Python 3 (not CPython-3.14-coupled — RV32I
# encodings come from the ISA spec, not from probing a running interpreter).
PYTHON3 ?= python3
BUILD_DIR ?= build
DOCKER_IMAGE ?= python-cpu-sim
DOCKER_CONTAINER_WORKDIR ?= /work
DOCKER_BUILD_FLAGS ?=
DOCKER_RUN_FLAGS ?=

PYCORE_SOURCE ?= pycore/programs/smoke_return.py
PYCORE_FUNCTION ?= managed_entry
PYCORE_PROGRAM_HEX ?= pycore/programs/program.hex
PYCORE_STRING_HEX ?= pycore/programs/string_mem.hex
PYCORE_TYPES ?= pycore/programs/program.types
PYCORE_CACHE_MAP ?= pycore/programs/cache_map.hex

RUN_SOURCE ?= pycore/programs/smoke_return.py
RUN_FUNCTION ?= managed_entry
RUN_PROGRAM_HEX ?= pycore/programs/run_program.hex
RUN_STRING_HEX ?= pycore/programs/run_string_mem.hex
RUN_TYPES ?= pycore/programs/run_program.types
RUN_CACHE_MAP ?= pycore/programs/run_cache_map.hex
RUN_MAX_CYCLES ?= 2000

PYCORE_RTL_SRCS := \
	pycore/rtl/pycore_tag_decode.sv \
	pycore/rtl/pycore_promote.sv \
	pycore/rtl/pycore_int_alu.sv \
	pycore/rtl/pycore_mul.sv \
	pycore/rtl/pycore_div.sv \
	pycore/rtl/pycore_fpu.sv \
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
	pycore/rtl/pycore_dmem.sv \
	pycore/rtl/pycore_mem_stage.sv \
	pycore/rtl/pycore_core.sv \
	pycore/rtl/pycore_system.sv \
	excore/rtl/excore_cpu.sv \
	excore/rtl/excore_mmio.sv \
	excore/rtl/trap_mailbox.sv \
	pycore/rtl/pycore_excore_system.sv

PYCORE_MEM_SRCS := \
	pycore/rtl/pycore_mem_block.sv \
	pycore/rtl/pycore_mem_bank.sv

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

.PHONY: pycore-preprocess run-file pycore-run-file all-tests pycore-test \
	pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs \
	pycore-python-tests pycore-mem pycore-frame pycore-frame-fib \
	pycore-top pycore-multifn \
	pycore-img pycore-img-smoke pycore-img-call-chain pycore-img-str-consts \
	pycore-img-containers pycore-img-recursion pycore-img-extended-arg \
	pycore-img-branchy pycore-img-undef-global pycore-img-noncallable \
	pycore-img-bad-argc pycore-img-deep-callgraph pycore-img-helper-containers \
	pycore-img-algo-sort pycore-img-bitwise-calls pycore-img-globals-accum \
	pycore-img-string-ops pycore-img-copy pycore-img-swap \
	pycore-img-delete-fast pycore-img-delete-fast-unbound \
	pycore-img-store-fast-load-fast pycore-img-load-fast-load-fast \
	pycore-img-load-fast-borrow-load-fast-borrow \
	pycore-img-load-fast-and-clear pycore-img-load-fast-and-clear-cleared \
	pycore-img-load-fast-check pycore-img-load-fast-check-unbound \
	pycore-img-to-bool pycore-img-to-bool-type-trap \
	pycore-img-to-bool-str-trap pycore-img-to-bool-list-trap \
	pycore-img-unary-not \
	pycore-img-is-op \
	pycore-img-pop-jump-if-none \
	pycore-img-nop \
	pycore-container pycore-container-build-index pycore-container-store-subscr \
	pycore-container-dict-lookup pycore-container-dict-store \
	pycore-container-list-empty pycore-container-dict-multi-pair \
	pycore-container-dict-collision pycore-container-dict-insert-new-key \
	pycore-container-dict-empty pycore-container-list-nested \
	pycore-container-tuple-index pycore-container-tuple-empty \
	pycore-container-list-oob-read pycore-container-list-oob-write \
	pycore-container-dict-missing-key pycore-container-tuple-store-trap \
	pycore-container-dict-full-insert pycore-container-list-oom \
	pycore-container-list-append-fast pycore-container-list-append-full-fatal \
	pycore-list-append-fixtures \
	pycore-container-list-extend-fast pycore-container-list-extend-fast-tuple \
	pycore-container-list-extend-empty \
	pycore-container-list-extend-full-fatal pycore-container-list-extend-type-fatal \
	pycore-list-extend-fixtures \
	pycore-excore-integration-fixtures pycore-excore-grow-from-zero \
	pycore-excore-fast-path-no-trap pycore-excore-grow-oom-fatal \
	pycore-excore-alias-stability pycore-excore-mixed-tags-preserved \
	pycore-excore-grow-repeated pycore-excore-append-across-call \
	pycore-excore-disabled \
	pycore-excore-extend-grow-list pycore-excore-extend-grow-tuple \
	pycore-excore-extend-fast-no-trap pycore-excore-extend-empty-noop \
	pycore-excore-extend-self pycore-excore-extend-mixed-tags \
	pycore-excore-extend-grow-to-fit pycore-excore-extend-oom-fatal \
	pycore-excore-extend-across-call pycore-excore-extend-disabled \
	pycore-excore-system \
	pycore-img-list-extend-two-core \
	pycore-img-list-del-simple pycore-img-list-del-first-last \
	pycore-img-list-contains-simple pycore-img-list-contains-types \
	pycore-img-tuple-contains pycore-img-dict-contains \
	pycore-img-list-del-contains pycore-img-list-del-nested \
	pycore-img-list-del-contains-call pycore-img-list-extend-del-contains-two-core \
	pycore-img-list-del-oob pycore-img-list-del-tuple-trap \
	pycore-img-dict-del-trap \
	pycore-img-dict-store-lookup pycore-img-dict-overwrite \
	pycore-img-dict-del-simple pycore-img-dict-del-then-insert \
	pycore-img-dict-hash-neg1 pycore-img-dict-str-keys \
	pycore-img-dict-large-pycore pycore-img-dict-grow-fatal \
	pycore-img-dict-bool-int-collision pycore-img-dict-false-zero \
	pycore-img-dict-grow-basic pycore-img-dict-grow-large \
	pycore-img-dict-del-collision pycore-img-dict-contains-collision \
	pycore-img-dict-mixed-ops \
	pycore-img-set-build-simple pycore-img-set-add-contains \
	pycore-img-set-bool-int pycore-img-set-hash-neg1 pycore-img-set-str \
	pycore-img-set-grow-fatal pycore-img-set-grow-basic pycore-img-set-update \
	pycore-img-two-core \
	excore-fw excore-asm-tests excore-cpu-test excore-test clean \
	docker-build docker-run-file docker-pycore-test docker-all-tests

pycore-preprocess:
	$(PYTHON) pycore/tools/preprocess.py \
		--source "$(PYCORE_SOURCE)" \
		--function "$(PYCORE_FUNCTION)" \
		--program-hex "$(PYCORE_PROGRAM_HEX)" \
		--string-hex "$(PYCORE_STRING_HEX)" \
		--types "$(PYCORE_TYPES)" \
		--cache-map "$(PYCORE_CACHE_MAP)"

run-file: pycore-run-file

pycore-run-file:
	$(PYTHON) pycore/tools/preprocess.py \
		--source "$(RUN_SOURCE)" \
		--function "$(RUN_FUNCTION)" \
		--program-hex "$(RUN_PROGRAM_HEX)" \
		--string-hex "$(RUN_STRING_HEX)" \
		--types "$(RUN_TYPES)" \
		--cache-map "$(RUN_CACHE_MAP)"
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_pycore_runfile \
		-GPROG_HEX=\"$(RUN_PROGRAM_HEX)\" \
		-GSTRING_HEX=\"$(RUN_STRING_HEX)\" \
		-GMAX_CYCLES=$(RUN_MAX_CYCLES) \
		--Mdir $(BUILD_DIR)/pycore_runfile \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_pycore_runfile.sv
	./$(BUILD_DIR)/pycore_runfile/Vtb_pycore_runfile
	$(PYTHON) tools/dump_hex.py --path "$(RUN_PROGRAM_HEX)" --label "Program memory image"
	$(PYTHON) tools/dump_hex.py --path "$(RUN_STRING_HEX)" --label "String memory image"
	@echo "Type sketch file: $(RUN_TYPES)"
	@echo "Cache map file: $(RUN_CACHE_MAP)"

all-tests: pycore-test excore-test

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
		pycore/rtl/pycore_exec.sv \
		pycore/tb/tb_exec.sv
	./$(BUILD_DIR)/pycore_exec/Vtb_exec

pycore-string-exec:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_string_exec \
		--Mdir $(BUILD_DIR)/pycore_string_exec \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_tag_decode.sv \
		pycore/rtl/pycore_promote.sv \
		pycore/rtl/pycore_int_alu.sv \
		pycore/rtl/pycore_mul.sv \
		pycore/rtl/pycore_div.sv \
		pycore/rtl/pycore_fpu.sv \
		pycore/rtl/pycore_exec.sv \
		pycore/tb/tb_string_exec.sv
	./$(BUILD_DIR)/pycore_string_exec/Vtb_string_exec

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

pycore-python-tests:
	PYTHONPATH=pycore/tools:$(PYTHONPATH) $(PYTHON) -m unittest discover -s pycore/tests -p "test_*.py"

pycore-top:
	@echo "tb_pycore relies on the pre-3.14 inline 3-slot LOAD_CONST datapath."
	@echo "End-to-end pipeline coverage is now provided by tb_container BOOT_EN=1"
	@echo "with image-boot programs (img_smoke.py, img_call_chain.py, etc.)."

# The old multifn hex fixtures used the pre-3.14 CALL encoding (opcode
# 0xab with {argc, slot} arg) and the deprecated inline 3-slot LOAD_CONST
# format.  Both are incompatible with the CPython 3.14.6 image-boot
# datapath (single-slot LOAD_CONST that indexes co_consts, and raw-argc
# CALL that reads a CODE_OBJECT off the RF).  Multi-function coverage
# is now provided by image-boot programs (see img_call_chain.py,
# img_recursion.py, img_smoke.py) run through tb_container with
# BOOT_EN=1 and CHECK_ENTRY_RETURN=1.

pycore-multifn:
	@echo "Legacy multifn targets removed; use image-boot img_* programs instead."

# ---- CPython image-boot differential tests ---------------------------------
# Positive tests use run_image_test.py so EXPECTED_TAG / EXPECTED_VALUE are
# derived from host CPython execution and then checked in hardware. Negative
# tests use image_from_source.py directly because host execution intentionally
# raises before a valid entry return exists.

define PYCORE_IMAGE_RUN
	mkdir -p $(BUILD_DIR)/img_$(1)
	$(PYTHON) pycore/tools/run_image_test.py \
		--source pycore/programs/img_$(1).py \
		--entry managed_entry \
		--program-hex $(BUILD_DIR)/img_$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/img_$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/img_$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/img_$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/img_$(1)/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/img_$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/img_$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=1 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d$$EXPECTED_TAG \
		"-GEXPECTED_VALUE=128'd$$EXPECTED_VALUE" \
		-GMAX_CYCLES=$(2) \
		--Mdir $(BUILD_DIR)/img_$(1)/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/img_$(1)/verilator/Vtb_container
endef

# Phase C full-regression companion to PYCORE_IMAGE_RUN: same image, run on
# the two-core top (EXCORE_EN=1) instead of the legacy pycore_system. Most
# img_* programs never emit LIST_APPEND/LIST_EXTEND grow traps (LIST_APPEND
# still needs FOR_ITER/GET_ITER; LIST_EXTEND is covered by
# img_list_extend.py on the two-core path only).
define PYCORE_IMAGE_RUN_TWOCORE
	mkdir -p $(BUILD_DIR)/img_$(1)
	$(PYTHON) pycore/tools/run_image_test.py \
		--source pycore/programs/img_$(1).py \
		--entry managed_entry \
		--program-hex $(BUILD_DIR)/img_$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/img_$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/img_$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/img_$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/img_$(1)/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/img_$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/img_$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=1 \
		-GEXCORE_EN=1 \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d$$EXPECTED_TAG \
		"-GEXPECTED_VALUE=128'd$$EXPECTED_VALUE" \
		-GMAX_CYCLES=$(2) \
		--Mdir $(BUILD_DIR)/img_$(1)/verilator_twocore \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/img_$(1)/verilator_twocore/Vtb_container
endef

define PYCORE_IMAGE_TRAP_RUN
	mkdir -p $(BUILD_DIR)/img_$(1)
	$(PYTHON) pycore/tools/image_from_source.py \
		--source pycore/programs/img_$(1).py \
		--program-hex $(BUILD_DIR)/img_$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/img_$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/img_$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/img_$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/img_$(1)/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/img_$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/img_$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXPECT_TRAP=1 \
		-GEXPECTED_TRAP_CODE=4\'d$(2) \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GMAX_CYCLES=$(3) \
		--Mdir $(BUILD_DIR)/img_$(1)/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/img_$(1)/verilator/Vtb_container
endef

pycore-img-smoke:
	$(call PYCORE_IMAGE_RUN,smoke,50000)

pycore-img-call-chain:
	$(call PYCORE_IMAGE_RUN,call_chain,50000)

pycore-img-str-consts:
	$(call PYCORE_IMAGE_RUN,str_consts,50000)

pycore-img-containers:
	$(call PYCORE_IMAGE_RUN,containers,50000)

pycore-img-recursion:
	$(call PYCORE_IMAGE_RUN,recursion,100000)

pycore-img-extended-arg:
	$(call PYCORE_IMAGE_RUN,extended_arg,200000)

pycore-img-branchy:
	$(call PYCORE_IMAGE_RUN,branchy,50000)

pycore-img-undef-global:
	$(call PYCORE_IMAGE_TRAP_RUN,undef_global,7,50000)

pycore-img-noncallable:
	$(call PYCORE_IMAGE_TRAP_RUN,noncallable,6,50000)

pycore-img-bad-argc:
	$(call PYCORE_IMAGE_TRAP_RUN,bad_argc,6,50000)

pycore-img-deep-callgraph:
	$(call PYCORE_IMAGE_RUN,deep_callgraph,400000)

pycore-img-helper-containers:
	$(call PYCORE_IMAGE_RUN,helper_containers,100000)

pycore-img-algo-sort:
	$(call PYCORE_IMAGE_RUN,algo_sort,200000)

pycore-img-bitwise-calls:
	$(call PYCORE_IMAGE_RUN,bitwise_calls,100000)

pycore-img-globals-accum:
	$(call PYCORE_IMAGE_RUN,globals_accum,100000)

pycore-img-string-ops:
	$(call PYCORE_IMAGE_RUN,string_ops,100000)

pycore-img-string-ops:
	$(call PYCORE_IMAGE_RUN,string_ops,100000)

pycore-img-copy:
	$(call PYCORE_IMAGE_RUN,copy,50000)

pycore-img-swap:
	$(call PYCORE_IMAGE_RUN,swap,50000)

pycore-img-delete-fast:
	$(call PYCORE_IMAGE_RUN,delete_fast,50000)

pycore-img-delete-fast-unbound:
	$(call PYCORE_IMAGE_TRAP_RUN,delete_fast_unbound,7,50000)

pycore-img-store-fast-load-fast:
	$(call PYCORE_IMAGE_RUN,store_fast_load_fast,50000)

pycore-img-load-fast-load-fast:
	$(call PYCORE_IMAGE_RUN,load_fast_load_fast,50000)

pycore-img-load-fast-borrow-load-fast-borrow:
	$(call PYCORE_IMAGE_RUN,load_fast_borrow_load_fast_borrow,50000)

pycore-img-load-fast-and-clear:
	$(call PYCORE_IMAGE_RUN,load_fast_and_clear,50000)

pycore-img-load-fast-and-clear-cleared:
	$(call PYCORE_IMAGE_TRAP_RUN,load_fast_and_clear_cleared,7,50000)

pycore-img-load-fast-check:
	$(call PYCORE_IMAGE_RUN,load_fast_check,50000)

pycore-img-load-fast-check-unbound:
	$(call PYCORE_IMAGE_TRAP_RUN,load_fast_check_unbound,7,50000)

pycore-img-to-bool:
	$(call PYCORE_IMAGE_RUN,to_bool,50000)

pycore-img-to-bool-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,to_bool_type_trap,1,50000)

pycore-img-to-bool-str-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,to_bool_str_trap,1,50000)

pycore-img-to-bool-list-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,to_bool_list_trap,1,50000)

pycore-img-unary-not:
	$(call PYCORE_IMAGE_RUN,unary_not,50000)

pycore-img-is-op:
	$(call PYCORE_IMAGE_RUN,is_op,50000)

pycore-img-pop-jump-if-none:
	$(call PYCORE_IMAGE_RUN,pop_jump_if_none,50000)

pycore-img-nop:
	$(call PYCORE_IMAGE_RUN,nop,50000)

# DELETE_SUBSCR / CONTAINS_OP (list shift-down + membership; raw Python imgs)
pycore-img-list-del-simple:
	$(call PYCORE_IMAGE_RUN,list_del_simple,50000)

pycore-img-list-del-first-last:
	$(call PYCORE_IMAGE_RUN,list_del_first_last,50000)

pycore-img-list-contains-simple:
	$(call PYCORE_IMAGE_RUN,list_contains_simple,50000)

pycore-img-list-contains-types:
	$(call PYCORE_IMAGE_RUN,list_contains_types,50000)

pycore-img-tuple-contains:
	$(call PYCORE_IMAGE_RUN,tuple_contains,50000)

pycore-img-dict-contains:
	$(call PYCORE_IMAGE_RUN,dict_contains,50000)

pycore-img-list-del-contains:
	$(call PYCORE_IMAGE_RUN,list_del_contains,50000)

pycore-img-list-del-nested:
	$(call PYCORE_IMAGE_RUN,list_del_nested,50000)

pycore-img-list-del-contains-call:
	$(call PYCORE_IMAGE_RUN,list_del_contains_call,100000)

pycore-img-list-del-oob:
	$(call PYCORE_IMAGE_TRAP_RUN,list_del_oob,7,50000)

pycore-img-list-del-tuple-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,list_del_tuple_trap,1,50000)

pycore-img-dict-del-trap:
	# Same-tag dict delete is on-pycore (tombstone); no TYPE trap.
	$(call PYCORE_IMAGE_RUN,dict_del_trap,50000)

# Dict same-tag paths (single-core; no DICT_GROW / DICT_COLLISION).
pycore-img-dict-store-lookup:
	$(call PYCORE_IMAGE_RUN,dict_store_lookup,50000)

pycore-img-dict-overwrite:
	$(call PYCORE_IMAGE_RUN,dict_overwrite,50000)

pycore-img-dict-del-simple:
	$(call PYCORE_IMAGE_RUN,dict_del_simple,50000)

pycore-img-dict-del-then-insert:
	$(call PYCORE_IMAGE_RUN,dict_del_then_insert,50000)

pycore-img-dict-hash-neg1:
	$(call PYCORE_IMAGE_RUN,dict_hash_neg1,50000)

pycore-img-dict-str-keys:
	$(call PYCORE_IMAGE_RUN,dict_str_keys,50000)

pycore-img-dict-large-pycore:
	$(call PYCORE_IMAGE_RUN,dict_large_pycore,100000)

# Empty dict + 4th new-key insert → fatal DICT_GROW without excore.
pycore-img-dict-grow-fatal:
	$(call PYCORE_IMAGE_TRAP_RUN,dict_grow_fatal,11,50000)

# Cross-tag dict rich_eq now on pycore (single-core).
pycore-img-dict-bool-int-collision:
	$(call PYCORE_IMAGE_RUN,dict_bool_int_collision,100000)

pycore-img-dict-false-zero:
	$(call PYCORE_IMAGE_RUN,dict_false_zero,100000)

pycore-img-dict-del-collision:
	$(call PYCORE_IMAGE_RUN,dict_del_collision,100000)

pycore-img-dict-contains-collision:
	$(call PYCORE_IMAGE_RUN,dict_contains_collision,100000)

# Dict grow still needs excore (two-core).
pycore-img-dict-grow-basic: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,dict_grow_basic,100000)

pycore-img-dict-grow-large: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,dict_grow_large,200000)

pycore-img-dict-mixed-ops: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,dict_mixed_ops,200000)

# ---- Set tests -------------------------------------------------------------
pycore-img-set-build-simple:
	$(call PYCORE_IMAGE_RUN,set_build_simple,50000)

pycore-img-set-add-contains:
	$(call PYCORE_IMAGE_RUN,set_add_contains,50000)

pycore-img-set-bool-int:
	$(call PYCORE_IMAGE_RUN,set_bool_int,50000)

pycore-img-set-hash-neg1:
	$(call PYCORE_IMAGE_RUN,set_hash_neg1,50000)

pycore-img-set-str:
	$(call PYCORE_IMAGE_RUN,set_str,50000)

pycore-img-set-grow-fatal:
	$(call PYCORE_IMAGE_TRAP_RUN,set_grow_fatal,13,50000)

pycore-img-set-grow-basic: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,set_grow_basic,100000)

pycore-img-set-update: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,set_update,100000)

# Extend (excore grow) then delete/contains — two-core only.
pycore-img-list-extend-del-contains-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_extend_del_contains,100000)

define PYCORE_IMAGE_TRAP_RUN_TWOCORE
	mkdir -p $(BUILD_DIR)/img_$(1)
	$(PYTHON) pycore/tools/image_from_source.py \
		--source pycore/programs/img_$(1).py \
		--program-hex $(BUILD_DIR)/img_$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/img_$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/img_$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/img_$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/img_$(1)/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/img_$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/img_$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXCORE_EN=1 \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		-GEXPECT_TRAP=1 \
		-GEXPECTED_TRAP_CODE=4\'d$(2) \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GMAX_CYCLES=$(3) \
		--Mdir $(BUILD_DIR)/img_$(1)/verilator_twocore \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/img_$(1)/verilator_twocore/Vtb_container
endef

pycore-img-smoke-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,smoke,50000)

pycore-img-call-chain-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,call_chain,50000)

pycore-img-str-consts-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,str_consts,50000)

pycore-img-containers-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,containers,50000)

pycore-img-recursion-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,recursion,100000)

pycore-img-extended-arg-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,extended_arg,200000)

pycore-img-branchy-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,branchy,50000)

pycore-img-undef-global-two-core: excore-fw
	$(call PYCORE_IMAGE_TRAP_RUN_TWOCORE,undef_global,7,50000)

pycore-img-noncallable-two-core: excore-fw
	$(call PYCORE_IMAGE_TRAP_RUN_TWOCORE,noncallable,6,50000)

pycore-img-bad-argc-two-core: excore-fw
	$(call PYCORE_IMAGE_TRAP_RUN_TWOCORE,bad_argc,6,50000)

pycore-img-deep-callgraph-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,deep_callgraph,400000)

pycore-img-helper-containers-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,helper_containers,100000)

pycore-img-algo-sort-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,algo_sort,200000)

pycore-img-bitwise-calls-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,bitwise_calls,100000)

pycore-img-globals-accum-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,globals_accum,100000)

pycore-img-string-ops-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,string_ops,100000)

# LIST_EXTEND via compile() list-display unpack (`[1,2,*x]`, `[*a,*b]`).
# Always hits the grow path (BUILD_LIST allocates cap==len), so this is
# two-core only.
pycore-img-list-extend-two-core: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_extend,100000)

pycore-img-two-core: \
	pycore-img-smoke-two-core \
	pycore-img-call-chain-two-core \
	pycore-img-str-consts-two-core \
	pycore-img-containers-two-core \
	pycore-img-recursion-two-core \
	pycore-img-extended-arg-two-core \
	pycore-img-branchy-two-core \
	pycore-img-undef-global-two-core \
	pycore-img-noncallable-two-core \
	pycore-img-bad-argc-two-core \
	pycore-img-deep-callgraph-two-core \
	pycore-img-helper-containers-two-core \
	pycore-img-algo-sort-two-core \
	pycore-img-bitwise-calls-two-core \
	pycore-img-globals-accum-two-core \
	pycore-img-string-ops-two-core \
	pycore-img-list-extend-two-core \
	pycore-img-list-extend-del-contains-two-core \
	pycore-img-dict-grow-basic \
	pycore-img-dict-grow-large \
	pycore-img-dict-mixed-ops \
	pycore-img-set-grow-basic \
	pycore-img-set-update

pycore-img: \
	pycore-img-smoke \
	pycore-img-call-chain \
	pycore-img-str-consts \
	pycore-img-containers \
	pycore-img-recursion \
	pycore-img-extended-arg \
	pycore-img-branchy \
	pycore-img-undef-global \
	pycore-img-noncallable \
	pycore-img-bad-argc \
	pycore-img-deep-callgraph \
	pycore-img-helper-containers \
	pycore-img-algo-sort \
	pycore-img-bitwise-calls \
	pycore-img-globals-accum \
	pycore-img-string-ops \
	pycore-img-copy \
	pycore-img-swap \
	pycore-img-delete-fast \
	pycore-img-delete-fast-unbound \
	pycore-img-store-fast-load-fast \
	pycore-img-load-fast-load-fast \
	pycore-img-load-fast-borrow-load-fast-borrow \
	pycore-img-load-fast-and-clear \
	pycore-img-load-fast-and-clear-cleared \
	pycore-img-load-fast-check \
	pycore-img-load-fast-check-unbound \
	pycore-img-to-bool \
	pycore-img-to-bool-type-trap \
	pycore-img-to-bool-str-trap \
	pycore-img-to-bool-list-trap \
	pycore-img-unary-not \
	pycore-img-is-op \
	pycore-img-pop-jump-if-none \
	pycore-img-nop \
	pycore-img-list-del-simple \
	pycore-img-list-del-first-last \
	pycore-img-list-contains-simple \
	pycore-img-list-contains-types \
	pycore-img-tuple-contains \
	pycore-img-dict-contains \
	pycore-img-list-del-contains \
	pycore-img-list-del-nested \
	pycore-img-list-del-contains-call \
	pycore-img-list-del-oob \
	pycore-img-list-del-tuple-trap \
	pycore-img-dict-del-trap \
	pycore-img-dict-store-lookup \
	pycore-img-dict-overwrite \
	pycore-img-dict-del-simple \
	pycore-img-dict-del-then-insert \
	pycore-img-dict-hash-neg1 \
	pycore-img-dict-str-keys \
	pycore-img-dict-large-pycore \
	pycore-img-dict-grow-fatal \
	pycore-img-dict-bool-int-collision \
	pycore-img-dict-false-zero \
	pycore-img-dict-del-collision \
	pycore-img-dict-contains-collision \
	pycore-img-set-build-simple \
	pycore-img-set-add-contains \
	pycore-img-set-bool-int \
	pycore-img-set-hash-neg1 \
	pycore-img-set-str \
	pycore-img-set-grow-fatal

# ---- Container (list/dict/tuple) tests -------------------------------------
# tb_container is parameterized: PROG_HEX selects the program, EXPECTED_TAG /
# EXPECTED_VALUE specify the expected base-frame return. EXPECT_TRAP /
# EXPECTED_TRAP_CODE cover negative cases.

define PYCORE_CONTAINER_RUN
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(1)\" \
		$(2) \
		--Mdir $(BUILD_DIR)/$(3) \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/$(3)/Vtb_container
endef

pycore-container-build-index:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_build_index.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d99",pycore_container_build_index)

pycore-container-store-subscr:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_store_subscr.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d42",pycore_container_store_subscr)

pycore-container-dict-lookup:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_build_lookup.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d42",pycore_container_dict_lookup)

pycore-container-dict-store:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_store_subscr.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d99",pycore_container_dict_store)

pycore-container-list-empty:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_empty.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d1" -GSTRING_HEX=\"pycore/programs/list_empty_str.hex\",pycore_container_list_empty)

pycore-container-dict-multi-pair:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_multi_pair.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d100" -GSTRING_HEX=\"pycore/programs/dict_multi_pair_str.hex\",pycore_container_dict_multi_pair)

pycore-container-dict-collision:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_collision.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d30" -GSTRING_HEX=\"pycore/programs/dict_collision_str.hex\",pycore_container_dict_collision)

pycore-container-dict-insert-new-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_insert_new_key.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d20" -GSTRING_HEX=\"pycore/programs/dict_insert_new_key_str.hex\",pycore_container_dict_insert_new_key)

# pycore-container-dict-bool-key / dict-str-key / dict-str-key-long removed:
# their hex fixtures still use the pre-3.14 inline 3-slot LOAD_CONST
# encoding.  Equivalent coverage is provided by image-boot programs
# under img_str_consts.py and img_containers.py.

pycore-container-dict-empty:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_empty.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d2" -GSTRING_HEX=\"pycore/programs/dict_empty_str.hex\",pycore_container_dict_empty)

pycore-container-list-nested:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_nested.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d7" -GSTRING_HEX=\"pycore/programs/list_nested_str.hex\",pycore_container_list_nested)

pycore-container-tuple-index:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_index.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d40" -GSTRING_HEX=\"pycore/programs/tuple_index_str.hex\",pycore_container_tuple_index)

pycore-container-tuple-empty:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_empty.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d9" -GSTRING_HEX=\"pycore/programs/tuple_empty_str.hex\",pycore_container_tuple_empty)

# pycore-container-across-call removed: its hex fixture uses the pre-3.14
# CALL encoding.  Replacement coverage lives in img_call_chain / image
# boot programs run through tb_container with BOOT_EN=1.

pycore-container-list-oob-read:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oob_read.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oob_read_str.hex\",pycore_container_list_oob_read)

pycore-container-list-oob-write:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oob_write.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oob_write_str.hex\",pycore_container_list_oob_write)

pycore-container-dict-missing-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_missing_key.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/dict_missing_key_str.hex\",pycore_container_dict_missing_key)

# pycore-container-list-float-key removed: hex uses pre-3.14 inline
# 3-slot LOAD_CONST for the float key.  Equivalent type-trap coverage
# is available through image-boot fixtures.

pycore-container-tuple-store-trap:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_store_trap.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d1 -GSTRING_HEX=\"pycore/programs/tuple_store_trap_str.hex\",pycore_container_tuple_store_trap)

pycore-container-dict-full-insert:
	# Load ≥ 2/3 / last-slot insert → PY_TRAP_DICT_GROW (11), not MEM_FAULT.
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_full_insert.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d11 -GSTRING_HEX=\"pycore/programs/dict_full_insert_str.hex\" -GMAX_CYCLES=20000,pycore_container_dict_full_insert)

# HEAP_INIT_PTR = 0x1F9C so BUILD_LIST 3 (112 bytes) exceeds PYCORE_HEAP_LIMIT.
pycore-container-list-oom:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oom.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oom_str.hex\" "-GHEAP_INIT_PTR=32\'h00001f9c",pycore_container_list_oom)

# list_append_fast / list_append_full_fatal (Phase A, LIST_APPEND): hand-
# built fixtures — compile() can only emit LIST_APPEND inside comprehensions,
# which still require unimplemented FOR_ITER/GET_ITER, so these cannot go
# through preprocess.py / image_from_source.py.  See
# pycore/tools/gen_list_append_fixtures.py for the generator (imem/dmem hex
# outputs are committed fixtures, like the other list_*.hex files).
pycore-list-append-fixtures:
	$(PYTHON) pycore/tools/gen_list_append_fixtures.py

# list_append_fast: [7] with hand-set capacity 4 (BUILD_LIST alone can never
# produce spare capacity); appends 8 and 9 via the fast path (no trap),
# subscripts both back, returns their sum (17).
pycore-container-list-append-fast:
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/list_append_fast.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	mkdir -p $(BUILD_DIR); \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/list_append_fast.hex\" \
		-GSTRING_HEX=\"pycore/programs/list_append_fast_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/list_append_fast_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd17" \
		--Mdir $(BUILD_DIR)/pycore_container_list_append_fast \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/pycore_container_list_append_fast/Vtb_container

# list_append_full_fatal: BUILD_LIST 1 (capacity==length==1, exactly full)
# then one LIST_APPEND -> PY_TRAP_LIST_GROW (trap code 9). Phase A has no
# excore, so this is fatal.
pycore-container-list-append-full-fatal:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_append_full_fatal.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d9 -GSTRING_HEX=\"pycore/programs/list_append_full_fatal_str.hex\",pycore_container_list_append_full_fatal)

# list_extend_* (LIST_EXTEND): hand-built fixtures — see
# pycore/tools/gen_list_extend_fixtures.py. Fast-path cases need spare
# capacity (BUILD_LIST never produces it). Grow-without-excore is fatal
# trap code 10; unsupported iterable tags are TYPE (code 1).
pycore-list-extend-fixtures:
	$(PYTHON) pycore/tools/gen_list_extend_fixtures.py

pycore-container-list-extend-fast:
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/list_extend_fast.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	mkdir -p $(BUILD_DIR); \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/list_extend_fast.hex\" \
		-GSTRING_HEX=\"pycore/programs/list_extend_fast_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/list_extend_fast_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd19" \
		--Mdir $(BUILD_DIR)/pycore_container_list_extend_fast \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/pycore_container_list_extend_fast/Vtb_container

pycore-container-list-extend-fast-tuple:
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/list_extend_fast_tuple.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	mkdir -p $(BUILD_DIR); \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/list_extend_fast_tuple.hex\" \
		-GSTRING_HEX=\"pycore/programs/list_extend_fast_tuple_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/list_extend_fast_tuple_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd23" \
		--Mdir $(BUILD_DIR)/pycore_container_list_extend_fast_tuple \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/pycore_container_list_extend_fast_tuple/Vtb_container

pycore-container-list-extend-empty:
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/list_extend_empty.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	mkdir -p $(BUILD_DIR); \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/list_extend_empty.hex\" \
		-GSTRING_HEX=\"pycore/programs/list_extend_empty_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/list_extend_empty_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd42" \
		--Mdir $(BUILD_DIR)/pycore_container_list_extend_empty \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/pycore_container_list_extend_empty/Vtb_container

pycore-container-list-extend-full-fatal:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_extend_full_fatal.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d10 -GSTRING_HEX=\"pycore/programs/list_extend_full_fatal_str.hex\",pycore_container_list_extend_full_fatal)

pycore-container-list-extend-type-fatal:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_extend_type_fatal.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d1 -GSTRING_HEX=\"pycore/programs/list_extend_type_fatal_str.hex\",pycore_container_list_extend_type_fatal)

# ---- Phase C: two-core (pycore + excore) system tests ----------------------
# Hand-built images (gen_excore_integration_fixtures.py) exercising the real
# CONT_LIST_APPEND -> S_TRAP_MARSHAL -> trap_mailbox -> excore -> S_TRAP_WAIT
# round trip, driven by genuine LIST_APPEND traps (not a mocked mailbox --
# that's excore-cpu-test / tb_excore.sv, Phase B).
pycore-excore-integration-fixtures:
	$(PYTHON) pycore/tools/gen_excore_integration_fixtures.py

define PYCORE_EXCORE_RUN
	mkdir -p $(BUILD_DIR)/$(1)
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/$(1).meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/$(1).hex\" \
		-GSTRING_HEX=\"pycore/programs/$(1)_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/$(1)_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXCORE_EN=1 \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		$(2) \
		--Mdir $(BUILD_DIR)/$(1)/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/$(1)/verilator/Vtb_container
endef

pycore-excore-grow-from-zero: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,grow_from_zero,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd55" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=20000)

pycore-excore-fast-path-no-trap: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,fast_path_no_trap,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd9" -GEXPECTED_TRAP_REQ_COUNT=0)

# HEAP_INIT_PTR overridden near PYCORE_HEAP_LIMIT (0x2000) so the excore's
# doubled buffer (cap 4 -> 8, 256 bytes) cannot fit -> FATAL(MEM_FAULT).
pycore-excore-grow-oom-fatal: excore-fw pycore-excore-integration-fixtures
	mkdir -p $(BUILD_DIR)/grow_oom_fatal
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/grow_oom_fatal.hex\" \
		-GSTRING_HEX=\"pycore/programs/grow_oom_fatal_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/grow_oom_fatal_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXCORE_EN=1 \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		"-GHEAP_INIT_PTR=32'h00001f80" \
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 \
		--Mdir $(BUILD_DIR)/grow_oom_fatal/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/grow_oom_fatal/verilator/Vtb_container

pycore-excore-alias-stability: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,alias_stability,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd30" -GEXPECTED_TRAP_REQ_COUNT=1)

pycore-excore-mixed-tags-preserved: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,mixed_tags_preserved,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd1677" -GEXPECTED_TRAP_REQ_COUNT=1)

pycore-excore-grow-repeated: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,grow_repeated,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd3850" -GEXPECTED_TRAP_REQ_COUNT=3 -GMAX_CYCLES=20000)

pycore-excore-append-across-call: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,append_across_call,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd77" -GEXPECTED_TRAP_REQ_COUNT=1)

# excore_disabled: the same image as grow_from_zero, but EXCORE_EN=0 ->
# legacy fatal behavior preserved (trap code 9), proving EXCORE_EN really
# gates the marshal path rather than pycore_trap_recoverable() alone.
pycore-excore-disabled: pycore-excore-integration-fixtures
	mkdir -p $(BUILD_DIR)/excore_disabled
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/grow_from_zero.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/grow_from_zero.hex\" \
		-GSTRING_HEX=\"pycore/programs/grow_from_zero_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/grow_from_zero_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXCORE_EN=0 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d9 \
		--Mdir $(BUILD_DIR)/excore_disabled/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/excore_disabled/verilator/Vtb_container

pycore-excore-extend-grow-list: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_grow_list,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd6" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

pycore-excore-extend-grow-tuple: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_grow_tuple,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd60" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

pycore-excore-extend-fast-no-trap: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_fast_no_trap,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd5" -GEXPECTED_TRAP_REQ_COUNT=0)

pycore-excore-extend-empty-noop: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_empty_noop,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd7" -GEXPECTED_TRAP_REQ_COUNT=0)

pycore-excore-extend-self: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_self,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd60" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

pycore-excore-extend-mixed-tags: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_mixed_tags,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd1677" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

pycore-excore-extend-grow-to-fit: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_grow_to_fit,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd146" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=100000)

pycore-excore-extend-oom-fatal: excore-fw pycore-excore-integration-fixtures
	mkdir -p $(BUILD_DIR)/extend_oom_fatal
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/extend_oom_fatal.hex\" \
		-GSTRING_HEX=\"pycore/programs/extend_oom_fatal_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/extend_oom_fatal_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXCORE_EN=1 \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		"-GHEAP_INIT_PTR=32'h00001f80" \
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 \
		--Mdir $(BUILD_DIR)/extend_oom_fatal/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/extend_oom_fatal/verilator/Vtb_container

pycore-excore-extend-across-call: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_across_call,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd88" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

# Same image as extend_grow_list, but EXCORE_EN=0 → fatal trap code 10.
pycore-excore-extend-disabled: pycore-excore-integration-fixtures
	mkdir -p $(BUILD_DIR)/extend_disabled
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' pycore/programs/extend_grow_list.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"pycore/programs/extend_grow_list.hex\" \
		-GSTRING_HEX=\"pycore/programs/extend_grow_list_str.hex\" \
		-GDMEM_HEX=\"pycore/programs/extend_grow_list_dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=0 \
		-GEXCORE_EN=0 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d10 \
		--Mdir $(BUILD_DIR)/extend_disabled/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/extend_disabled/verilator/Vtb_container

pycore-excore-system: \
	pycore-excore-grow-from-zero \
	pycore-excore-fast-path-no-trap \
	pycore-excore-grow-oom-fatal \
	pycore-excore-alias-stability \
	pycore-excore-mixed-tags-preserved \
	pycore-excore-grow-repeated \
	pycore-excore-append-across-call \
	pycore-excore-disabled \
	pycore-excore-extend-grow-list \
	pycore-excore-extend-grow-tuple \
	pycore-excore-extend-fast-no-trap \
	pycore-excore-extend-empty-noop \
	pycore-excore-extend-self \
	pycore-excore-extend-mixed-tags \
	pycore-excore-extend-grow-to-fit \
	pycore-excore-extend-oom-fatal \
	pycore-excore-extend-across-call \
	pycore-excore-extend-disabled

# pycore-container-image-boot removed: the old fixture was generated with
# the pre-3.14 preprocess and still uses 3-slot LOAD_CONST.  The real
# image-boot flow (BOOT_EN=1) is exercised by the img_* programs built
# with pycore/tools/image_from_source.py.

pycore-container: \
	pycore-container-build-index \
	pycore-container-store-subscr \
	pycore-container-dict-lookup \
	pycore-container-dict-store \
	pycore-container-list-empty \
	pycore-container-dict-multi-pair \
	pycore-container-dict-collision \
	pycore-container-dict-insert-new-key \
	pycore-container-dict-empty \
	pycore-container-list-nested \
	pycore-container-tuple-index \
	pycore-container-tuple-empty \
	pycore-container-list-oob-read \
	pycore-container-list-oob-write \
	pycore-container-dict-missing-key \
	pycore-container-tuple-store-trap \
	pycore-container-dict-full-insert \
	pycore-container-list-oom \
	pycore-container-list-append-fast \
	pycore-container-list-append-full-fatal \
	pycore-container-list-extend-fast \
	pycore-container-list-extend-fast-tuple \
	pycore-container-list-extend-empty \
	pycore-container-list-extend-full-fatal \
	pycore-container-list-extend-type-fatal

# excore-fw: assemble excore firmware as a build step. Generated hex is
# never committed (see excore/tools/asm_rv32.py) — no external toolchain.
excore-fw:
	mkdir -p $(dir $(EXCORE_FW_HEX))
	$(PYTHON3) excore/tools/asm_rv32.py $(EXCORE_FW_SRC) -o $(EXCORE_FW_HEX)

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

pycore-test: pycore-python-tests pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-mem pycore-frame pycore-frame-fib pycore-top pycore-multifn pycore-container pycore-img pycore-excore-system pycore-img-two-core

docker-build:
	docker build $(DOCKER_BUILD_FLAGS) -t $(DOCKER_IMAGE) .

docker-run-file: docker-build
	docker run --rm $(DOCKER_RUN_FLAGS) -v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" \
		$(DOCKER_IMAGE) make run-file \
		RUN_SOURCE="$(RUN_SOURCE)" \
		RUN_FUNCTION="$(RUN_FUNCTION)" \
		RUN_PROGRAM_HEX="$(RUN_PROGRAM_HEX)" \
		RUN_STRING_HEX="$(RUN_STRING_HEX)" \
		RUN_TYPES="$(RUN_TYPES)" \
		RUN_CACHE_MAP="$(RUN_CACHE_MAP)" \
		RUN_MAX_CYCLES="$(RUN_MAX_CYCLES)"

docker-pycore-test: docker-build
	docker run --rm $(DOCKER_RUN_FLAGS) -v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make pycore-test

docker-all-tests: docker-build
	docker run --rm $(DOCKER_RUN_FLAGS) -v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make all-tests

clean:
	rm -rf $(BUILD_DIR)

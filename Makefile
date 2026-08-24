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
	pycore/rtl/pycore_complex_alu.sv \
	pycore/rtl/pycore_string_mem.sv \
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
	pycore/rtl/pycore_mem_stage.sv \
	pycore/rtl/pycore_exc_stack.sv \
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
	pycore-img-to-bool-str pycore-img-to-bool-list-trap \
	pycore-img-unary-not \
	pycore-img-unary-invert pycore-img-align-mask pycore-img-unary-negative \
	pycore-img-unary-invert-float-trap \
	pycore-img-unpack-tuple pycore-img-unpack-list pycore-img-unpack-len-trap \
	pycore-img-unpack-ex pycore-img-list-to-tuple \
	pycore-img-str-eq pycore-img-str-lt-trap \
	pycore-img-str-subscr pycore-img-str-subscr-long \
	pycore-img-exec-all \
	pycore-img-slice-all \
	pycore-img-exc-types-all \
	pycore-img-code-ram-all \
	pycore-img-str-subscr-unicode pycore-img-str-subscr-loop \
	pycore-img-str-subscr-oob-trap pycore-img-str-subscr-char-oob-trap \
	pycore-img-scalar-all \
	pycore-img-is-op \
	pycore-img-compare-op pycore-img-compare-op-type-trap \
	pycore-img-pop-jump-if-none \
	pycore-img-for-iter pycore-img-for-iter-type-trap \
	pycore-img-for-iter-nested pycore-img-for-iter-edges \
	pycore-img-for-iter-branch pycore-img-for-iter-mutate \
	pycore-img-for-iter-mutate-visited pycore-img-for-iter-rebind \
	pycore-img-for-iter-grow \
	pycore-img-for-iter-delete pycore-img-for-iter-clear \
	pycore-img-for-iter-subscr pycore-img-for-iter-build-tuple \
	pycore-img-for-iter-range pycore-img-for-iter-range-bounds \
	pycore-img-for-iter-range-step pycore-img-for-iter-range-empty \
	pycore-img-for-iter-range-negative-step pycore-img-for-iter-range-type-trap \
	pycore-img-for-iter-range-bool pycore-img-for-iter-range-zero-step-trap \
	pycore-img-for-iter-str-short pycore-img-for-iter-str-empty \
	pycore-img-for-iter-str-long pycore-img-for-iter-str-unicode \
	pycore-img-for-iter-str-branch pycore-img-for-iter-str-type-trap \
	pycore-img-for-iter-dict-keys pycore-img-for-iter-dict-empty \
	pycore-img-for-iter-dict-delete pycore-img-for-iter-dict-str-keys \
	pycore-img-for-iter-dict-grow \
	pycore-img-for-iter-set-basic pycore-img-for-iter-set-empty \
	pycore-img-for-iter-set-type-trap \
	pycore-img-for-iter-all pycore-img-container-call-spike \
	pycore-img-for-iter-object-list pycore-img-for-iter-object-next \
	pycore-img-for-iter-object-exhaust pycore-img-for-iter-object-no-iter-trap \
	pycore-img-for-iter-object-nested \
	pycore-img-list-comp-basic pycore-img-list-comp-fast-clear \
	pycore-img-for-loop-all \
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
	pycore-for-iter-fixtures pycore-container-for-iter-end-for \
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
	pycore-img-list-del-last-only pycore-img-list-del-shift-excore \
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
	pycore-img-set-update-tuple \
	pycore-img-map-add pycore-img-dict-update pycore-img-dict-update-obj \
	pycore-img-dict-merge \
	pycore-img-two-core \
	pycore-img-attr-basic pycore-img-attr-overwrite pycore-img-attr-many \
	pycore-img-attr-missing pycore-img-attr-type-trap \
	pycore-img-attr-del pycore-img-attr-del-reinsert \
	pycore-img-attr-shadow pycore-img-attr-mro \
	pycore-img-attr-dunder-dict pycore-img-attr-dunder-class \
	pycore-img-attr-dunder-base pycore-img-attr-dunder-store-trap \
	pycore-img-attr-dunder-del-trap \
	pycore-img-attr-grow-global pycore-img-seed-grow-global \
	pycore-img-load-global-namei pycore-img-builtin-max pycore-img-builtin-len-list \
	pycore-img-builtins-fallback pycore-img-builtins-shadow pycore-img-builtins-null-bit \
	pycore-img-load-name-builtin pycore-img-builtin-len-long-str pycore-img-builtin-len-range \
	pycore-img-builtin-len-empty-range pycore-img-builtin-len-obj pycore-img-builtin-len-obj-missing \
	pycore-img-builtin-ord pycore-img-builtin-chr \
	pycore-img-builtin-ord-unicode pycore-img-builtin-ord-scan \
	pycore-img-builtin-ord-len-trap pycore-img-builtin-ord-type-trap \
	pycore-img-builtin-chr-range-trap pycore-img-builtin-chr-surrogate-trap \
	pycore-img-to-bool-none pycore-img-to-bool-containers pycore-img-raise-varargs \
	pycore-img-raise-stopiteration-fatal pycore-img-try-stopiteration \
	pycore-img-try-stopiteration-nested \
	pycore-img-try-exception pycore-img-try-typeerror \
	pycore-img-raise-typeerror-call pycore-img-raise-instance \
	pycore-img-try-tuple-match pycore-img-try-lookuperror \
	pycore-img-try-except-miss pycore-img-bare-raise \
	pycore-img-bare-raise-no-active pycore-img-try-except-else \
	pycore-img-try-finally pycore-img-try-except-as pycore-img-exc-all \
	pycore-img-return-true \
	pycore-img-unpack-ex pycore-img-list-to-tuple \
	pycore-img-firmware-rom-subset pycore-img-firmware-iterators \
	pycore-img-firmware-wave3a pycore-img-firmware-wave3-strings \
	pycore-img-firmware-wave3-pow pycore-img-firmware-wave3-containers \
	pycore-img-firmware-sorted-kw pycore-img-firmware-filter-pred \
	pycore-img-firmware-attr-helpers pycore-img-firmware-isinstance \
	pycore-img-firmware-tuple-empty \
	pycore-img-print-empty pycore-img-print-basic pycore-img-print-sep-end \
	pycore-img-print-end-only pycore-img-print-none-sep \
	pycore-img-print-many pycore-img-print-star pycore-img-print-star-kw \
	pycore-img-print-neg pycore-img-print-bools pycore-img-print-type-trap \
	pycore-img-attr-all \
	pycore-img-method-call pycore-img-method-nested \
	pycore-img-ctor-noinit pycore-img-ctor-init \
	pycore-img-default-arg pycore-img-default-arg-argc-trap \
	pycore-img-default-none pycore-img-default-false-zero \
	pycore-img-default-empty-tuple pycore-img-default-multi-zero-argc \
	pycore-img-default-arg-too-many pycore-img-default-kwonly-none \
	pycore-img-default-partial-none pycore-img-default-call-ex-empty \
	pycore-img-default-nested pycore-img-method-default \
	pycore-img-varargs-pos-defaults \
	pycore-img-call-kw pycore-img-call-kw-unexpected \
	pycore-img-call-function-ex pycore-img-call-function-ex-kw \
	pycore-img-varargs-basic pycore-img-varargs-empty \
	pycore-img-varargs-kwonly pycore-img-varargs-kwonly2 \
	pycore-img-varargs-kwonly2-partial pycore-img-varargs-ex-kw \
	pycore-img-varargs-call-ex \
	pycore-img-varkw-basic pycore-img-varkw-empty pycore-img-varkw-only \
	pycore-img-varkw-and-varargs pycore-img-varkw-call-ex \
	pycore-img-varkw-posonly pycore-img-posonly-kw-trap \
	pycore-img-posonly-ok \
	pycore-img-varkw-name-collision pycore-img-varkw-no-wipe \
	pycore-img-varkw-many pycore-img-varkw-kwonly pycore-img-varkw-combo \
	pycore-img-varkw-method pycore-img-varkw-dup-trap \
	pycore-img-varkw-kwonly-missing-trap \
	pycore-img-method-call-kw \
	pycore-img-bound-method-obj pycore-img-method-all \
	pycore-img-call-all \
	pycore-img-class-simple pycore-img-class-const \
	pycore-img-staticmethod pycore-img-class-two-instances \
	pycore-img-class-all \
	pycore-allocator-host pycore-img-allocator-list pycore-img-allocator-bytes \
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
		pycore/rtl/pycore_complex_alu.sv \
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
		pycore/rtl/pycore_complex_alu.sv \
		pycore/rtl/pycore_string_mem.sv \
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


# ---- Broad-object-support milestone targets (M6 / M8) ---------------------
# Host smoke always runs. Image-boot targets are wired now but fail until
# LOAD_ATTR / classes / bound-method CALL land (M2–M6 / M8).
pycore-allocator-host:
	PYTHONPATH=pycore/tools:$$PYTHONPATH $(PYTHON) -c 'from pathlib import Path; import runpy, tempfile; from run_image_test import apply_heap_list_capacity_inject; text=apply_heap_list_capacity_inject(Path("pycore/programs/allocator_list.py").read_text(), filename="allocator_list.py"); p=Path(tempfile.mkdtemp())/"a.py"; p.write_text(text); ns=runpy.run_path(str(p)); assert isinstance(ns["managed_entry"](), int); ns=runpy.run_path("pycore/programs/allocator_bytes.py"); assert isinstance(ns["managed_entry"](), int); print("allocator host smoke ok")'

define PYCORE_IMAGE_RUN_SRC
	mkdir -p $(BUILD_DIR)/$(1)
	$(PYTHON) pycore/tools/run_image_test.py \
		--source pycore/programs/$(2) \
		--entry managed_entry \
		--program-hex $(BUILD_DIR)/$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/$(1)/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=1 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d$$EXPECTED_TAG \
		"-GEXPECTED_VALUE=128'd$$EXPECTED_VALUE" \
		-GMAX_CYCLES=$(3) \
		--Mdir $(BUILD_DIR)/$(1)/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/$(1)/verilator/Vtb_container
endef

# Same as PYCORE_IMAGE_RUN_SRC but on the two-core top (LIST_EXTEND / grow).
define PYCORE_IMAGE_RUN_SRC_TWOCORE
	mkdir -p $(BUILD_DIR)/$(1)
	$(PYTHON) pycore/tools/run_image_test.py \
		--source pycore/programs/$(2) \
		--entry managed_entry \
		--program-hex $(BUILD_DIR)/$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/$(1)/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=1 \
		-GEXCORE_EN=1 \
		-GFW_HEX=\"$(EXCORE_FW_HEX)\" \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d$$EXPECTED_TAG \
		"-GEXPECTED_VALUE=128'd$$EXPECTED_VALUE" \
		-GMAX_CYCLES=$(3) \
		--Mdir $(BUILD_DIR)/$(1)/verilator_twocore \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/$(1)/verilator_twocore/Vtb_container
endef

# M6 target: allocator_list needs LIST_EXTEND (excore) for _zeros().
# M8 target remains deferred until builtins/slices land.
pycore-img-allocator-list: excore-fw
	$(call PYCORE_IMAGE_RUN_SRC_TWOCORE,img_allocator_list,allocator_list.py,5000000)

pycore-img-allocator-bytes:
	$(call PYCORE_IMAGE_RUN_SRC,img_allocator_bytes,allocator_bytes.py,400000)

pycore-python-tests:
	PYTHONPATH=pycore/tools:$(PYTHONPATH) $(PYTHON) -m unittest discover -s pycore/tests -p "test_*.py"

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

# Plan 1 P1: same differential flow as PYCORE_IMAGE_RUN, but the program is
# built with entry slots offset into code RAM and loaded through CODE_RAM_HEX
# with an empty ROM. A function must produce the same result whichever region
# it executes from, which is the definitive check that the fetch region mux is
# transparent.
define PYCORE_IMAGE_RUN_CODERAM
	mkdir -p $(BUILD_DIR)/imgcr_$(1)
	$(PYTHON) pycore/tools/run_image_test.py \
		--source pycore/programs/img_$(1).py \
		--entry managed_entry \
		--code-ram \
		--program-hex $(BUILD_DIR)/imgcr_$(1)/code_ram.hex \
		--dmem-hex $(BUILD_DIR)/imgcr_$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/imgcr_$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/imgcr_$(1)/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/imgcr_$(1)/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/imgcr_$(1)/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/imgcr_$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"\" \
		-GCODE_RAM_HEX=\"$(BUILD_DIR)/imgcr_$(1)/code_ram.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/imgcr_$(1)/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/imgcr_$(1)/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=1 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d$$EXPECTED_TAG \
		"-GEXPECTED_VALUE=128'd$$EXPECTED_VALUE" \
		-GMAX_CYCLES=$(2) \
		--Mdir $(BUILD_DIR)/imgcr_$(1)/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/imgcr_$(1)/verilator/Vtb_container
endef

# Synthetic §6.1 spike: the generator rewrites the inner zero-arg CALL to
# GET_ITER while preserving CALL's [callable, NULL] RF layout.  The test-only
# core parameter launches S_CALL from S_CONTAINER and must resume with LIST.
define PYCORE_CONTAINER_CALL_SPIKE_RUN
	mkdir -p $(BUILD_DIR)/img_container_call_spike
	$(PYTHON) pycore/tools/gen_container_call_spike.py \
		--source pycore/programs/img_container_call_spike.py \
		--program-hex $(BUILD_DIR)/img_container_call_spike/program.hex \
		--dmem-hex $(BUILD_DIR)/img_container_call_spike/dmem.hex \
		--string-hex $(BUILD_DIR)/img_container_call_spike/string_mem.hex \
		--meta $(BUILD_DIR)/img_container_call_spike/image.meta
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	EXPECTED_TAG=$$(awk -F= '/^EXPECTED_TAG=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	EXPECTED_VALUE=$$(awk -F= '/^EXPECTED_VALUE=/{print $$2}' $(BUILD_DIR)/img_container_call_spike/image.meta); \
	test -n "$$HEAP_INIT_PTR" && test -n "$$EXPECTED_TAG" && test -n "$$EXPECTED_VALUE" || exit 1; \
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl +incdir+excore/rtl/singlecore \
		--top-module tb_container \
		-GPROG_HEX=\"$(BUILD_DIR)/img_container_call_spike/program.hex\" \
		-GSTRING_HEX=\"$(BUILD_DIR)/img_container_call_spike/string_mem.hex\" \
		-GDMEM_HEX=\"$(BUILD_DIR)/img_container_call_spike/dmem.hex\" \
		-GBOOT_EN=1 \
		-GCHECK_ENTRY_RETURN=1 \
		-GCONTAINER_CALL_SPIKE_EN=1 \
		-GHEAP_INIT_PTR=$$HEAP_INIT_PTR \
		-GEXPECTED_TAG=4\'d$$EXPECTED_TAG \
		"-GEXPECTED_VALUE=128'd$$EXPECTED_VALUE" \
		-GMAX_CYCLES=100000 \
		--Mdir $(BUILD_DIR)/img_container_call_spike/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/img_container_call_spike/verilator/Vtb_container
endef

# Phase C full-regression companion to PYCORE_IMAGE_RUN: same image, run on
# the two-core top (EXCORE_EN=1) instead of the legacy pycore_system.
# Programs that need LIST_EXTEND / LIST_DELETE / DICT_GROW / SET_* traps
# must use this path (or EXCORE_EN=1 fixtures).
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

# Two-core image run with console stdout golden (print / BI_PRINT).
# Skips host execution (host print would pollute logs); EXPECTED_* are INT 0.
define PYCORE_IMAGE_RUN_TWOCORE_STDOUT
	mkdir -p $(BUILD_DIR)/img_$(1)
	$(PYTHON) pycore/tools/image_from_source.py \
		--source pycore/programs/img_$(1).py \
		--program-hex $(BUILD_DIR)/img_$(1)/program.hex \
		--dmem-hex $(BUILD_DIR)/img_$(1)/dmem.hex \
		--string-hex $(BUILD_DIR)/img_$(1)/string_mem.hex \
		--meta $(BUILD_DIR)/img_$(1)/image.meta \
		--expected-tag 1 \
		--expected-value 0
	HEAP_INIT_PTR=$$(awk -F= '/^HEAP_INIT_PTR=/{print $$2}' $(BUILD_DIR)/img_$(1)/image.meta); \
	test -n "$$HEAP_INIT_PTR" || exit 1; \
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
		-GEXPECTED_TAG=4\'d1 \
		"-GEXPECTED_VALUE=128'd0" \
		-GSTDOUT_PATH=\"$(BUILD_DIR)/img_$(1)/sim.stdout\" \
		-GMAX_CYCLES=$(2) \
		--Mdir $(BUILD_DIR)/img_$(1)/verilator_twocore \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv && \
	./$(BUILD_DIR)/img_$(1)/verilator_twocore/Vtb_container && \
	diff -u pycore/programs/img_$(1).stdout $(BUILD_DIR)/img_$(1)/sim.stdout
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
		-GEXPECTED_TRAP_CODE=5\'d$(2) \
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
	$(call PYCORE_IMAGE_RUN,to_bool_type_trap,50000)

pycore-img-to-bool-str:
	$(call PYCORE_IMAGE_RUN,to_bool_str,50000)

pycore-img-to-bool-list-trap:
	$(call PYCORE_IMAGE_RUN,to_bool_list_trap,50000)

pycore-img-unary-not:
	$(call PYCORE_IMAGE_RUN,unary_not,50000)

pycore-img-unary-invert:
	$(call PYCORE_IMAGE_RUN,unary_invert,50000)

pycore-img-align-mask:
	$(call PYCORE_IMAGE_RUN,align_mask,50000)

pycore-img-unary-negative:
	$(call PYCORE_IMAGE_RUN,unary_negative,50000)

pycore-img-unary-invert-float-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,unary_invert_float_trap,1,50000)

pycore-img-unpack-tuple:
	$(call PYCORE_IMAGE_RUN,unpack_tuple,50000)

pycore-img-unpack-list:
	$(call PYCORE_IMAGE_RUN,unpack_list,50000)

pycore-img-unpack-len-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,unpack_len_trap,1,50000)

pycore-img-unpack-ex:
	$(call PYCORE_IMAGE_RUN,unpack_ex,50000)

pycore-img-list-to-tuple: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_to_tuple,100000)

pycore-img-str-eq:
	$(call PYCORE_IMAGE_RUN,str_eq,50000)

pycore-img-str-lt-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,str_lt_trap,1,50000)

pycore-img-str-subscr:
	$(call PYCORE_IMAGE_RUN,str_subscr,50000)

pycore-img-exec-code-basic:
	$(call PYCORE_IMAGE_RUN,exec_code_basic,50000)

pycore-img-exec-code-globals-rw:
	$(call PYCORE_IMAGE_RUN,exec_code_globals_rw,50000)

pycore-img-exec-code-returns-none:
	$(call PYCORE_IMAGE_RUN,exec_code_returns_none,50000)

pycore-img-exec-code-nested:
	$(call PYCORE_IMAGE_RUN,exec_code_nested,50000)

pycore-img-eval-code-expr:
	$(call PYCORE_IMAGE_RUN,eval_code_expr,50000)

pycore-img-exec-bad-arg-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,exec_bad_arg_trap,6,50000)

pycore-img-exec-globals-dict:
	$(call PYCORE_IMAGE_RUN,exec_globals_dict,100000)

pycore-img-exec-globals-read:
	$(call PYCORE_IMAGE_RUN,exec_globals_read,100000)

pycore-img-exec-globals-restore:
	$(call PYCORE_IMAGE_RUN,exec_globals_restore,100000)

pycore-img-exec-globals-nested:
	$(call PYCORE_IMAGE_RUN,exec_globals_nested,100000)

pycore-img-exec-globals-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,exec_globals_type_trap,1,50000)

# Plan 1 P3: exec/eval on precompiled CODE_OBJECTs (SEED_CODE payloads).
pycore-img-slice-str:
	$(call PYCORE_IMAGE_RUN,slice_str,50000)

pycore-img-slice-str-open:
	$(call PYCORE_IMAGE_RUN,slice_str_open,50000)

pycore-img-slice-str-clamp:
	$(call PYCORE_IMAGE_RUN,slice_str_clamp,50000)

pycore-img-slice-str-long:
	$(call PYCORE_IMAGE_RUN,slice_str_long,100000)

pycore-img-slice-str-unicode:
	$(call PYCORE_IMAGE_RUN,slice_str_unicode,100000)

pycore-img-slice-str-empty:
	$(call PYCORE_IMAGE_RUN,slice_str_empty,50000)

pycore-img-slice-str-scan:
	$(call PYCORE_IMAGE_RUN,slice_str_scan,200000)

pycore-img-slice-str-neg-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,slice_str_neg_trap,1,50000)

pycore-img-slice-list-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,slice_list_trap,1,50000)

pycore-img-try-syntaxerror:
	$(call PYCORE_IMAGE_RUN,try_syntaxerror,50000)

pycore-img-try-exc-types:
	$(call PYCORE_IMAGE_RUN,try_exc_types,100000)

pycore-img-try-syntaxerror-msg:
	$(call PYCORE_IMAGE_RUN,try_syntaxerror_msg,50000)

pycore-img-raise-syntaxerror-fatal:
	$(call PYCORE_IMAGE_TRAP_RUN,raise_syntaxerror_fatal,17,50000)

pycore-img-try-exc-cross-frame-fatal:
	$(call PYCORE_IMAGE_RUN,try_exc_cross_frame_fatal,100000)

pycore-img-try-callee-unhandled:
	$(call PYCORE_IMAGE_TRAP_RUN,try_callee_unhandled,17,100000)

pycore-img-code-ram-call-rom:
	$(call PYCORE_IMAGE_RUN,code_ram_call,100000)

pycore-img-code-ram-call:
	$(call PYCORE_IMAGE_RUN_CODERAM,code_ram_call,100000)

pycore-img-heap-mark-release:
	$(call PYCORE_IMAGE_RUN,heap_mark_release,100000)

pycore-img-code-mark-release:
	$(call PYCORE_IMAGE_RUN,code_mark_release,50000)

pycore-img-heap-release-stale-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,heap_release_stale_trap,7,50000)

pycore-img-heap-release-below-base-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,heap_release_below_base_trap,7,50000)

pycore-img-code-release-stale-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,code_release_stale_trap,7,50000)

pycore-img-heap-mark-argc-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,heap_mark_argc_trap,6,50000)

# Plan 1 P8: region mark / release for heap and code RAM.
pycore-img-marks-all: \
	pycore-img-heap-mark-release \
	pycore-img-code-mark-release \
	pycore-img-heap-release-stale-trap \
	pycore-img-heap-release-below-base-trap \
	pycore-img-code-release-stale-trap \
	pycore-img-heap-mark-argc-trap

# Plan 1 P1: the same program from ROM and from code RAM must agree.
pycore-img-code-ram-all: \
	pycore-img-code-ram-call-rom \
	pycore-img-code-ram-call

# Plan 1 P7: seeded leaf exception types for firmware error reporting.
pycore-img-exc-types-all: \
	pycore-img-try-syntaxerror \
	pycore-img-try-exc-types \
	pycore-img-try-syntaxerror-msg \
	pycore-img-raise-syntaxerror-fatal \
	pycore-img-try-exc-cross-frame-fatal

# Plan 1 P6.1: BINARY_SLICE on strings (character-indexed, CPython clamping).
pycore-img-slice-all: \
	pycore-img-slice-str \
	pycore-img-slice-str-open \
	pycore-img-slice-str-clamp \
	pycore-img-slice-str-long \
	pycore-img-slice-str-unicode \
	pycore-img-slice-str-empty \
	pycore-img-slice-str-scan \
	pycore-img-slice-str-neg-trap \
	pycore-img-slice-list-trap

pycore-img-exec-all: \
	pycore-img-exec-code-basic \
	pycore-img-exec-code-globals-rw \
	pycore-img-exec-code-returns-none \
	pycore-img-exec-code-nested \
	pycore-img-eval-code-expr \
	pycore-img-exec-bad-arg-trap \
	pycore-img-exec-globals-dict \
	pycore-img-exec-globals-read \
	pycore-img-exec-globals-restore \
	pycore-img-exec-globals-nested \
	pycore-img-exec-globals-type-trap

pycore-img-str-subscr-long:
	$(call PYCORE_IMAGE_RUN,str_subscr_long,50000)

pycore-img-str-subscr-unicode:
	$(call PYCORE_IMAGE_RUN,str_subscr_unicode,50000)

pycore-img-str-subscr-loop:
	$(call PYCORE_IMAGE_RUN,str_subscr_loop,100000)

pycore-img-str-subscr-oob-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,str_subscr_oob_trap,7,50000)

pycore-img-str-subscr-char-oob-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,str_subscr_char_oob_trap,7,50000)

pycore-img-scalar-all: \
	pycore-img-unary-invert \
	pycore-img-align-mask \
	pycore-img-unary-negative \
	pycore-img-unary-invert-float-trap \
	pycore-img-unpack-tuple \
	pycore-img-unpack-list \
	pycore-img-unpack-len-trap \
	pycore-img-unpack-ex \
	pycore-img-list-to-tuple \
	pycore-img-str-eq \
	pycore-img-str-lt-trap \
	pycore-img-str-subscr \
	pycore-img-str-subscr-long \
	pycore-img-str-subscr-unicode \
	pycore-img-str-subscr-loop \
	pycore-img-str-subscr-oob-trap \
	pycore-img-str-subscr-char-oob-trap

pycore-img-is-op:
	$(call PYCORE_IMAGE_RUN,is_op,50000)

pycore-img-compare-op:
	$(call PYCORE_IMAGE_RUN,compare_op,50000)

pycore-img-compare-op-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,compare_op_type_trap,1,50000)

pycore-img-pop-jump-if-none:
	$(call PYCORE_IMAGE_RUN,pop_jump_if_none,50000)

pycore-img-for-iter:
	$(call PYCORE_IMAGE_RUN,for_iter,100000)

pycore-img-container-call-spike:
	$(PYCORE_CONTAINER_CALL_SPIKE_RUN)

pycore-img-for-iter-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_type_trap,1,50000)

pycore-img-for-iter-nested:
	$(call PYCORE_IMAGE_RUN,for_iter_nested,100000)

pycore-img-for-iter-edges:
	$(call PYCORE_IMAGE_RUN,for_iter_edges,100000)

pycore-img-for-iter-branch:
	$(call PYCORE_IMAGE_RUN,for_iter_branch,100000)

pycore-img-for-iter-mutate:
	$(call PYCORE_IMAGE_RUN,for_iter_mutate,100000)

pycore-img-for-iter-mutate-visited:
	$(call PYCORE_IMAGE_RUN,for_iter_mutate_visited,100000)

pycore-img-for-iter-rebind:
	$(call PYCORE_IMAGE_RUN,for_iter_rebind,100000)

pycore-img-for-iter-grow: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,for_iter_grow,150000)

pycore-img-for-iter-delete: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,for_iter_delete,150000)

pycore-img-for-iter-clear: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,for_iter_clear,150000)

pycore-img-for-iter-subscr:
	$(call PYCORE_IMAGE_RUN,for_iter_subscr,100000)

pycore-img-for-iter-build-tuple:
	$(call PYCORE_IMAGE_RUN,for_iter_build_tuple,100000)

pycore-img-for-iter-range:
	$(call PYCORE_IMAGE_RUN,for_iter_range,100000)

pycore-img-for-iter-range-bounds:
	$(call PYCORE_IMAGE_RUN,for_iter_range_bounds,150000)

pycore-img-for-iter-range-step:
	$(call PYCORE_IMAGE_RUN,for_iter_range_step,100000)

pycore-img-for-iter-range-empty:
	$(call PYCORE_IMAGE_RUN,for_iter_range_empty,100000)

pycore-img-for-iter-range-negative-step:
	$(call PYCORE_IMAGE_RUN,for_iter_range_negative_step,100000)

pycore-img-for-iter-range-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_range_type_trap,1,50000)

pycore-img-for-iter-range-bool:
	$(call PYCORE_IMAGE_RUN,for_iter_range_bool,100000)

pycore-img-for-iter-range-zero-step-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_range_zero_step_trap,1,50000)

pycore-img-for-iter-str-short:
	$(call PYCORE_IMAGE_RUN,for_iter_str_short,100000)

pycore-img-for-iter-str-empty:
	$(call PYCORE_IMAGE_RUN,for_iter_str_empty,100000)

pycore-img-for-iter-str-long:
	$(call PYCORE_IMAGE_RUN,for_iter_str_long,150000)

pycore-img-for-iter-str-unicode:
	$(call PYCORE_IMAGE_RUN,for_iter_str_unicode,100000)

pycore-img-for-iter-str-branch:
	$(call PYCORE_IMAGE_RUN,for_iter_str_branch,100000)

pycore-img-for-iter-str-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_str_type_trap,1,50000)

pycore-img-for-iter-dict-keys:
	$(call PYCORE_IMAGE_RUN,for_iter_dict_keys,100000)

pycore-img-for-iter-dict-empty:
	$(call PYCORE_IMAGE_RUN,for_iter_dict_empty,50000)

pycore-img-for-iter-dict-delete:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_dict_delete,1,100000)

pycore-img-for-iter-dict-str-keys:
	$(call PYCORE_IMAGE_RUN,for_iter_dict_str_keys,150000)

pycore-img-for-iter-dict-grow: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,for_iter_dict_grow,200000)

pycore-img-for-iter-set-basic:
	$(call PYCORE_IMAGE_RUN,for_iter_set_basic,150000)

pycore-img-for-iter-set-empty:
	$(call PYCORE_IMAGE_RUN,for_iter_set_empty,100000)

pycore-img-for-iter-set-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_set_type_trap,1,50000)

pycore-img-for-iter-object-list:
	$(call PYCORE_IMAGE_RUN,for_iter_object_list,200000)

pycore-img-for-iter-object-next:
	$(call PYCORE_IMAGE_RUN,for_iter_object_next,400000)

pycore-img-for-iter-object-raise-catch:
	$(call PYCORE_IMAGE_RUN,for_iter_object_raise_catch,400000)

pycore-img-for-iter-object-exhaust:
	$(call PYCORE_IMAGE_RUN,for_iter_object_exhaust,200000)

pycore-img-for-iter-object-no-iter-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,for_iter_object_no_iter_trap,1,100000)

pycore-img-for-iter-object-nested:
	$(call PYCORE_IMAGE_RUN,for_iter_object_nested,400000)

# Track C: real compile() list comprehensions (LIST_APPEND grow → two-core).
pycore-img-list-comp-basic: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_comp_basic,400000)

pycore-img-list-comp-fast-clear: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_comp_fast_clear,400000)

pycore-img-for-loop-all: \
	pycore-img-for-iter-all \
	pycore-img-for-iter-object-list \
	pycore-img-for-iter-object-next \
	pycore-img-for-iter-object-exhaust \
	pycore-img-for-iter-object-no-iter-trap \
	pycore-img-for-iter-object-nested \
	pycore-img-exc-all \
	pycore-img-list-comp-basic \
	pycore-img-list-comp-fast-clear

pycore-img-for-iter-all: \
	pycore-img-for-iter \
	pycore-img-for-iter-type-trap \
	pycore-img-for-iter-nested \
	pycore-img-for-iter-edges \
	pycore-img-for-iter-branch \
	pycore-img-for-iter-mutate \
	pycore-img-for-iter-mutate-visited \
	pycore-img-for-iter-rebind \
	pycore-img-for-iter-grow \
	pycore-img-for-iter-delete \
	pycore-img-for-iter-clear \
	pycore-img-for-iter-subscr \
	pycore-img-for-iter-build-tuple \
	pycore-img-for-iter-range \
	pycore-img-for-iter-range-bounds \
	pycore-img-for-iter-range-step \
	pycore-img-for-iter-range-empty \
	pycore-img-for-iter-range-negative-step \
	pycore-img-for-iter-range-type-trap \
	pycore-img-for-iter-range-bool \
	pycore-img-for-iter-range-zero-step-trap \
	pycore-img-for-iter-str-short \
	pycore-img-for-iter-str-empty \
	pycore-img-for-iter-str-long \
	pycore-img-for-iter-str-unicode \
	pycore-img-for-iter-str-branch \
	pycore-img-for-iter-str-type-trap \
	pycore-img-for-iter-dict-keys \
	pycore-img-for-iter-dict-empty \
	pycore-img-for-iter-dict-delete \
	pycore-img-for-iter-dict-str-keys \
	pycore-img-for-iter-dict-grow \
	pycore-img-for-iter-set-basic \
	pycore-img-for-iter-set-empty \
	pycore-img-for-iter-set-type-trap \
	pycore-img-for-iter-object-list \
	pycore-img-for-iter-object-next \
	pycore-img-for-iter-object-exhaust \
	pycore-img-for-iter-object-no-iter-trap \
	pycore-img-for-iter-object-nested \
	pycore-container-for-iter-end-for

pycore-img-nop:
	$(call PYCORE_IMAGE_RUN,nop,50000)

# DELETE_SUBSCR / CONTAINS_OP (list shift-down + membership; raw Python imgs)
# Mid-list delete raises LIST_DELETE (12) → two-core. Last-element stays
# O(1) on pycore (single-core).
pycore-img-list-del-simple: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_del_simple,100000)

pycore-img-list-del-first-last: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_del_first_last,100000)

pycore-img-list-del-last-only:
	$(call PYCORE_IMAGE_RUN,list_del_last_only,50000)

pycore-img-list-del-shift-excore: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_del_shift_excore,100000)

pycore-img-list-contains-simple:
	$(call PYCORE_IMAGE_RUN,list_contains_simple,50000)

pycore-img-list-contains-types:
	$(call PYCORE_IMAGE_RUN,list_contains_types,50000)

pycore-img-tuple-contains:
	$(call PYCORE_IMAGE_RUN,tuple_contains,50000)

pycore-img-dict-contains:
	$(call PYCORE_IMAGE_RUN,dict_contains,50000)

pycore-img-list-del-contains: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_del_contains,100000)

pycore-img-list-del-nested: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,list_del_nested,100000)

# helper deletes last element only → single-core O(1) path
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

# TUPLE-source SET_UPDATE: excore fast path excludes TUPLE, so pycore owns the
# whole op (grow + rehash + insert). Two-core so the excore firmware is linked
# even though the SET_UPDATE itself never traps out to it.
pycore-img-set-update-tuple: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,set_update_tuple,100000)

# Bulk dict ops: MAP_ADD (dict comprehension), DICT_UPDATE ({**a, **b}) and
# non-empty DICT_MERGE (CALL_FUNCTION_EX **kwargs). All hit excore grow/merge.
pycore-img-map-add: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,map_add,150000)

pycore-img-dict-update: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,dict_update,150000)

# Contaminated DICT_UPDATE (OBJECT/instance keys) — pycore owns grow + rehash +
# order-copy + insert/overwrite; never traps to excore for the update itself.
pycore-img-dict-update-obj: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,dict_update_obj,200000)

pycore-img-dict-merge: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,dict_merge,150000)

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
		-GEXPECTED_TRAP_CODE=5\'d$(2) \
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
	pycore-img-list-del-simple \
	pycore-img-list-del-first-last \
	pycore-img-list-del-contains \
	pycore-img-list-del-nested \
	pycore-img-list-del-shift-excore \
	pycore-img-dict-grow-basic \
	pycore-img-dict-grow-large \
	pycore-img-dict-mixed-ops \
	pycore-img-set-grow-basic \
	pycore-img-set-update \
	pycore-img-set-update-tuple \
	pycore-img-map-add \
	pycore-img-dict-update \
	pycore-img-dict-update-obj \
	pycore-img-dict-merge \
	pycore-img-attr-many

pycore-img: \
	pycore-img-exec-all \
	pycore-img-slice-all \
	pycore-img-exc-types-all \
	pycore-img-code-ram-all \
	pycore-img-marks-all \
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
	pycore-img-to-bool-str \
	pycore-img-to-bool-list-trap \
	pycore-img-unary-not \
	pycore-img-scalar-all \
	pycore-img-is-op \
	pycore-img-compare-op \
	pycore-img-compare-op-type-trap \
	pycore-img-pop-jump-if-none \
	pycore-img-for-iter-all \
	pycore-img-container-call-spike \
	pycore-img-for-loop-all \
	pycore-img-nop \
	pycore-img-list-del-last-only \
	pycore-img-list-contains-simple \
	pycore-img-list-contains-types \
	pycore-img-tuple-contains \
	pycore-img-dict-contains \
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
	pycore-img-set-grow-fatal \
	pycore-img-attr-all \
	pycore-img-method-all \
	pycore-img-call-all \
	pycore-img-varargs-basic \
	pycore-img-varargs-empty \
	pycore-img-varargs-kwonly \
	pycore-img-varargs-kwonly2 \
	pycore-img-varargs-kwonly2-partial \
	pycore-img-varargs-ex-kw \
	pycore-img-varargs-call-ex \
	pycore-img-class-all \
	pycore-img-allocator-list

# Attribute protocol (M2): LOAD/STORE/DELETE_ATTR via seeded OBK_INSTANCE.
pycore-img-attr-basic:
	$(call PYCORE_IMAGE_RUN,attr_basic,50000)

pycore-img-attr-overwrite:
	$(call PYCORE_IMAGE_RUN,attr_overwrite,50000)

pycore-img-attr-many: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,attr_many,100000)

pycore-img-attr-missing:
	$(call PYCORE_IMAGE_TRAP_RUN,attr_missing,15,50000)

pycore-img-attr-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,attr_type_trap,1,50000)

pycore-img-attr-del:
	$(call PYCORE_IMAGE_TRAP_RUN,attr_del,15,50000)

pycore-img-attr-del-reinsert:
	$(call PYCORE_IMAGE_RUN,attr_del_reinsert,50000)

pycore-img-attr-shadow:
	$(call PYCORE_IMAGE_RUN,attr_shadow,50000)

pycore-img-attr-mro:
	$(call PYCORE_IMAGE_RUN,attr_mro,50000)

pycore-img-attr-dunder-dict:
	$(call PYCORE_IMAGE_RUN,attr_dunder_dict,50000)

pycore-img-attr-dunder-class:
	$(call PYCORE_IMAGE_RUN,attr_dunder_class,50000)

pycore-img-attr-dunder-base:
	$(call PYCORE_IMAGE_RUN,attr_dunder_base,50000)

pycore-img-attr-dunder-store-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,attr_dunder_store_trap,1,50000)

pycore-img-attr-dunder-del-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,attr_dunder_del_trap,1,50000)

pycore-img-attr-all: \
	pycore-img-attr-basic \
	pycore-img-attr-overwrite \
	pycore-img-attr-many \
	pycore-img-attr-missing \
	pycore-img-attr-type-trap \
	pycore-img-attr-del \
	pycore-img-attr-del-reinsert \
	pycore-img-attr-shadow \
	pycore-img-attr-mro \
	pycore-img-attr-dunder-dict \
	pycore-img-attr-dunder-class \
	pycore-img-attr-dunder-base \
	pycore-img-attr-dunder-store-trap \
	pycore-img-attr-dunder-del-trap \
	pycore-img-attr-grow-global \
	pycore-img-seed-grow-global \
	pycore-img-load-global-namei pycore-img-builtin-max pycore-img-builtin-len-list \
	pycore-img-builtins-fallback pycore-img-builtins-shadow pycore-img-builtins-null-bit \
	pycore-img-load-name-builtin pycore-img-builtin-len-long-str pycore-img-builtin-len-range \
	pycore-img-builtin-len-empty-range pycore-img-builtin-len-obj pycore-img-builtin-len-obj-missing \
	pycore-img-builtin-ord pycore-img-builtin-chr \
	pycore-img-builtin-ord-unicode pycore-img-builtin-ord-scan \
	pycore-img-builtin-ord-len-trap pycore-img-builtin-ord-type-trap \
	pycore-img-builtin-chr-range-trap pycore-img-builtin-chr-surrogate-trap \
	pycore-img-to-bool-none pycore-img-to-bool-containers pycore-img-raise-varargs \
	pycore-img-raise-stopiteration-fatal pycore-img-try-stopiteration \
	pycore-img-try-stopiteration-nested \
	pycore-img-try-exception pycore-img-try-typeerror \
	pycore-img-raise-typeerror-call pycore-img-raise-instance \
	pycore-img-try-tuple-match pycore-img-try-lookuperror \
	pycore-img-try-except-miss pycore-img-bare-raise \
	pycore-img-bare-raise-no-active pycore-img-try-except-else \
	pycore-img-try-finally pycore-img-try-except-as pycore-img-exc-all \
	pycore-img-return-true \
	pycore-img-unpack-ex pycore-img-list-to-tuple \
	pycore-img-firmware-rom-subset pycore-img-firmware-iterators \
	pycore-img-firmware-wave3a pycore-img-firmware-wave3-strings \
	pycore-img-firmware-wave3-pow pycore-img-firmware-wave3-containers \
	pycore-img-firmware-sorted-kw pycore-img-firmware-filter-pred \
	pycore-img-firmware-attr-helpers pycore-img-firmware-isinstance \
	pycore-img-firmware-tuple-empty \
	pycore-img-print-empty pycore-img-print-basic pycore-img-print-sep-end \
	pycore-img-print-end-only pycore-img-print-none-sep \
	pycore-img-print-many pycore-img-print-star pycore-img-print-star-kw \
	pycore-img-print-neg pycore-img-print-bools pycore-img-print-type-trap \
	pycore-img-builtin-max \
	pycore-img-builtin-len-list

# Generalized CALL (M3): method form, type ctor, defaults, bound-method obj.
pycore-img-method-call:
	$(call PYCORE_IMAGE_RUN,method_call,50000)

pycore-img-method-nested:
	$(call PYCORE_IMAGE_RUN,method_nested,100000)

pycore-img-ctor-noinit:
	$(call PYCORE_IMAGE_RUN,ctor_noinit,50000)

pycore-img-ctor-init:
	$(call PYCORE_IMAGE_RUN,ctor_init,100000)

pycore-img-attr-grow-global: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,attr_grow_global,200000)

pycore-img-seed-grow-global: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,seed_grow_global,200000)

pycore-img-load-global-namei:
	$(call PYCORE_IMAGE_RUN,load_global_namei,50000)

pycore-img-builtin-max:
	$(call PYCORE_IMAGE_RUN,builtin_max,50000)

pycore-img-builtin-len-list:
	$(call PYCORE_IMAGE_RUN,builtin_len_list,50000)

pycore-img-builtins-fallback:
	$(call PYCORE_IMAGE_RUN,builtins_fallback,50000)

pycore-img-builtins-shadow:
	$(call PYCORE_IMAGE_RUN,builtins_shadow,50000)

pycore-img-builtins-null-bit:
	$(call PYCORE_IMAGE_RUN,builtins_null_bit,50000)

pycore-img-firmware-rom-subset:
	$(call PYCORE_IMAGE_RUN,firmware_rom_subset,200000)

pycore-img-firmware-iterators: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,firmware_iterators,500000)

pycore-img-firmware-wave3a:
	$(call PYCORE_IMAGE_RUN,firmware_wave3a,200000)

pycore-img-firmware-wave3-strings:
	$(call PYCORE_IMAGE_RUN,firmware_wave3_strings,200000)

pycore-img-firmware-wave3-pow:
	$(call PYCORE_IMAGE_RUN,firmware_wave3_pow,200000)

pycore-img-firmware-wave3-containers: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,firmware_wave3_containers,500000)

pycore-img-firmware-sorted-kw: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,firmware_sorted_kw,500000)

pycore-img-firmware-filter-pred: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE,firmware_filter_pred,500000)

pycore-img-firmware-attr-helpers:
	$(call PYCORE_IMAGE_RUN,firmware_attr_helpers,200000)

pycore-img-firmware-isinstance:
	$(call PYCORE_IMAGE_RUN,firmware_isinstance,200000)

pycore-img-firmware-tuple-empty:
	$(call PYCORE_IMAGE_RUN,firmware_tuple_empty,100000)

pycore-img-print-empty: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_empty,200000)

pycore-img-print-basic: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_basic,200000)

pycore-img-print-sep-end: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_sep_end,200000)

pycore-img-print-end-only: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_end_only,200000)

pycore-img-print-none-sep: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_none_sep,200000)

pycore-img-print-many: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_many,300000)

pycore-img-print-star: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_star,300000)

pycore-img-print-star-kw: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_star_kw,300000)

pycore-img-print-neg: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_neg,200000)

pycore-img-print-bools: excore-fw
	$(call PYCORE_IMAGE_RUN_TWOCORE_STDOUT,print_bools,200000)

pycore-img-print-type-trap: excore-fw
	$(call PYCORE_IMAGE_TRAP_RUN_TWOCORE,print_type_trap,1,200000)

pycore-img-load-name-builtin:
	$(call PYCORE_IMAGE_RUN,load_name_builtin,50000)

pycore-img-builtin-len-long-str:
	$(call PYCORE_IMAGE_RUN,builtin_len_long_str,50000)

pycore-img-builtin-len-range:
	$(call PYCORE_IMAGE_RUN,builtin_len_range,50000)

pycore-img-builtin-len-empty-range:
	$(call PYCORE_IMAGE_RUN,builtin_len_empty_range,50000)

pycore-img-builtin-len-obj:
	$(call PYCORE_IMAGE_RUN,builtin_len_obj,100000)

pycore-img-builtin-len-obj-missing:
	$(call PYCORE_IMAGE_TRAP_RUN,builtin_len_obj_missing,15,50000)

pycore-img-builtin-ord:
	$(call PYCORE_IMAGE_RUN,builtin_ord,50000)

pycore-img-builtin-chr:
	$(call PYCORE_IMAGE_RUN,builtin_chr,50000)

pycore-img-builtin-ord-unicode:
	$(call PYCORE_IMAGE_RUN,builtin_ord_unicode,100000)

pycore-img-builtin-ord-scan:
	$(call PYCORE_IMAGE_RUN,builtin_ord_scan,100000)

pycore-img-builtin-ord-len-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,builtin_ord_len_trap,1,50000)

pycore-img-builtin-ord-type-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,builtin_ord_type_trap,1,50000)

pycore-img-builtin-chr-range-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,builtin_chr_range_trap,1,50000)

pycore-img-builtin-chr-surrogate-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,builtin_chr_surrogate_trap,1,50000)

pycore-img-to-bool-none:
	$(call PYCORE_IMAGE_RUN,to_bool_none,50000)

pycore-img-to-bool-containers:
	$(call PYCORE_IMAGE_RUN,to_bool_containers,100000)

pycore-img-raise-varargs:
	$(call PYCORE_IMAGE_TRAP_RUN,raise_varargs,1,50000)

pycore-img-raise-stopiteration-fatal:
	$(call PYCORE_IMAGE_TRAP_RUN,raise_stopiteration_fatal,17,50000)

pycore-img-try-stopiteration:
	$(call PYCORE_IMAGE_RUN,try_stopiteration,100000)

pycore-img-try-stopiteration-nested:
	$(call PYCORE_IMAGE_RUN,try_stopiteration_nested,100000)

pycore-img-try-exception:
	$(call PYCORE_IMAGE_RUN,try_exception,100000)

pycore-img-try-typeerror:
	$(call PYCORE_IMAGE_RUN,try_typeerror,100000)

pycore-img-raise-typeerror-call:
	$(call PYCORE_IMAGE_RUN,raise_typeerror_call,100000)

pycore-img-raise-instance:
	$(call PYCORE_IMAGE_RUN,raise_instance,100000)

pycore-img-try-tuple-match:
	$(call PYCORE_IMAGE_RUN,try_tuple_match,100000)

pycore-img-try-lookuperror:
	$(call PYCORE_IMAGE_RUN,try_lookuperror,100000)

pycore-img-try-except-miss:
	$(call PYCORE_IMAGE_TRAP_RUN,try_except_miss,17,100000)

pycore-img-bare-raise:
	$(call PYCORE_IMAGE_RUN,bare_raise,100000)

pycore-img-bare-raise-no-active:
	$(call PYCORE_IMAGE_TRAP_RUN,bare_raise_no_active,17,50000)

pycore-img-try-except-else:
	$(call PYCORE_IMAGE_RUN,try_except_else,100000)

pycore-img-try-finally:
	$(call PYCORE_IMAGE_RUN,try_finally,150000)

pycore-img-try-except-as:
	$(call PYCORE_IMAGE_RUN,try_except_as,100000)

pycore-img-exc-all: \
	pycore-img-try-stopiteration \
	pycore-img-try-stopiteration-nested \
	pycore-img-raise-stopiteration-fatal \
	pycore-img-try-exception \
	pycore-img-try-typeerror \
	pycore-img-raise-typeerror-call \
	pycore-img-raise-instance \
	pycore-img-try-tuple-match \
	pycore-img-try-lookuperror \
	pycore-img-try-except-miss \
	pycore-img-bare-raise \
	pycore-img-bare-raise-no-active \
	pycore-img-try-except-else \
	pycore-img-try-finally \
	pycore-img-try-except-as \
	pycore-img-try-exc-cross-frame-fatal \
	pycore-img-try-callee-unhandled \
	pycore-img-for-iter-object-raise-catch

pycore-img-return-true:
	$(call PYCORE_IMAGE_RUN,return_true,50000)

pycore-img-default-arg:
	$(call PYCORE_IMAGE_RUN,default_arg,50000)

pycore-img-default-arg-argc-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,default_arg_argc_trap,6,50000)

pycore-img-default-none:
	$(call PYCORE_IMAGE_RUN,default_none,50000)

pycore-img-default-false-zero:
	$(call PYCORE_IMAGE_RUN,default_false_zero,50000)

pycore-img-default-empty-tuple:
	$(call PYCORE_IMAGE_RUN,default_empty_tuple,50000)

pycore-img-default-multi-zero-argc:
	$(call PYCORE_IMAGE_RUN,default_multi_zero_argc,50000)

pycore-img-default-arg-too-many:
	$(call PYCORE_IMAGE_TRAP_RUN,default_arg_too_many,6,50000)

pycore-img-default-kwonly-none:
	$(call PYCORE_IMAGE_RUN,default_kwonly_none,100000)

pycore-img-default-partial-none:
	$(call PYCORE_IMAGE_RUN,default_partial_none,50000)

pycore-img-default-call-ex-empty:
	$(call PYCORE_IMAGE_RUN,default_call_ex_empty,100000)

pycore-img-default-nested:
	$(call PYCORE_IMAGE_RUN,default_nested,50000)

pycore-img-method-default:
	$(call PYCORE_IMAGE_RUN,method_default,100000)

pycore-img-varargs-pos-defaults:
	$(call PYCORE_IMAGE_RUN,varargs_pos_defaults,100000)

pycore-img-call-kw:
	$(call PYCORE_IMAGE_RUN,call_kw,100000)

pycore-img-call-kw-unexpected:
	$(call PYCORE_IMAGE_TRAP_RUN,call_kw_unexpected,6,50000)

pycore-img-call-function-ex:
	$(call PYCORE_IMAGE_RUN,call_function_ex,100000)

pycore-img-call-function-ex-kw:
	$(call PYCORE_IMAGE_RUN,call_function_ex_kw,100000)

pycore-img-varargs-basic:
	$(call PYCORE_IMAGE_RUN,varargs_basic,100000)

pycore-img-varargs-empty:
	$(call PYCORE_IMAGE_RUN,varargs_empty,100000)

pycore-img-varargs-kwonly:
	$(call PYCORE_IMAGE_RUN,varargs_kwonly,100000)

pycore-img-varargs-kwonly2:
	$(call PYCORE_IMAGE_RUN,varargs_kwonly2,100000)

pycore-img-varargs-kwonly2-partial:
	$(call PYCORE_IMAGE_RUN,varargs_kwonly2_partial,100000)

pycore-img-varargs-ex-kw:
	$(call PYCORE_IMAGE_RUN,varargs_ex_kw,100000)

pycore-img-varargs-call-ex:
	$(call PYCORE_IMAGE_RUN,varargs_call_ex,100000)

pycore-img-varkw-basic:
	$(call PYCORE_IMAGE_RUN,varkw_basic,100000)

pycore-img-varkw-empty:
	$(call PYCORE_IMAGE_RUN,varkw_empty,100000)

pycore-img-varkw-only:
	$(call PYCORE_IMAGE_RUN,varkw_only,100000)

pycore-img-varkw-and-varargs:
	$(call PYCORE_IMAGE_RUN,varkw_and_varargs,100000)

pycore-img-varkw-call-ex:
	$(call PYCORE_IMAGE_RUN,varkw_call_ex,150000)

pycore-img-varkw-posonly:
	$(call PYCORE_IMAGE_RUN,varkw_posonly,100000)

pycore-img-posonly-kw-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,posonly_kw_trap,6,50000)

pycore-img-posonly-ok:
	$(call PYCORE_IMAGE_RUN,posonly_ok,100000)

pycore-img-varkw-name-collision:
	$(call PYCORE_IMAGE_RUN,varkw_name_collision,100000)

pycore-img-varkw-no-wipe:
	$(call PYCORE_IMAGE_RUN,varkw_no_wipe,100000)

pycore-img-varkw-many:
	$(call PYCORE_IMAGE_RUN,varkw_many,150000)

pycore-img-varkw-kwonly:
	$(call PYCORE_IMAGE_RUN,varkw_kwonly,100000)

pycore-img-varkw-combo:
	$(call PYCORE_IMAGE_RUN,varkw_combo,150000)

pycore-img-varkw-method:
	$(call PYCORE_IMAGE_RUN,varkw_method,150000)

pycore-img-method-call-kw:
	$(call PYCORE_IMAGE_RUN,method_call_kw,100000)

pycore-img-varkw-dup-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,varkw_dup_trap,6,50000)

pycore-img-varkw-kwonly-missing-trap:
	$(call PYCORE_IMAGE_TRAP_RUN,varkw_kwonly_missing_trap,6,50000)

pycore-img-bound-method-obj:
	$(call PYCORE_IMAGE_RUN,bound_method_obj,100000)

# Full CALL binder regression: defaults / kwargs / varargs / varkw / EX / methods.
pycore-img-call-all: \
	pycore-img-call-chain \
	pycore-img-bad-argc \
	pycore-img-noncallable \
	pycore-img-default-arg \
	pycore-img-default-arg-argc-trap \
	pycore-img-default-none \
	pycore-img-default-false-zero \
	pycore-img-default-empty-tuple \
	pycore-img-default-multi-zero-argc \
	pycore-img-default-arg-too-many \
	pycore-img-default-kwonly-none \
	pycore-img-default-partial-none \
	pycore-img-default-call-ex-empty \
	pycore-img-default-nested \
	pycore-img-method-default \
	pycore-img-varargs-pos-defaults \
	pycore-img-call-kw \
	pycore-img-call-kw-unexpected \
	pycore-img-call-function-ex \
	pycore-img-call-function-ex-kw \
	pycore-img-varargs-basic \
	pycore-img-varargs-empty \
	pycore-img-varargs-kwonly \
	pycore-img-varargs-kwonly2 \
	pycore-img-varargs-kwonly2-partial \
	pycore-img-varargs-ex-kw \
	pycore-img-varargs-call-ex \
	pycore-img-varkw-basic \
	pycore-img-varkw-empty \
	pycore-img-varkw-only \
	pycore-img-varkw-and-varargs \
	pycore-img-varkw-call-ex \
	pycore-img-varkw-posonly \
	pycore-img-posonly-kw-trap \
	pycore-img-posonly-ok \
	pycore-img-varkw-name-collision \
	pycore-img-varkw-no-wipe \
	pycore-img-varkw-many \
	pycore-img-varkw-kwonly \
	pycore-img-varkw-combo \
	pycore-img-varkw-method \
	pycore-img-method-call-kw \
	pycore-img-varkw-dup-trap \
	pycore-img-varkw-kwonly-missing-trap \
	pycore-img-bound-method-obj \
	pycore-img-method-call \
	pycore-img-method-nested \
	pycore-img-ctor-noinit \
	pycore-img-ctor-init \
	pycore-img-firmware-tuple-empty

pycore-img-method-all: \
	pycore-img-method-call \
	pycore-img-method-nested \
	pycore-img-ctor-noinit \
	pycore-img-ctor-init \
	pycore-img-default-arg \
	pycore-img-default-arg-argc-trap \
	pycore-img-default-none \
	pycore-img-default-false-zero \
	pycore-img-default-empty-tuple \
	pycore-img-default-multi-zero-argc \
	pycore-img-default-arg-too-many \
	pycore-img-default-kwonly-none \
	pycore-img-default-partial-none \
	pycore-img-default-call-ex-empty \
	pycore-img-default-nested \
	pycore-img-method-default \
	pycore-img-varargs-pos-defaults \
	pycore-img-call-kw \
	pycore-img-call-kw-unexpected \
	pycore-img-call-function-ex \
	pycore-img-call-function-ex-kw \
	pycore-img-varargs-basic \
	pycore-img-varargs-empty \
	pycore-img-varargs-kwonly \
	pycore-img-varargs-kwonly2 \
	pycore-img-varargs-kwonly2-partial \
	pycore-img-varargs-ex-kw \
	pycore-img-varargs-call-ex \
	pycore-img-varkw-method \
	pycore-img-method-call-kw \
	pycore-img-bound-method-obj

# ClassImageBuilder (M4): fold module-level class → OBK_TYPE + STORE_NAME.
pycore-img-class-simple:
	$(call PYCORE_IMAGE_RUN,class_simple,100000)

pycore-img-class-const:
	$(call PYCORE_IMAGE_RUN,class_const,100000)

pycore-img-staticmethod:
	$(call PYCORE_IMAGE_RUN,staticmethod,100000)

pycore-img-class-two-instances:
	$(call PYCORE_IMAGE_RUN,class_two_instances,100000)

pycore-img-class-all: \
	pycore-img-class-simple \
	pycore-img-class-const \
	pycore-img-staticmethod \
	pycore-img-class-two-instances

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
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oob_read.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d7 -GSTRING_HEX=\"pycore/programs/list_oob_read_str.hex\",pycore_container_list_oob_read)

pycore-container-list-oob-write:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oob_write.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d7 -GSTRING_HEX=\"pycore/programs/list_oob_write_str.hex\",pycore_container_list_oob_write)

pycore-container-dict-missing-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_missing_key.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d7 -GSTRING_HEX=\"pycore/programs/dict_missing_key_str.hex\",pycore_container_dict_missing_key)

# pycore-container-list-float-key removed: hex uses pre-3.14 inline
# 3-slot LOAD_CONST for the float key.  Equivalent type-trap coverage
# is available through image-boot fixtures.

pycore-container-tuple-store-trap:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_store_trap.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d1 -GSTRING_HEX=\"pycore/programs/tuple_store_trap_str.hex\",pycore_container_tuple_store_trap)

pycore-container-dict-full-insert:
	# Load ≥ 2/3 / last-slot insert → PY_TRAP_DICT_GROW (11), not MEM_FAULT.
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_full_insert.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d11 -GSTRING_HEX=\"pycore/programs/dict_full_insert_str.hex\" -GMAX_CYCLES=20000,pycore_container_dict_full_insert)

# HEAP_INIT_PTR = 0x1AF9C so BUILD_LIST 3 (112 bytes) exceeds PYCORE_HEAP_LIMIT
# (0x1B000; exc-info arena begins there).
pycore-container-list-oom:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oom.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d7 -GSTRING_HEX=\"pycore/programs/list_oom_str.hex\" "-GHEAP_INIT_PTR=32\'h0001af9c",pycore_container_list_oom)

# Natural FOR_ITER exhaustion skips END_FOR, so this raw stream executes
# END_FOR directly and verifies its POP_TOP-equivalent stack effect.
pycore-for-iter-fixtures:
	$(PYTHON) pycore/tools/gen_for_iter_fixtures.py

pycore-container-for-iter-end-for: pycore-for-iter-fixtures
	$(call PYCORE_CONTAINER_RUN,pycore/programs/for_iter_end_for.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d7",pycore_container_for_iter_end_for)

# list_append_fast / list_append_full_fatal (Phase A, LIST_APPEND): hand-
# built fixtures with spare-capacity/full-list layouts that source compilation
# cannot express directly. See
# pycore/tools/gen_list_append_fixtures.py for the generator (imem/dmem hex
# outputs are committed fixtures, like the other list_*.hex files).
pycore-list-append-fixtures:
	$(PYTHON) pycore/tools/gen_list_append_fixtures.py

# list_append_fast: [7] with hand-set capacity 4 (BUILD_LIST alone can never
# produce spare capacity); appends 8 and 9 via the fast path (no trap),
# subscripts both back, returns their sum (17).
pycore-container-list-append-fast: pycore-list-append-fixtures
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
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_append_full_fatal.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d9 -GSTRING_HEX=\"pycore/programs/list_append_full_fatal_str.hex\",pycore_container_list_append_full_fatal)

# list_extend_* (LIST_EXTEND): hand-built fixtures — see
# pycore/tools/gen_list_extend_fixtures.py. Non-empty extend always traps
# code 10 without excore (even with spare capacity). Empty source is a
# no-op on pycore. Unsupported iterable tags are TYPE (code 1).
# Functional spare-capacity extend is covered by pycore-excore-extend-fast-no-trap.
pycore-list-extend-fixtures:
	$(PYTHON) pycore/tools/gen_list_extend_fixtures.py

pycore-container-list-extend-fast: pycore-list-extend-fixtures
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
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d10 \
		--Mdir $(BUILD_DIR)/pycore_container_list_extend_fast \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/pycore_container_list_extend_fast/Vtb_container

pycore-container-list-extend-fast-tuple: pycore-list-extend-fixtures
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
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d10 \
		--Mdir $(BUILD_DIR)/pycore_container_list_extend_fast_tuple \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/pycore_container_list_extend_fast_tuple/Vtb_container

pycore-container-list-extend-empty: pycore-list-extend-fixtures
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
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_extend_full_fatal.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d10 -GSTRING_HEX=\"pycore/programs/list_extend_full_fatal_str.hex\",pycore_container_list_extend_full_fatal)

pycore-container-list-extend-type-fatal:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_extend_type_fatal.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d1 -GSTRING_HEX=\"pycore/programs/list_extend_type_fatal_str.hex\",pycore_container_list_extend_type_fatal)

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

# HEAP_INIT_PTR overridden near PYCORE_HEAP_LIMIT (0x1B000) so the excore's
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
		"-GHEAP_INIT_PTR=32'h0001af80" \
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d7 \
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
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d9 \
		--Mdir $(BUILD_DIR)/excore_disabled/verilator \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_container.sv
	./$(BUILD_DIR)/excore_disabled/verilator/Vtb_container

pycore-excore-extend-grow-list: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_grow_list,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd6" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

pycore-excore-extend-grow-tuple: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_grow_tuple,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd60" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

# Spare capacity still raises LIST_EXTEND (always-excore); firmware in-place copy.
pycore-excore-extend-fast-no-trap: excore-fw pycore-excore-integration-fixtures
	$(call PYCORE_EXCORE_RUN,extend_fast_no_trap,-GEXPECTED_TAG=4\'d1 "-GEXPECTED_VALUE=128'd5" -GEXPECTED_TRAP_REQ_COUNT=1 -GMAX_CYCLES=50000)

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
		"-GHEAP_INIT_PTR=32'h0001af80" \
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d7 \
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
		-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=5\'d10 \
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
	pycore-container-for-iter-end-for \
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

pycore-test: pycore-python-tests pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-mem pycore-frame pycore-frame-fib pycore-container pycore-img pycore-excore-system pycore-img-two-core

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

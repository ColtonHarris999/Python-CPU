VERILATOR ?= verilator
PYTHON ?= python3.14
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
	pycore/rtl/pycore_system.sv

PYCORE_MEM_SRCS := \
	pycore/rtl/pycore_mem_block.sv \
	pycore/rtl/pycore_mem_bank.sv

.PHONY: pycore-preprocess run-file pycore-run-file all-tests pycore-test \
	pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs \
	pycore-python-tests pycore-mem pycore-frame pycore-frame-fib \
	pycore-top pycore-multifn \
	pycore-img pycore-img-smoke pycore-img-call-chain pycore-img-str-consts \
	pycore-img-containers pycore-img-recursion pycore-img-extended-arg \
	pycore-img-branchy pycore-img-undef-global pycore-img-noncallable \
	pycore-img-bad-argc \
	pycore-container pycore-container-build-index pycore-container-store-subscr \
	pycore-container-dict-lookup pycore-container-dict-store \
	pycore-container-list-empty pycore-container-dict-multi-pair \
	pycore-container-dict-collision pycore-container-dict-insert-new-key \
	pycore-container-dict-empty pycore-container-list-nested \
	pycore-container-tuple-index pycore-container-tuple-empty \
	pycore-container-list-oob-read pycore-container-list-oob-write \
	pycore-container-dict-missing-key pycore-container-tuple-store-trap \
	pycore-container-dict-full-insert pycore-container-list-oom clean \
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
		+incdir+pycore/rtl \
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

all-tests: pycore-test

pycore-tag-decode:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_tag_decode \
		--Mdir $(BUILD_DIR)/pycore_tag_decode \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_tag_decode.sv pycore/tb/tb_tag_decode.sv
	./$(BUILD_DIR)/pycore_tag_decode/Vtb_tag_decode

pycore-exec:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
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
		+incdir+pycore/rtl \
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
		+incdir+pycore/rtl \
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
		+incdir+pycore/rtl \
		--top-module tb_mem_bank \
		--Mdir $(BUILD_DIR)/pycore_mem \
		-Wall -Wno-fatal \
		$(PYCORE_MEM_SRCS) pycore/tb/tb_mem_bank.sv
	./$(BUILD_DIR)/pycore_mem/Vtb_mem_bank

pycore-frame:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_frame \
		--Mdir $(BUILD_DIR)/pycore_frame \
		-Wall -Wno-fatal \
		pycore/rtl/pycore_frame.sv \
		pycore/tb/tb_frame.sv
	./$(BUILD_DIR)/pycore_frame/Vtb_frame

pycore-frame-fib:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
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
		+incdir+pycore/rtl \
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
		+incdir+pycore/rtl \
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
	pycore-img-bad-argc

# ---- Container (list/dict/tuple) tests -------------------------------------
# tb_container is parameterized: PROG_HEX selects the program, EXPECTED_TAG /
# EXPECTED_VALUE specify the expected base-frame return. EXPECT_TRAP /
# EXPECTED_TRAP_CODE cover negative cases.

define PYCORE_CONTAINER_RUN
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
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
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_full_insert.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/dict_full_insert_str.hex\" -GMAX_CYCLES=20000,pycore_container_dict_full_insert)

# HEAP_INIT_PTR = 0x1F9C so BUILD_LIST 3 (112 bytes) exceeds PYCORE_HEAP_LIMIT.
pycore-container-list-oom:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oom.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oom_str.hex\" "-GHEAP_INIT_PTR=32\'h00001f9c",pycore_container_list_oom)

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
	pycore-container-list-oom

pycore-test: pycore-python-tests pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-mem pycore-frame pycore-frame-fib pycore-top pycore-multifn pycore-container pycore-img

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

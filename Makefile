VERILATOR ?= verilator
BUILD_DIR ?= build
DOCKER_IMAGE ?= python-cpu-sim
DOCKER_CONTAINER_WORKDIR ?= /work
DOCKER_BUILD_FLAGS ?=
DOCKER_RUN_FLAGS ?=
PYTHON ?= python3

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

.PHONY: pycore-preprocess run-file pycore-run-file all-tests pycore-test pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-python-tests pycore-mem pycore-frame pycore-frame-fib pycore-top pycore-multifn pycore-multifn-simple pycore-multifn-const pycore-multifn-arg pycore-multifn-chain pycore-multifn-stress pycore-container pycore-container-build-index pycore-container-store-subscr pycore-container-dict-lookup pycore-container-dict-store pycore-container-list-empty pycore-container-dict-multi-pair pycore-container-dict-collision pycore-container-dict-insert-new-key pycore-container-dict-bool-key pycore-container-dict-str-key pycore-container-dict-str-key-long pycore-container-dict-empty pycore-container-list-nested pycore-container-tuple-index pycore-container-tuple-empty pycore-container-across-call pycore-container-list-oob-read pycore-container-list-oob-write pycore-container-dict-missing-key pycore-container-list-float-key pycore-container-tuple-store-trap pycore-container-dict-full-insert pycore-container-list-oom pycore-container-image-boot clean docker-build docker-run-file docker-pycore-test docker-all-tests

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
	$(PYTHON) -m unittest discover -s pycore/tests -p "test_*.py"

pycore-top:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_pycore \
		--Mdir $(BUILD_DIR)/pycore_top \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_pycore.sv
	./$(BUILD_DIR)/pycore_top/Vtb_pycore

MULTIFN_BUILD := $(BUILD_DIR)/pycore_multifn

pycore-multifn-simple:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_multifn \
		-GPROG_HEX=\"pycore/programs/multifn_simple.hex\" \
		-GEXPECTED_TAG=4\'b0001 \
		"-GEXPECTED_VALUE=128\'d42" \
		--Mdir $(BUILD_DIR)/pycore_multifn_simple \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_multifn.sv
	./$(BUILD_DIR)/pycore_multifn_simple/Vtb_multifn

pycore-multifn-const:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_multifn \
		-GPROG_HEX=\"pycore/programs/multifn_const.hex\" \
		-GEXPECTED_TAG=4\'b0001 \
		"-GEXPECTED_VALUE=128\'d1337" \
		--Mdir $(BUILD_DIR)/pycore_multifn_const \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_multifn.sv
	./$(BUILD_DIR)/pycore_multifn_const/Vtb_multifn

pycore-multifn-arg:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_multifn \
		-GPROG_HEX=\"pycore/programs/multifn_arg.hex\" \
		-GEXPECTED_TAG=4\'b0001 \
		"-GEXPECTED_VALUE=128\'d42" \
		--Mdir $(BUILD_DIR)/pycore_multifn_arg \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_multifn.sv
	./$(BUILD_DIR)/pycore_multifn_arg/Vtb_multifn

pycore-multifn-chain:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_multifn \
		-GPROG_HEX=\"pycore/programs/multifn_chain.hex\" \
		-GEXPECTED_TAG=4\'b0001 \
		"-GEXPECTED_VALUE=128\'d42" \
		--Mdir $(BUILD_DIR)/pycore_multifn_chain \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_multifn.sv
	./$(BUILD_DIR)/pycore_multifn_chain/Vtb_multifn

pycore-multifn-stress:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_multifn \
		-GPROG_HEX=\"pycore/programs/multifn_stress.hex\" \
		-GEXPECTED_TAG=4\'b0001 \
		"-GEXPECTED_VALUE=128\'d202" \
		--Mdir $(BUILD_DIR)/pycore_multifn_stress \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_multifn.sv
	./$(BUILD_DIR)/pycore_multifn_stress/Vtb_multifn

pycore-multifn: pycore-multifn-simple pycore-multifn-const pycore-multifn-arg pycore-multifn-chain pycore-multifn-stress

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

pycore-container-dict-bool-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_bool_key.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d5" -GSTRING_HEX=\"pycore/programs/dict_bool_key_str.hex\",pycore_container_dict_bool_key)

pycore-container-dict-str-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_str_key.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d42" -GSTRING_HEX=\"pycore/programs/dict_str_key_str.hex\",pycore_container_dict_str_key)

pycore-container-dict-str-key-long:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_str_key_long.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d77" -GSTRING_HEX=\"pycore/programs/dict_str_key_long_str.hex\",pycore_container_dict_str_key_long)

pycore-container-dict-empty:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_empty.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d2" -GSTRING_HEX=\"pycore/programs/dict_empty_str.hex\",pycore_container_dict_empty)

pycore-container-list-nested:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_nested.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d7" -GSTRING_HEX=\"pycore/programs/list_nested_str.hex\",pycore_container_list_nested)

pycore-container-tuple-index:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_index.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d40" -GSTRING_HEX=\"pycore/programs/tuple_index_str.hex\",pycore_container_tuple_index)

pycore-container-tuple-empty:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_empty.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d9" -GSTRING_HEX=\"pycore/programs/tuple_empty_str.hex\",pycore_container_tuple_empty)

pycore-container-across-call:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/container_across_call.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d7" -GSTRING_HEX=\"pycore/programs/container_across_call_str.hex\",pycore_container_across_call)

pycore-container-list-oob-read:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oob_read.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oob_read_str.hex\",pycore_container_list_oob_read)

pycore-container-list-oob-write:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oob_write.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oob_write_str.hex\",pycore_container_list_oob_write)

pycore-container-dict-missing-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_missing_key.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/dict_missing_key_str.hex\",pycore_container_dict_missing_key)

pycore-container-list-float-key:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_float_key.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d1 -GSTRING_HEX=\"pycore/programs/list_float_key_str.hex\",pycore_container_list_float_key)

pycore-container-tuple-store-trap:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/tuple_store_trap.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d1 -GSTRING_HEX=\"pycore/programs/tuple_store_trap_str.hex\",pycore_container_tuple_store_trap)

pycore-container-dict-full-insert:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/dict_full_insert.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/dict_full_insert_str.hex\" -GMAX_CYCLES=20000,pycore_container_dict_full_insert)

# HEAP_INIT_PTR = 0x1F9C so BUILD_LIST 3 (112 bytes) exceeds PYCORE_HEAP_LIMIT.
pycore-container-list-oom:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/list_oom.hex,-GEXPECT_TRAP=1 -GEXPECTED_TRAP_CODE=4\'d7 -GSTRING_HEX=\"pycore/programs/list_oom_str.hex\" "-GHEAP_INIT_PTR=32\'h00001f9c",pycore_container_list_oom)

# Preloaded dmem image with string-keyed dict + tuple; HEAP_INIT_PTR past static objects.
pycore-container-image-boot:
	$(call PYCORE_CONTAINER_RUN,pycore/programs/image_boot.hex,-GEXPECTED_TAG=4\'b0001 "-GEXPECTED_VALUE=128\'d141" -GSTRING_HEX=\"pycore/programs/image_boot_str.hex\" -GDMEM_HEX=\"pycore/programs/image_boot_dmem.hex\" "-GHEAP_INIT_PTR=32\'h00000550",pycore_container_image_boot)

pycore-container: \
	pycore-container-build-index \
	pycore-container-store-subscr \
	pycore-container-dict-lookup \
	pycore-container-dict-store \
	pycore-container-list-empty \
	pycore-container-dict-multi-pair \
	pycore-container-dict-collision \
	pycore-container-dict-insert-new-key \
	pycore-container-dict-bool-key \
	pycore-container-dict-str-key \
	pycore-container-dict-str-key-long \
	pycore-container-dict-empty \
	pycore-container-list-nested \
	pycore-container-tuple-index \
	pycore-container-tuple-empty \
	pycore-container-across-call \
	pycore-container-list-oob-read \
	pycore-container-list-oob-write \
	pycore-container-dict-missing-key \
	pycore-container-list-float-key \
	pycore-container-tuple-store-trap \
	pycore-container-dict-full-insert \
	pycore-container-list-oom \
	pycore-container-image-boot

pycore-test: pycore-python-tests pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-mem pycore-frame pycore-frame-fib pycore-top pycore-multifn pycore-container

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

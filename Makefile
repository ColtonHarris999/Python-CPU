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

.PHONY: pycore-preprocess run-file pycore-run-file all-tests pycore-test pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-python-tests pycore-mem pycore-frame pycore-frame-fib pycore-top pycore-multifn pycore-multifn-simple pycore-multifn-const pycore-multifn-arg pycore-multifn-chain pycore-multifn-stress clean docker-build docker-run-file docker-pycore-test docker-all-tests

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
		-GEXPECTED_TAG=4\'b0000 \
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
		-GEXPECTED_TAG=4\'b0000 \
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
		-GEXPECTED_TAG=4\'b0000 \
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
		-GEXPECTED_TAG=4\'b0000 \
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
		-GEXPECTED_TAG=4\'b0000 \
		"-GEXPECTED_VALUE=128\'d202" \
		--Mdir $(BUILD_DIR)/pycore_multifn_stress \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_multifn.sv
	./$(BUILD_DIR)/pycore_multifn_stress/Vtb_multifn

pycore-multifn: pycore-multifn-simple pycore-multifn-const pycore-multifn-arg pycore-multifn-chain pycore-multifn-stress

pycore-test: pycore-python-tests pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-mem pycore-frame pycore-frame-fib pycore-top pycore-multifn

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

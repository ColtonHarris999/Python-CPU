VERILATOR ?= verilator
BUILD_DIR ?= build
TOP ?= pycpu_core
DOCKER_IMAGE ?= python-cpu-sim
DOCKER_CONTAINER_WORKDIR ?= /work
DOCKER_BUILD_FLAGS ?=
DOCKER_RUN_FLAGS ?=
PYTHON ?= python3
PROGRAM_SOURCE ?= programs/demo_program.py
PROGRAM_FUNCTION ?= managed_entry
PROGRAM_HEX ?= programs/demo_prog.hex
CONST_HEX ?= programs/demo_consts.hex
EXPECTED_TXT ?= programs/demo_expected.txt
EXPECT_TRAP ?= 0
EXPECT_ILLEGAL ?= 0
MAX_CYCLES ?= 2000

RTL_SRCS := rtl/pycpu_core.sv
TB_SRC := tb/tb_pycpu.cpp
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
	pycore/rtl/pycore_const_table.sv \
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

.PHONY: gen-bytecode sim sim-raw build-sim test-programs pycore-test pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-python-tests pycore-mem pycore-frame pycore-top clean docker-build docker-sim docker-pycore-test

gen-bytecode:
	$(PYTHON) tools/gen_bytecode_assets.py \
		--source $(PROGRAM_SOURCE) \
		--function $(PROGRAM_FUNCTION) \
		--program-hex $(PROGRAM_HEX) \
		--const-hex $(CONST_HEX) \
		--expected $(EXPECTED_TXT)

build-sim:
	$(VERILATOR) --cc --exe --build \
		--top-module $(TOP) \
		-GPROG_HEX=\"$(PROGRAM_HEX)\" \
		-GCONST_HEX=\"$(CONST_HEX)\" \
		-Wall -Wno-fatal \
		--Mdir $(BUILD_DIR) \
		$(RTL_SRCS) $(TB_SRC)
	EXPECTED_TXT=$(EXPECTED_TXT) \
	EXPECT_TRAP=$(EXPECT_TRAP) \
	EXPECT_ILLEGAL=$(EXPECT_ILLEGAL) \
	MAX_CYCLES=$(MAX_CYCLES) \
	./$(BUILD_DIR)/V$(TOP)

sim: gen-bytecode build-sim

sim-raw: build-sim

test-programs:
	$(MAKE) sim \
		PROGRAM_SOURCE=programs/demo_program.py \
		PROGRAM_HEX=programs/demo_prog.hex \
		CONST_HEX=programs/demo_consts.hex \
		EXPECTED_TXT=programs/demo_expected.txt
	$(MAKE) sim \
		PROGRAM_SOURCE=programs/int_ops_program.py \
		PROGRAM_HEX=programs/int_ops_prog.hex \
		CONST_HEX=programs/int_ops_consts.hex \
		EXPECTED_TXT=programs/int_ops_expected.txt
	$(MAKE) sim \
		PROGRAM_SOURCE=programs/int_ops_inplace_program.py \
		PROGRAM_HEX=programs/int_ops_inplace_prog.hex \
		CONST_HEX=programs/int_ops_inplace_consts.hex \
		EXPECTED_TXT=programs/int_ops_inplace_expected.txt
	$(MAKE) sim-raw \
		PROGRAM_HEX=programs/invalid_opcode_prog.hex \
		CONST_HEX=programs/invalid_opcode_consts.hex \
		EXPECT_TRAP=1 \
		EXPECT_ILLEGAL=1

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

pycore-python-tests:
	$(PYTHON) -m unittest pycore.tests.test_type_pair_programs pycore.tests.test_preprocess_strings

pycore-top:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -sv --binary --timing \
		+incdir+pycore/rtl \
		--top-module tb_pycore \
		--Mdir $(BUILD_DIR)/pycore_top \
		-Wall -Wno-fatal \
		$(PYCORE_RTL_SRCS) pycore/tb/tb_pycore.sv
	./$(BUILD_DIR)/pycore_top/Vtb_pycore

pycore-test: pycore-python-tests pycore-tag-decode pycore-exec pycore-string-exec pycore-type-pairs pycore-mem pycore-frame pycore-top

docker-build:
	docker build $(DOCKER_BUILD_FLAGS) -t $(DOCKER_IMAGE) .

docker-sim: docker-build
	docker run --rm $(DOCKER_RUN_FLAGS) -v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make sim

docker-pycore-test: docker-build
	docker run --rm $(DOCKER_RUN_FLAGS) -v "$(CURDIR):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make pycore-test

clean:
	rm -rf $(BUILD_DIR)

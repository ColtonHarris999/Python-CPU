VERILATOR ?= verilator
BUILD_DIR ?= build
TOP ?= pycpu_core
DOCKER_IMAGE ?= python-cpu-sim
DOCKER_CONTAINER_WORKDIR ?= /work
PYTHON ?= python3
PROGRAM_SOURCE ?= programs/demo_program.py
PROGRAM_FUNCTION ?= managed_entry
PROGRAM_HEX ?= programs/demo_prog.hex
CONST_HEX ?= programs/demo_consts.hex
EXPECTED_TXT ?= programs/demo_expected.txt
EXPECT_TRAP ?= 0
EXPECT_ILLEGAL ?= 0
MAX_CYCLES ?= 2000
PYCORE_SOURCE ?= programs/bool_kernel.py
PYCORE_FUNCTION ?= managed_entry
PYCORE_PROGRAM_HEX ?= programs/pycore_prog.hex
PYCORE_CONST_HEX ?= programs/pycore_consts.hex
PYCORE_TYPES ?= programs/pycore.types

RTL_SRCS := rtl/pycpu_core.sv
TB_SRC := tb/tb_pycpu.cpp
PYCORE_RTL_SRCS := \
	rtl/pycore_types_pkg.sv \
	rtl/pycore_mul.sv \
	rtl/pycore_div.sv \
	rtl/pycore_alu.sv \
	rtl/pycore_fetch.sv \
	rtl/pycore_decode.sv \
	rtl/pycore_regfile.sv \
	rtl/pycore_branch.sv \
	rtl/pycore_trap.sv \
	rtl/pycore_frame.sv \
	rtl/pycore_const_table.sv \
	rtl/pycore_top.sv

.PHONY: gen-bytecode sim sim-raw build-sim test-programs pycore-preprocess pycore-sim pycore-alu-sim clean docker-build docker-sim

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


pycore-preprocess:
	$(PYTHON) tools/preprocess.py \
		--source $(PYCORE_SOURCE) \
		--function $(PYCORE_FUNCTION) \
		--program-hex $(PYCORE_PROGRAM_HEX) \
		--const-hex $(PYCORE_CONST_HEX) \
		--types-out $(PYCORE_TYPES)

pycore-sim: pycore-preprocess
	$(VERILATOR) -sv --binary \
		-Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/pycore \
		--top-module tb_pycore \
		$(PYCORE_RTL_SRCS) tb/tb_pycore.sv
	./$(BUILD_DIR)/pycore/Vtb_pycore

pycore-alu-sim:
	$(VERILATOR) -sv --binary \
		-Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/pycore_alu \
		--top-module tb_alu \
		rtl/pycore_types_pkg.sv rtl/pycore_mul.sv rtl/pycore_div.sv rtl/pycore_alu.sv tb/tb_alu.sv
	./$(BUILD_DIR)/pycore_alu/Vtb_alu

docker-build:
	docker build -t $(DOCKER_IMAGE) .

docker-sim: docker-build
	docker run --rm -v "$(PWD):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make sim

clean:
	rm -rf $(BUILD_DIR)

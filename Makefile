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

RTL_SRCS := rtl/pycpu_core.sv
TB_SRC := tb/tb_pycpu.cpp

.PHONY: gen-bytecode sim sim-raw build-sim test-programs clean docker-build docker-sim

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

docker-build:
	docker build -t $(DOCKER_IMAGE) .

docker-sim: docker-build
	docker run --rm -v "$(PWD):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make sim

clean:
	rm -rf $(BUILD_DIR)

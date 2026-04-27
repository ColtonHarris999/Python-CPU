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

RTL_SRCS := rtl/pycpu_core.sv
TB_SRC := tb/tb_pycpu.cpp

.PHONY: gen-bytecode sim clean docker-build docker-sim

gen-bytecode:
	$(PYTHON) tools/gen_bytecode_assets.py \
		--source $(PROGRAM_SOURCE) \
		--function $(PROGRAM_FUNCTION) \
		--program-hex $(PROGRAM_HEX) \
		--const-hex $(CONST_HEX) \
		--expected $(EXPECTED_TXT)

sim: gen-bytecode
	$(VERILATOR) --cc --exe --build \
		--top-module $(TOP) \
		-Wall -Wno-fatal \
		--Mdir $(BUILD_DIR) \
		$(RTL_SRCS) $(TB_SRC)
	./$(BUILD_DIR)/V$(TOP)

docker-build:
	docker build -t $(DOCKER_IMAGE) .

docker-sim: docker-build
	docker run --rm -v "$(PWD):$(DOCKER_CONTAINER_WORKDIR)" -w "$(DOCKER_CONTAINER_WORKDIR)" $(DOCKER_IMAGE) make sim

clean:
	rm -rf $(BUILD_DIR)

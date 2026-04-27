VERILATOR ?= verilator
BUILD_DIR ?= build
TOP ?= pycpu_core
DOCKER_IMAGE ?= python-cpu-sim
DOCKER_CONTAINER_WORKDIR ?= /work

RTL_SRCS := rtl/pycpu_core.sv
TB_SRC := tb/tb_pycpu.cpp

.PHONY: sim clean docker-build docker-sim

sim:
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

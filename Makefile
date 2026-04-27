VERILATOR ?= verilator
BUILD_DIR ?= build
TOP ?= pycpu_core

RTL_SRCS := rtl/pycpu_core.sv
TB_SRC := tb/tb_pycpu.cpp

.PHONY: sim clean

sim:
	$(VERILATOR) --cc --exe --build \
		--top-module $(TOP) \
		-Wall -Wno-fatal \
		--Mdir $(BUILD_DIR) \
		$(RTL_SRCS) $(TB_SRC)
	./$(BUILD_DIR)/V$(TOP)

clean:
	rm -rf $(BUILD_DIR)

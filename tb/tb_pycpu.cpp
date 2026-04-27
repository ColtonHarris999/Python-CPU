#include "Vpycpu_core.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vpycpu_core dut;

    dut.clk = 0;
    dut.rst_n = 0;
    dut.eval();

    for (int i = 0; i < 5; ++i) {
        dut.clk = !dut.clk;
        dut.eval();
    }

    dut.rst_n = 1;

    const int max_cycles = 200;
    for (int cycle = 0; cycle < max_cycles; ++cycle) {
        dut.clk = 0;
        dut.eval();
        dut.clk = 1;
        dut.eval();

        if (dut.halted) {
            if (dut.trap_valid) {
                std::printf("FAIL: processor trapped at cycle %d\n", cycle);
                return 1;
            }
            if (!dut.ret_valid) {
                std::printf("FAIL: halted without return value at cycle %d\n", cycle);
                return 1;
            }

            std::printf("PASS: returned %d at cycle %d\n", static_cast<int32_t>(dut.ret_value), cycle);
            if (static_cast<int32_t>(dut.ret_value) != 44) {
                std::printf("FAIL: expected return value 44\n");
                return 1;
            }
            return 0;
        }
    }

    std::printf("FAIL: timeout waiting for halt\n");
    return 1;
}

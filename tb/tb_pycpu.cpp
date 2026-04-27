#include "Vpycpu_core.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>

namespace {

int32_t load_expected_result(const char* path) {
    std::ifstream in(path);
    if (!in) {
        std::fprintf(stderr, "FAIL: unable to open expected result file: %s\n", path);
        std::exit(1);
    }

    long long value = 0;
    in >> value;
    if (!in.good() && !in.eof()) {
        std::fprintf(stderr, "FAIL: invalid integer in expected result file: %s\n", path);
        std::exit(1);
    }
    if (value < INT32_MIN || value > INT32_MAX) {
        std::fprintf(stderr, "FAIL: expected result out of int32 range: %lld\n", value);
        std::exit(1);
    }
    return static_cast<int32_t>(value);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const int32_t expected = load_expected_result("programs/demo_expected.txt");

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
            if (static_cast<int32_t>(dut.ret_value) != expected) {
                std::printf("FAIL: expected return value %d\n", expected);
                return 1;
            }
            return 0;
        }
    }

    std::printf("FAIL: timeout waiting for halt\n");
    return 1;
}

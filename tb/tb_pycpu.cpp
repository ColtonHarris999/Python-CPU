#include "Vpycpu_core.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

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

int parse_env_flag(const char* name, int default_value) {
    const char* raw = std::getenv(name);
    if (raw == nullptr || *raw == '\0') {
        return default_value;
    }
    const std::string value(raw);
    if (value == "1" || value == "true" || value == "TRUE" || value == "yes" || value == "YES") {
        return 1;
    }
    if (value == "0" || value == "false" || value == "FALSE" || value == "no" || value == "NO") {
        return 0;
    }
    std::fprintf(stderr, "FAIL: invalid boolean value for %s: %s\n", name, raw);
    std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const int expect_trap = parse_env_flag("EXPECT_TRAP", 0);
    const int expect_illegal = parse_env_flag("EXPECT_ILLEGAL", 0);
    const char* expected_path = std::getenv("EXPECTED_TXT");
    if (expected_path == nullptr || *expected_path == '\0') {
        expected_path = "programs/demo_expected.txt";
    }
    const int32_t expected = expect_trap ? 0 : load_expected_result(expected_path);

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
            if (expect_trap) {
                if (!dut.trap_valid) {
                    std::printf("FAIL: expected trap but halted without trap at cycle %d\n", cycle);
                    return 1;
                }
                if (static_cast<int>(dut.illegal_instr_valid) != expect_illegal) {
                    std::printf(
                        "FAIL: expected illegal_instr_valid=%d but got %d at cycle %d\n",
                        expect_illegal,
                        static_cast<int>(dut.illegal_instr_valid),
                        cycle
                    );
                    return 1;
                }
                std::printf(
                    "PASS: trapped as expected at cycle %d (illegal_instr_valid=%d)\n",
                    cycle,
                    static_cast<int>(dut.illegal_instr_valid)
                );
                return 0;
            }

            if (dut.trap_valid) {
                std::printf(
                    "FAIL: processor trapped at cycle %d (illegal_instr_valid=%d)\n",
                    cycle,
                    static_cast<int>(dut.illegal_instr_valid)
                );
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

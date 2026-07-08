`include "pycore_defs.svh"

module tb_pycore_runfile #(
    parameter string PROG_HEX   = "pycore/programs/run_program.hex",
    parameter string STRING_HEX = "pycore/programs/run_string_mem.hex",
    parameter int MAX_CYCLES = 2000
);
    localparam logic [2:0] CORE_S_WB = 3'd4;

    logic clk;
    logic rst_n;
    logic trap_out;
    logic [3:0] trap_code;
    logic [63:0] cycle_count;
    logic dbg_wb_we;
    logic [6:0] dbg_wb_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry;

    pycore_system #(
        .PROG_HEX(PROG_HEX),
        .STRING_HEX(STRING_HEX)
    ) dut (
        .clk_i(clk),
        .rst_n_i(rst_n),
        .trap_out_o(trap_out),
        .trap_code_o(trap_code),
        .cycle_count_o(cycle_count),
        .dbg_wb_we_o(dbg_wb_we),
        .dbg_wb_addr_o(dbg_wb_addr),
        .dbg_wb_entry_o(dbg_wb_entry)
    );

    always #5 clk = ~clk;

    logic [PYCORE_ENTRY_WIDTH-1:0] shadow [0:95];

    always_ff @(posedge clk) begin
        if (dbg_wb_we) begin
            shadow[dbg_wb_addr] <= dbg_wb_entry;
        end
    end

    initial begin
        int i;
        bit return_seen;
        logic [PYCORE_ENTRY_WIDTH-1:0] return_entry;

        clk = 1'b0;
        rst_n = 1'b0;
        return_seen = 1'b0;
        return_entry = pycore_make_entry(PY_TAG_UNINIT, '0);

        for (i = 0; i < 96; i++) begin
            shadow[i] = pycore_make_entry(PY_TAG_UNINIT, '0);
        end

        #20;
        rst_n = 1'b1;

        for (i = 0; i < MAX_CYCLES; i++) begin
            @(posedge clk);

            if (trap_out) begin
                $error("Program trapped (code=%0d) at cycle=%0d", trap_code, cycle_count);
                $finish;
            end

            if ((dut.core.state_r == CORE_S_WB) && (dut.core.cur_opcode_r == PY_OP_RETURN_VALUE)) begin
                return_seen = 1'b1;
                return_entry = dut.core.rs1_r;
                break;
            end
        end

        if (!return_seen) begin
            $error("Program did not retire RETURN_VALUE within MAX_CYCLES=%0d", MAX_CYCLES);
            $finish;
        end

        $display("RETURN_ENTRY=0x%033h", return_entry);
        $display("RETURN_TAG=%0d", pycore_get_tag(return_entry));
        $display("RETURN_VALUE_HEX=0x%032h", pycore_get_val(return_entry));
        $display("MEMORY_DUMP_BEGIN");
        for (i = 0; i < 96; i++) begin
            if (pycore_get_tag(shadow[i]) != PY_TAG_UNINIT) begin
                $display("RF[%0d]=0x%033h", i, shadow[i]);
            end
        end
        $display("MEMORY_DUMP_END");
        $display("PASS: pycore run-file completed in %0d cycles", cycle_count);
        $finish;
    end
endmodule

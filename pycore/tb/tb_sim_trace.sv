`include "pycore_defs.svh"

// Traced two-core image-boot testbench for the simulator/debugger UI.
// Always instantiates pycore_excore_system (EXCORE_EN=1). Emits a JSONL
// trace (TRACE_JSONL) with one snapshot per retired opcode (S_WB or
// completing S_CONTAINER) plus mailbox events and a terminal END record.
// Hierarchical peeks are confined to this file.
module tb_sim_trace #(
    parameter string PROG_HEX       = "build/sim_ui/program.hex",
    parameter string STRING_HEX     = "build/sim_ui/string_mem.hex",
    parameter string DMEM_HEX       = "build/sim_ui/dmem.hex",
    parameter string FW_HEX         = "build/excore_fw/list_grow.hex",
    parameter string TRACE_JSONL    = "build/sim_ui/trace.jsonl",
    parameter string DMEM_FINAL_HEX = "build/sim_ui/dmem_final.hex",
    parameter logic [31:0] HEAP_INIT_PTR = PYCORE_HEAP_BASE,
    parameter int    MAX_CYCLES     = 200000,
    parameter int    MAX_SNAPSHOTS  = 50000,
    parameter bit    BOOT_EN        = 1'b1,
    parameter bit    CHECK_ENTRY_RETURN = 1'b1,
    parameter bit    HAS_EXPECTED   = 1'b0,
    parameter logic [3:0]                  EXPECTED_TAG   = PY_TAG_INT,
    parameter logic [PYCORE_VAL_WIDTH-1:0] EXPECTED_VALUE = 128'd0
);
    localparam logic [3:0] CORE_S_WB           = 4'd4;
    localparam logic [3:0] CORE_S_CONTAINER    = 4'd8;
    localparam logic [3:0] CORE_S_FETCH        = 4'd0;
    localparam logic [3:0] CORE_S_TRAP_MARSHAL = 4'd10;
    localparam int STACK_BASE = 32;
    localparam int RF_DEPTH   = 256;
    localparam int WORDS_PER_BLOCK = (1 << PYCORE_BLOCK_SHIFT) / (PYCORE_DMEM_DATA_WIDTH / 8);
    localparam int DMEM_BLOCKS = PYCORE_DMEM_BLOCK_COUNT;

    logic clk;
    logic rst_n;
    logic trap_out;
    logic [4:0]  trap_code;
    logic [63:0] cycle_count;
    logic dbg_wb_we;
    logic [7:0]  dbg_wb_addr;
    logic [PYCORE_ENTRY_WIDTH-1:0] dbg_wb_entry;

    int unsigned trap_req_count;
    int unsigned snapshot_count;
    int fd;

    pycore_excore_system #(
        .PROG_HEX  (PROG_HEX),
        .STRING_HEX(STRING_HEX),
        .DMEM_HEX  (DMEM_HEX),
        .HEAP_INIT_PTR(HEAP_INIT_PTR),
        .BOOT_EN(BOOT_EN),
        .EXCORE_EN(1'b1),
        .FW_HEX(FW_HEX)
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

    // Constant-index dmem word peek (Verilator forbids variable gen-block index).
    function automatic logic [PYCORE_DMEM_DATA_WIDTH-1:0] peek_dmem_word(
        input int block_idx,
        input int word_idx
    );
        begin
            peek_dmem_word = '0;
            unique case (block_idx)
                0:  peek_dmem_word = dut.dmem.bank.gen_block[0].blk.mem[word_idx];
                1:  peek_dmem_word = dut.dmem.bank.gen_block[1].blk.mem[word_idx];
                2:  peek_dmem_word = dut.dmem.bank.gen_block[2].blk.mem[word_idx];
                3:  peek_dmem_word = dut.dmem.bank.gen_block[3].blk.mem[word_idx];
                4:  peek_dmem_word = dut.dmem.bank.gen_block[4].blk.mem[word_idx];
                5:  peek_dmem_word = dut.dmem.bank.gen_block[5].blk.mem[word_idx];
                6:  peek_dmem_word = dut.dmem.bank.gen_block[6].blk.mem[word_idx];
                7:  peek_dmem_word = dut.dmem.bank.gen_block[7].blk.mem[word_idx];
                8:  peek_dmem_word = dut.dmem.bank.gen_block[8].blk.mem[word_idx];
                9:  peek_dmem_word = dut.dmem.bank.gen_block[9].blk.mem[word_idx];
                10: peek_dmem_word = dut.dmem.bank.gen_block[10].blk.mem[word_idx];
                11: peek_dmem_word = dut.dmem.bank.gen_block[11].blk.mem[word_idx];
                12: peek_dmem_word = dut.dmem.bank.gen_block[12].blk.mem[word_idx];
                13: peek_dmem_word = dut.dmem.bank.gen_block[13].blk.mem[word_idx];
                14: peek_dmem_word = dut.dmem.bank.gen_block[14].blk.mem[word_idx];
                15: peek_dmem_word = dut.dmem.bank.gen_block[15].blk.mem[word_idx];
                16: peek_dmem_word = dut.dmem.bank.gen_block[16].blk.mem[word_idx];
                17: peek_dmem_word = dut.dmem.bank.gen_block[17].blk.mem[word_idx];
                18: peek_dmem_word = dut.dmem.bank.gen_block[18].blk.mem[word_idx];
                19: peek_dmem_word = dut.dmem.bank.gen_block[19].blk.mem[word_idx];
                20: peek_dmem_word = dut.dmem.bank.gen_block[20].blk.mem[word_idx];
                21: peek_dmem_word = dut.dmem.bank.gen_block[21].blk.mem[word_idx];
                22: peek_dmem_word = dut.dmem.bank.gen_block[22].blk.mem[word_idx];
                23: peek_dmem_word = dut.dmem.bank.gen_block[23].blk.mem[word_idx];
                24: peek_dmem_word = dut.dmem.bank.gen_block[24].blk.mem[word_idx];
                25: peek_dmem_word = dut.dmem.bank.gen_block[25].blk.mem[word_idx];
                26: peek_dmem_word = dut.dmem.bank.gen_block[26].blk.mem[word_idx];
                27: peek_dmem_word = dut.dmem.bank.gen_block[27].blk.mem[word_idx];
                28: peek_dmem_word = dut.dmem.bank.gen_block[28].blk.mem[word_idx];
                29: peek_dmem_word = dut.dmem.bank.gen_block[29].blk.mem[word_idx];
                30: peek_dmem_word = dut.dmem.bank.gen_block[30].blk.mem[word_idx];
                31: peek_dmem_word = dut.dmem.bank.gen_block[31].blk.mem[word_idx];
                default: peek_dmem_word = '0;
            endcase
        end
    endfunction

    task automatic dump_dmem_final;
        int bi, wi, fd_mem;
        begin
            fd_mem = $fopen(DMEM_FINAL_HEX, "w");
            if (fd_mem == 0) begin
                $error("tb_sim_trace: cannot open DMEM_FINAL_HEX=%s", DMEM_FINAL_HEX);
            end else begin
                for (bi = 0; bi < DMEM_BLOCKS; bi++) begin
                    for (wi = 0; wi < WORDS_PER_BLOCK; wi++) begin
                        $fwrite(fd_mem, "%032h\n", peek_dmem_word(bi, wi));
                    end
                end
                $fclose(fd_mem);
            end
        end
    endtask

    task automatic write_entry_hex(input logic [PYCORE_ENTRY_WIDTH-1:0] e);
        begin
            $fwrite(fd, "%033h", e);
        end
    endtask

    task automatic emit_stack_array;
        int idx;
        int first;
        logic [7:0] tos;
        begin
            tos = dut.core.tos_r[7:0];
            $fwrite(fd, "[");
            first = 1;
            if (tos > STACK_BASE[7:0]) begin
                for (idx = STACK_BASE; idx < tos; idx++) begin
                    if (!first) $fwrite(fd, ",");
                    $fwrite(fd, "\"");
                    write_entry_hex(dut.core.regfile.rf[idx]);
                    $fwrite(fd, "\"");
                    first = 0;
                end
            end
            $fwrite(fd, "]");
        end
    endtask

    task automatic emit_locals_array;
        int idx;
        int first;
        int base;
        int n;
        begin
            base = dut.core.cur_locals_base_r;
            n = 16;
            if (base + n > RF_DEPTH) n = RF_DEPTH - base;
            $fwrite(fd, "[");
            first = 1;
            for (idx = 0; idx < n; idx++) begin
                if (!first) $fwrite(fd, ",");
                $fwrite(fd, "\"");
                write_entry_hex(dut.core.regfile.rf[base + idx]);
                $fwrite(fd, "\"");
                first = 0;
            end
            $fwrite(fd, "]");
        end
    endtask

    task automatic emit_frames_array;
        // Current frame from architectural state + saved-frame count.
        // Full dmem frame-stack walk is omitted (Verilator hierarchy limits);
        // UI labels locals via co_varnames on the current code object.
        begin
            $fwrite(fd,
                "[{\"depth\":%0d,\"pc_return\":null,\"tos_base\":%0d,\"locals_base\":%0d,\"code_addr\":%0d,\"current\":true,\"saved_frames\":%0d}]",
                dut.core.frame_active_depth,
                dut.core.tos_r,
                dut.core.cur_locals_base_r,
                dut.core.cur_code_r,
                dut.core.frame_active_depth);
        end
    endtask

    task automatic emit_step(input string state_name);
        begin
            if (snapshot_count >= MAX_SNAPSHOTS) return;
            $fwrite(fd,
                "{\"t\":\"step\",\"step\":%0d,\"cycle\":%0d,\"pc\":%0d,\"opcode\":%0d,\"oparg\":%0d,\"state\":\"%s\",\"tos\":%0d,\"locals_base\":%0d,\"frame_depth\":%0d,\"mem_owner\":%0d,\"heap_ptr\":%0d,\"cur_code\":%0d,\"stack\":",
                snapshot_count,
                cycle_count,
                dut.core.cur_pc_r,
                dut.core.cur_opcode_r,
                dut.core.cur_arg_r,
                state_name,
                dut.core.tos_r,
                dut.core.cur_locals_base_r,
                dut.core.frame_active_depth,
                dut.mem_owner_r,
                dut.core.heap_ptr_r,
                dut.core.cur_code_r);
            emit_stack_array();
            $fwrite(fd, ",\"locals\":");
            emit_locals_array();
            $fwrite(fd, ",\"frames\":");
            emit_frames_array();
            $fwrite(fd, "}\n");
            snapshot_count = snapshot_count + 1;
        end
    endtask

    task automatic emit_event(
        input string kind,
        input int code,
        input int pc,
        input int opcode,
        input int arg
    );
        begin
            $fwrite(fd,
                "{\"t\":\"event\",\"step\":%0d,\"cycle\":%0d,\"kind\":\"%s\",\"code\":%0d,\"pc\":%0d,\"opcode\":%0d,\"arg\":%0d,\"mem_owner\":%0d}\n",
                (snapshot_count > 0) ? snapshot_count - 1 : 0,
                cycle_count, kind, code, pc, opcode, arg, dut.mem_owner_r);
        end
    endtask

    task automatic emit_end(
        input string status,
        input bit has_ret,
        input logic [PYCORE_ENTRY_WIDTH-1:0] ret_entry,
        input logic [4:0] got_trap
    );
        begin
            if (has_ret) begin
                $fwrite(fd,
                    "{\"t\":\"end\",\"status\":\"%s\",\"cycles\":%0d,\"opcodes\":%0d,\"trap_req_count\":%0d,\"trap_code\":%0d,\"return_tag\":%0d,\"return_value\":\"%032h\",\"expected_match\":",
                    status, cycle_count, snapshot_count, trap_req_count, got_trap,
                    pycore_get_tag(ret_entry), pycore_get_val(ret_entry));
                if (HAS_EXPECTED) begin
                    if ((pycore_get_tag(ret_entry) == EXPECTED_TAG) &&
                        (pycore_get_val(ret_entry) == EXPECTED_VALUE))
                        $fwrite(fd, "true");
                    else
                        $fwrite(fd, "false");
                end else begin
                    $fwrite(fd, "null");
                end
                $fwrite(fd, "}\n");
            end else begin
                $fwrite(fd,
                    "{\"t\":\"end\",\"status\":\"%s\",\"cycles\":%0d,\"opcodes\":%0d,\"trap_req_count\":%0d,\"trap_code\":%0d,\"return_tag\":null,\"return_value\":null,\"expected_match\":null}\n",
                    status, cycle_count, snapshot_count, trap_req_count, got_trap);
            end
        end
    endtask

    logic trap_req_fire;
    logic trap_res_fire;
    assign trap_req_fire = dut.trap_req_valid && dut.trap_req_ready;
    assign trap_res_fire = dut.trap_res_valid && dut.trap_res_ready;

    initial begin
        int i;
        bit return_seen;
        bit trap_seen;
        bit timed_out;
        logic [PYCORE_ENTRY_WIDTH-1:0] return_entry;
        logic [4:0] got_trap;
        logic [3:0] st;
        logic [3:0] st_n;

        clk = 1'b0;
        rst_n = 1'b0;
        return_seen = 0;
        trap_seen = 0;
        timed_out = 0;
        got_trap = PY_TRAP_NONE;
        trap_req_count = 0;
        snapshot_count = 0;

        fd = $fopen(TRACE_JSONL, "w");
        if (fd == 0) begin
            $error("tb_sim_trace: cannot open TRACE_JSONL=%s", TRACE_JSONL);
            $finish;
        end

        $fwrite(fd,
            "{\"t\":\"meta\",\"excore\":true,\"boot_en\":%0d,\"max_cycles\":%0d,\"heap_init_ptr\":%0d,\"prog_hex\":\"%s\"}\n",
            BOOT_EN, MAX_CYCLES, HEAP_INIT_PTR, PROG_HEX);

        #20;
        rst_n = 1'b1;

        for (i = 0; i < MAX_CYCLES; i++) begin
            @(posedge clk);

            if (trap_req_fire) begin
                // Sample core trap_req_* (stable on the handshake edge).
                // mb_* registers update via NBA on this same edge, so reading
                // them here would observe the previous mailbox payload.
                trap_req_count = trap_req_count + 1;
                emit_event("trap_req",
                           dut.core.trap_req_code_o,
                           dut.core.trap_req_pc_o,
                           dut.core.trap_req_instr_o[7:0],
                           dut.core.trap_req_instr_o[39:8]);
            end
            if (trap_res_fire) begin
                emit_event("trap_res", dut.trap_res_code, dut.core.cur_pc_r,
                           dut.core.cur_opcode_r, dut.core.cur_arg_r);
            end

            st   = dut.core.state_r;
            st_n = dut.core.state_next;

            if (st == CORE_S_WB) begin
                emit_step("S_WB");
            end else if (st == CORE_S_CONTAINER &&
                         (st_n == CORE_S_FETCH || st_n == CORE_S_TRAP_MARSHAL)) begin
                emit_step("S_CONTAINER");
            end

            if (trap_out) begin
                trap_seen = 1;
                got_trap  = trap_code;
                break;
            end

            if ((st == CORE_S_WB) &&
                (dut.core.cur_opcode_r == PY_OP_RETURN_VALUE) &&
                (dut.core.frame_active_depth ==
                    (CHECK_ENTRY_RETURN ? 8'd1 : 8'd0))) begin
                if (CHECK_ENTRY_RETURN &&
                    pycore_is_none(pycore_get_tag(dut.core.rs1_r),
                                   pycore_get_val(dut.core.rs1_r))) begin
                end else begin
                    return_seen  = 1;
                    return_entry = dut.core.rs1_r;
                    break;
                end
            end
        end

        if (i >= MAX_CYCLES) timed_out = 1;

        dump_dmem_final();

        if (timed_out) begin
            emit_end("TIMEOUT", 0, '0, got_trap);
            $display("TRACE_END TIMEOUT cycles=%0d steps=%0d", cycle_count, snapshot_count);
        end else if (trap_seen) begin
            emit_end("FATAL_TRAP", 0, '0, got_trap);
            $display("TRACE_END FATAL_TRAP code=%0d cycles=%0d steps=%0d",
                     got_trap, cycle_count, snapshot_count);
        end else if (return_seen) begin
            emit_end("PASS", 1, return_entry, got_trap);
            $display("TRACE_END PASS tag=%0d value=0x%0h cycles=%0d steps=%0d trap_reqs=%0d",
                     pycore_get_tag(return_entry), pycore_get_val(return_entry)[63:0],
                     cycle_count, snapshot_count, trap_req_count);
        end else begin
            emit_end("ERROR", 0, '0, got_trap);
            $display("TRACE_END ERROR cycles=%0d", cycle_count);
        end

        $fclose(fd);
        $finish;
    end
endmodule

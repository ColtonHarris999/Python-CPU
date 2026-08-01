`include "pycore_defs.svh"

module pycore_string_mem #(
    parameter int STRING_MEM_BYTES = 65536,
    parameter int STRING_MAX_LEN = 4096,
    parameter longint unsigned STRING_RUNTIME_BASE = 64'd16384,
    parameter string STRING_HEX = "pycore/programs/string_mem.hex"
) (
    input  logic clk_i,
    input  logic rst_n_i,

    input  logic exec_valid_i,
    input  logic [4:0] exec_alu_op_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] exec_rs1_i,
    input  logic [PYCORE_ENTRY_WIDTH-1:0] exec_rs2_i,
    output logic exec_path_valid_o,
    output logic [PYCORE_ENTRY_WIDTH-1:0] exec_result_o,
    output logic exec_trap_o,
    output logic [4:0] exec_trap_code_o,

    input  logic snapshot_valid_i,
    input  logic [3:0] snapshot_size_i,
    input  logic [119:0] snapshot_payload_i,
    output logic snapshot_ok_o,
    output logic [31:0] snapshot_addr_o,

    input  logic [31:0] read_addr_i,
    output logic [31:0] read_data_o
);

    logic [7:0] string_mem [0:STRING_MEM_BYTES-1];
    logic [63:0] string_heap_alloc_r;

    logic [3:0] rs1_tag;
    logic [3:0] rs2_tag;
    logic [PYCORE_VAL_WIDTH-1:0] rs1_value;
    logic [PYCORE_VAL_WIDTH-1:0] rs2_value;
    logic string_store_fire;
    logic [63:0] string_lhs_len;
    logic [63:0] string_rhs_len;
    logic [63:0] string_concat_len;
    logic [63:0] string_lhs_addr;
    logic [63:0] string_rhs_addr;
    logic [63:0] string_dst_addr;
    logic [119:0] string_short_payload;
    logic [63:0] string_heap_alloc_next;

    localparam logic [63:0] STRING_MEM_BYTES_U64 = STRING_MEM_BYTES;
    localparam logic [63:0] STRING_MAX_LEN_U64 = STRING_MAX_LEN;
    localparam logic [63:0] STRING_RUNTIME_BASE_U64 =
        STRING_RUNTIME_BASE[63:0];

    assign rs1_tag = pycore_get_tag(exec_rs1_i);
    assign rs2_tag = pycore_get_tag(exec_rs2_i);
    assign rs1_value = pycore_get_val(exec_rs1_i);
    assign rs2_value = pycore_get_val(exec_rs2_i);

    initial begin
        int i;
        for (i = 0; i < STRING_MEM_BYTES; i++) begin
            string_mem[i] = 8'h00;
        end
        $readmemh(STRING_HEX, string_mem);
    end

    function automatic logic [7:0] string_operand_byte(
        input logic [3:0] tag,
        input logic [PYCORE_VAL_WIDTH-1:0] value,
        input logic [63:0] idx
    );
        int unsigned mem_idx;
        begin
            if (tag == PY_TAG_SHORT_STR) begin
                string_operand_byte = pycore_short_str_byte(value, idx[3:0]);
            end else begin
                mem_idx = int'(pycore_long_str_addr(value) + idx);
                string_operand_byte = string_mem[mem_idx];
            end
        end
    endfunction

    always_comb begin
        int i;
        logic [7:0] byte_value;
        logic [63:0] lhs_end;
        logic [63:0] rhs_end;
        logic [63:0] dst_end;

        exec_path_valid_o = exec_valid_i &&
                            (exec_alu_op_i == PY_ALU_ADD) &&
                            pycore_is_string_tag(rs1_tag) &&
                            pycore_is_string_tag(rs2_tag);
        exec_result_o = pycore_make_entry(PY_TAG_OBJECT, '0);
        exec_trap_o = 1'b0;
        exec_trap_code_o = PY_TRAP_NONE;
        string_store_fire = 1'b0;
        string_lhs_len = 64'b0;
        string_rhs_len = 64'b0;
        string_concat_len = 64'b0;
        string_lhs_addr = 64'b0;
        string_rhs_addr = 64'b0;
        string_dst_addr = 64'b0;
        string_short_payload = '0;
        string_heap_alloc_next = string_heap_alloc_r;
        byte_value = 8'h00;
        lhs_end = 64'b0;
        rhs_end = 64'b0;
        dst_end = 64'b0;

        if (exec_path_valid_o) begin
            string_lhs_len = (rs1_tag == PY_TAG_SHORT_STR) ?
                             {60'b0, pycore_short_str_size(rs1_value)} :
                             pycore_long_str_size(rs1_value);
            string_rhs_len = (rs2_tag == PY_TAG_SHORT_STR) ?
                             {60'b0, pycore_short_str_size(rs2_value)} :
                             pycore_long_str_size(rs2_value);
            string_lhs_addr = (rs1_tag == PY_TAG_LONG_STR) ?
                              pycore_long_str_addr(rs1_value) : 64'b0;
            string_rhs_addr = (rs2_tag == PY_TAG_LONG_STR) ?
                              pycore_long_str_addr(rs2_value) : 64'b0;
            lhs_end = string_lhs_addr + string_lhs_len;
            rhs_end = string_rhs_addr + string_rhs_len;

            if ((rs1_tag == PY_TAG_SHORT_STR) &&
                (string_lhs_len > PYCORE_SHORT_STR_MAX_BYTES)) begin
                exec_trap_o = 1'b1;
                exec_trap_code_o = PY_TRAP_TYPE;
            end else if ((rs2_tag == PY_TAG_SHORT_STR) &&
                         (string_rhs_len > PYCORE_SHORT_STR_MAX_BYTES)) begin
                exec_trap_o = 1'b1;
                exec_trap_code_o = PY_TRAP_TYPE;
            end else if ((rs1_tag == PY_TAG_LONG_STR) &&
                         ((lhs_end < string_lhs_addr) ||
                          (lhs_end > STRING_MEM_BYTES_U64))) begin
                exec_trap_o = 1'b1;
                exec_trap_code_o = PY_TRAP_MEM_FAULT;
            end else if ((rs2_tag == PY_TAG_LONG_STR) &&
                         ((rhs_end < string_rhs_addr) ||
                          (rhs_end > STRING_MEM_BYTES_U64))) begin
                exec_trap_o = 1'b1;
                exec_trap_code_o = PY_TRAP_MEM_FAULT;
            end else begin
                string_concat_len = string_lhs_len + string_rhs_len;
                if ((string_concat_len < string_lhs_len) ||
                    (string_concat_len > STRING_MAX_LEN_U64)) begin
                    exec_trap_o = 1'b1;
                    exec_trap_code_o = PY_TRAP_MEM_FAULT;
                end else if (string_concat_len <=
                             PYCORE_SHORT_STR_MAX_BYTES) begin
                    for (i = 0; i < PYCORE_SHORT_STR_MAX_BYTES; i++) begin
                        if (i < string_concat_len) begin
                            if (i < string_lhs_len) begin
                                byte_value = string_operand_byte(
                                    rs1_tag, rs1_value, i);
                            end else begin
                                byte_value = string_operand_byte(
                                    rs2_tag, rs2_value,
                                    i - string_lhs_len);
                            end
                            string_short_payload[119-(i*8)-:8] =
                                byte_value;
                        end
                    end
                    exec_result_o = pycore_make_short_str_entry(
                        string_concat_len[3:0], string_short_payload);
                end else begin
                    string_dst_addr =
                        (string_heap_alloc_r < STRING_RUNTIME_BASE_U64) ?
                        STRING_RUNTIME_BASE_U64 : string_heap_alloc_r;
                    dst_end = string_dst_addr + string_concat_len;
                    if ((dst_end < string_dst_addr) ||
                        (dst_end > STRING_MEM_BYTES_U64)) begin
                        exec_trap_o = 1'b1;
                        exec_trap_code_o = PY_TRAP_MEM_FAULT;
                    end else begin
                        string_store_fire = 1'b1;
                        string_heap_alloc_next = dst_end;
                        exec_result_o = pycore_make_long_str_entry(
                            string_concat_len, string_dst_addr);
                    end
                end
            end
        end
    end

    always_comb begin
        logic [63:0] snapshot_end;
        snapshot_addr_o = string_heap_alloc_r[31:0];
        snapshot_end = string_heap_alloc_r + {60'b0, snapshot_size_i};
        snapshot_ok_o = snapshot_valid_i &&
                        (string_heap_alloc_r >= STRING_RUNTIME_BASE_U64) &&
                        (snapshot_end >= string_heap_alloc_r) &&
                        (snapshot_end <= STRING_MEM_BYTES_U64);
    end

    always_comb begin
        int i;
        logic [32:0] byte_addr;
        read_data_o = 32'b0;
        for (i = 0; i < 4; i++) begin
            byte_addr = {1'b0, read_addr_i} + i;
            if (byte_addr < STRING_MEM_BYTES) begin
                read_data_o[(i*8)+:8] = string_mem[byte_addr[31:0]];
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            string_heap_alloc_r <= STRING_RUNTIME_BASE_U64;
        end else if (exec_path_valid_o && !exec_trap_o &&
                     string_store_fire) begin
            int i;
            logic [7:0] byte_value;
            logic [63:0] rhs_idx;
            int unsigned dst_idx;

            for (i = 0; i < STRING_MAX_LEN; i++) begin
                if (i < string_concat_len) begin
                    if (i < string_lhs_len) begin
                        byte_value = string_operand_byte(
                            rs1_tag, rs1_value, i);
                    end else begin
                        rhs_idx = i - string_lhs_len;
                        byte_value = string_operand_byte(
                            rs2_tag, rs2_value, rhs_idx);
                    end
                    dst_idx = int'(string_dst_addr + i);
                    string_mem[dst_idx] = byte_value;
                end
            end
            string_heap_alloc_r <= string_heap_alloc_next;
        end else if (snapshot_valid_i && snapshot_ok_o) begin
            int i;
            int unsigned dst_idx;
            for (i = 0; i < PYCORE_SHORT_STR_MAX_BYTES; i++) begin
                if (i < snapshot_size_i) begin
                    dst_idx = int'(string_heap_alloc_r + i);
                    string_mem[dst_idx] =
                        snapshot_payload_i[119-(i*8)-:8];
                end
            end
            string_heap_alloc_r <= string_heap_alloc_r +
                                   {60'b0, snapshot_size_i};
        end
    end

endmodule

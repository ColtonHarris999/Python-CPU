`ifndef _riscv_multicycle
`define _riscv_multicycle
/*

This is a very simple 5 stage multicycle RISC-V 32bit design.

The stages are fetch, decode, execute, memory, writeback

*/

`include "base.sv"
`include "system.sv"
`include "riscv.sv"

module riscv_multicycle #(

    ) (
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp);

import riscv::*;

typedef enum {
    stage_fetch
    ,stage_decode
    ,stage_execute
    ,stage_mem
    ,stage_writeback
}   stage;

stage   current_stage;


/*

 Instruction fetch

*/

word_address    pc;
instr32 instruction_read;
// Stage through a word: tools reject part-selects on function returns.
word instruction_read_word;

always_comb begin
    inst_mem_req = memory_io_no_req;
    inst_mem_req.addr = pc;
    inst_mem_req.user_tag = (`user_tag_size)'(0);
    inst_mem_req.valid = inst_mem_rsp.ready
                            && (stage_fetch == current_stage);
    inst_mem_req.do_read[3:0] = (stage_fetch == current_stage) ? 4'b1111 : 0;
    instruction_read_word = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr);
    instruction_read = instruction_read_word[31:0];
end

instr32    latched_instruction_read;
always_ff @(posedge clk) begin
    if (inst_mem_rsp.valid)
        latched_instruction_read <= instruction_read;

end

instr32    fetched_instruction;
assign fetched_instruction = (inst_mem_rsp.valid) ? instruction_read : latched_instruction_read;

/*

  Instruction decode

*/
tag     rs1;
tag     rs2;
word    rd1;
word    rd2;
tag     wbs;
word    wbd;
logic   wbv;
word    reg_file_rd1;
word    reg_file_rd2;
word    imm;
funct3  f3;
funct7  f7;
opcode_q op_q;
instr_format format;
bool     is_memory_op;

word    reg_file[0:31];

always_comb begin
    rs1 = decode_rs1(fetched_instruction);
    rs2 = decode_rs2(fetched_instruction);
    wbs = decode_rd(fetched_instruction);
    f3 = decode_funct3(fetched_instruction);
    op_q = decode_opcode_q(fetched_instruction);
    format = decode_format(op_q);
    imm = decode_imm(fetched_instruction, format);
    wbv = decode_writeback(op_q);
    f7 = decode_funct7(fetched_instruction, format);
end

logic read_reg_valid;
logic write_reg_valid;

always_ff @(posedge clk) begin
    if (read_reg_valid) begin
        reg_file_rd1 <= reg_file[rs1];
        reg_file_rd2 <= reg_file[rs2];
    end
    else if (write_reg_valid)
        reg_file[wbs] <= wbd;
end

logic memory_stage_complete;
always_comb begin
    if (op_q == q_load || op_q == q_store || op_q == q_amo) begin
        if (data_mem_rsp.valid)
            memory_stage_complete = true;
        else
            memory_stage_complete = false;
    end else
        memory_stage_complete = true;
end

always_comb begin
    read_reg_valid = false;
    write_reg_valid = false;
    if (current_stage == stage_decode) begin
        read_reg_valid = true;
    end

    if (memory_stage_complete && current_stage == stage_writeback && wbv) begin
        write_reg_valid = true;
    end
end

/*

 Instruction execute

 */

always_comb begin
    if (rs1 == `tag_size'd0)
        rd1 = `word_size'd0;
    else
        rd1 = reg_file_rd1;        
    if (rs2 == `tag_size'd0)
        rd2 = `word_size'd0;
    else
        rd2 = reg_file_rd2;        
end

ext_operand exec_result_comb;
word next_pc_comb;
always_comb begin
    exec_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(imm),
        pc,
        op_q,
        f3,
        f7);
    next_pc_comb = compute_next_pc(
        cast_to_ext_operand(rd1),
        exec_result_comb,
        imm,
        pc,
        op_q,
        f3);
end

word exec_result;
word next_pc;
always_ff @(posedge clk) begin
    if (current_stage == stage_execute) begin
        //$display("pc=%x rd1=%x rd2=%x imm=%x, op_q=%x exec_result = %x",
        //    pc,
        //    rd1, rd2, imm, op_q,
        //    exec_result_comb[`word_size-1:0]);
        exec_result <= exec_result_comb[`word_size-1:0];
        next_pc <= next_pc_comb;

        //$display("%x: %b - %x = %x %x (imm=%x)", pc, op_q, exec_result_comb[`word_size - 1:0], rd1, rd2, imm);


    end
end

/*

  Stage and mem

 */

always_comb begin
    data_mem_req = memory_io_no_req;
    if (data_mem_rsp.ready && current_stage == stage_mem &&
        (op_q == q_store || op_q == q_load || op_q == q_amo)) begin
        data_mem_req.user_tag = `user_tag_size'(0);
        if (op_q == q_store) begin
            data_mem_req.addr = exec_result[`word_address_size - 1:0];
            data_mem_req.valid = true;
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result);
            data_mem_req.data = shuffle_store_data(rd2, exec_result);
        end
        else if (op_q == q_load) begin
            data_mem_req.addr = exec_result[`word_address_size - 1:0];
            data_mem_req.valid = true;
            data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result);
        end 
        else if (op_q == q_amo) begin
            // AMO path is unused by excore firmware; keep a full-word
            // placeholder so RV32 elaborates without 64-bit-only f3_amo_d.
            data_mem_req.addr = rd1;
            data_mem_req.data = rd2;
            data_mem_req.valid = true;
            data_mem_req.do_write = {(`word_size_bytes){1'b1}};
            data_mem_req.do_read = {(`word_size_bytes){1'b1}};
        end
     end
end

word load_result;
always_ff @(posedge clk) begin
    if (data_mem_rsp.valid)
        load_result <= data_mem_rsp.data;
end

always_comb begin
    if (op_q == q_load)
        wbd = subset_load_data(
                    shuffle_load_data(data_mem_rsp.valid ? data_mem_rsp.data : load_result, exec_result),
                    cast_to_memory_op(f3));
    else
        wbd = exec_result;

end

always_ff @(posedge clk) begin
    if (reset)
        pc <= reset_pc;
    else begin
        if (current_stage == stage_writeback)
            pc <= next_pc;
    end
end

/*

 Stage control

 */
always_ff @(posedge clk) begin
    if (reset)
        current_stage <= stage_fetch;
    else begin
        case (current_stage)
            stage_fetch:
                if (inst_mem_rsp.valid)
                    current_stage <= stage_decode;
            stage_decode:
                if (inst_mem_rsp.valid)
                    current_stage <= stage_execute;
            stage_execute:
                current_stage <= stage_mem;
            stage_mem:
                current_stage <= stage_writeback;
            stage_writeback:
                if (memory_stage_complete)
                    current_stage <= stage_fetch;
            default:
                current_stage <= stage_fetch;
        endcase
    end
end

endmodule : riscv_multicycle
`endif

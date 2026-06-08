`include "pycore_defs.svh"

module pycore_top (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [39:0] imem_rdata,
    output logic        trap_out,
    output logic [3:0]  trap_code,
    output logic [63:0] cycle_count
);

    logic        fetch_valid;
    logic [7:0]  fetch_opcode;
    logic [31:0] fetch_arg;
    logic [31:0] fetch_pc;
    logic        decoded_valid;
    logic [4:0]  alu_op;
    logic [6:0]  rs1_sel;
    logic [6:0]  rs2_sel;
    logic [6:0]  rd_sel;
    logic        is_branch;
    logic        is_call;
    logic        is_return;
    logic        push_stack;
    logic        pop_stack;
    logic [2:0]  mem_op;
    logic        illegal_opcode;
    logic [31:0] decoded_pc;
    logic [66:0] rs1_entry;
    logic [66:0] rs2_entry;
    logic [66:0] exec_result;
    logic        exec_stall;
    logic        exec_trap;
    logic [3:0]  exec_trap_code;
    logic        stack_fault;
    logic [5:0]  tos_ptr_small;
    logic [5:0]  locals_base_small;
    logic [6:0]  tos_ptr;
    logic [6:0]  locals_base;
    logic        freeze_pipeline;

    assign tos_ptr_small = tos_ptr[5:0];
    assign locals_base_small = locals_base[5:0];

    pycore_fetch fetch (
        .clk(clk),
        .rst_n(rst_n),
        .stall(exec_stall || freeze_pipeline),
        .flush(1'b0),
        .branch_taken(1'b0),
        .branch_target(32'b0),
        .imem_addr(imem_addr),
        .imem_rdata(imem_rdata),
        .instr_valid(fetch_valid),
        .opcode(fetch_opcode),
        .arg(fetch_arg),
        .pc(fetch_pc)
    );

    pycore_decode decode (
        .instr_valid(fetch_valid),
        .opcode(fetch_opcode),
        .arg(fetch_arg),
        .pc(fetch_pc),
        .tos_index(tos_ptr_small),
        .locals_base(locals_base_small),
        .decoded_valid(decoded_valid),
        .alu_op(alu_op),
        .rs1_sel(rs1_sel),
        .rs2_sel(rs2_sel),
        .rd_sel(rd_sel),
        .is_branch(is_branch),
        .is_call(is_call),
        .is_return(is_return),
        .push_stack(push_stack),
        .pop_stack(pop_stack),
        .mem_op(mem_op),
        .illegal_opcode(illegal_opcode),
        .decoded_pc(decoded_pc)
    );

    pycore_regfile regfile (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr(rs1_sel[$clog2(96)-1:0]),
        .rs2_addr(rs2_sel[$clog2(96)-1:0]),
        .rs1(rs1_entry),
        .rs2(rs2_entry),
        .rd_we(decoded_valid && !illegal_opcode && !exec_trap && (alu_op != PY_ALU_PASS)),
        .rd_addr(rd_sel[$clog2(96)-1:0]),
        .rd(exec_result),
        .set_locals_base(1'b0),
        .new_locals_base('0),
        .init_frame(1'b0),
        .push_stack(push_stack && decoded_valid),
        .pop_stack(pop_stack && decoded_valid),
        .tos_ptr(tos_ptr[$clog2(96)-1:0]),
        .locals_base(locals_base[$clog2(96)-1:0]),
        .stack_fault(stack_fault)
    );

    pycore_exec exec (
        .clk(clk),
        .rst_n(rst_n),
        .valid(decoded_valid && !illegal_opcode && mem_op == PY_MEM_NONE),
        .alu_op(alu_op),
        .rs1(rs1_entry),
        .rs2(rs2_entry),
        .result(exec_result),
        .stall(exec_stall),
        .trap(exec_trap),
        .trap_code(exec_trap_code)
    );

    pycore_trap trap_block (
        .clk(clk),
        .rst_n(rst_n),
        .type_trap(exec_trap && exec_trap_code == PY_TRAP_TYPE),
        .stack_fault(stack_fault),
        .div_zero(exec_trap && exec_trap_code == PY_TRAP_DIV_ZERO),
        .fpu_exception(exec_trap && exec_trap_code == PY_TRAP_FPU_EXCEPTION),
        .illegal_opcode(illegal_opcode || (exec_trap && exec_trap_code == PY_TRAP_ILLEGAL_OPCODE)),
        .fault_pc(decoded_pc),
        .fault_rs1(rs1_entry),
        .fault_rs2(rs2_entry),
        .trap_out(trap_out),
        .trap_code(trap_code),
        .trap_pc(),
        .trap_rs1(),
        .trap_rs2(),
        .freeze_pipeline(freeze_pipeline)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 64'b0;
        end else if (!trap_out) begin
            cycle_count <= cycle_count + 1'b1;
        end
    end

endmodule

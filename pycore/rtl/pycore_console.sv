`include "pycore_defs.svh"

// Memory-mapped console (accelerator_split_plan.md §7.2).
// Channel c lives at IO_BASE + c*0x100.
//   +0x00 TX_STR   SHORT_STR value; emits `size` bytes
//   +0x10 TX_RAW   strobed bytes, low address first
//   +0x20 MARK     low byte (PHASE_MARK ids 0x01-0x07 stay in band)
//   +0x30 STATUS   read as 0 (space available)
// A store is accepted only when the byte shifter is empty, then acked.
// Bytes leave one per cycle afterwards, in program order.
module pycore_console (
    input  logic              clk_i,
    input  logic              rst_n_i,
    input  logic              req_i,
    input  logic              we_i,
    input  logic [31:0]       addr_i,
    input  logic [127:0]      wdata_i,
    input  logic [15:0]       wstrb_i,
    output logic              ack_o,
    output logic              fault_o,
    output logic              emit_valid_o,
    output logic [7:0]        emit_byte_o
);
    logic [7:0] buf_r [0:15];
    logic [4:0] left_r;
    logic       ack_r;
    logic       fault_r;

    wire        in_window = (addr_i >= PYCORE_IO_BASE) && (addr_i < PYCORE_IO_LIMIT);
    wire [7:0]  ch_off = addr_i[7:0];
    wire        tx_str  = we_i && (ch_off == 8'h00);
    wire        tx_raw  = we_i && (ch_off == 8'h10);
    wire        tx_mark = we_i && (ch_off == 8'h20);
    wire [3:0]  slen = pycore_short_str_size(wdata_i);

    logic [4:0] push_n;
    logic [7:0] push_b [0:15];
    integer i;
    always_comb begin
        push_n = 5'd0;
        for (i = 0; i < 16; i++) push_b[i] = 8'h00;
        if (tx_str) begin
            push_n = {1'b0, slen};
            for (i = 0; i < 15; i++) begin
                if (i < int'(slen))
                    push_b[i] = pycore_short_str_byte(wdata_i, i);
            end
        end else if (tx_raw) begin
            for (i = 0; i < 16; i++) begin
                if (wstrb_i[i]) begin
                    push_b[push_n] = wdata_i[i*8 +: 8];
                    push_n = push_n + 5'd1;
                end
            end
        end else if (tx_mark) begin
            push_n    = 5'd1;
            push_b[0] = wdata_i[7:0];
        end
    end

    wire accept = req_i && in_window && we_i && (left_r == 5'd0);
    wire reply  = req_i && (left_r == 5'd0) && !accept;

    assign ack_o        = ack_r;
    assign fault_o      = fault_r;
    assign emit_valid_o = (left_r != 5'd0);
    assign emit_byte_o  = buf_r[0];

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            left_r  <= '0;
            ack_r   <= 1'b0;
            fault_r <= 1'b0;
            for (i = 0; i < 16; i++) buf_r[i] <= 8'h00;
        end else begin
            ack_r   <= 1'b0;
            fault_r <= 1'b0;
            if (left_r != 5'd0) begin
                for (i = 0; i < 15; i++) buf_r[i] <= buf_r[i+1];
                buf_r[15] <= 8'h00;
                left_r    <= left_r - 5'd1;
            end else if (accept) begin
                for (i = 0; i < 16; i++) buf_r[i] <= push_b[i];
                left_r  <= push_n;
                ack_r   <= 1'b1;
                fault_r <= 1'b0;
            end else if (reply) begin
                ack_r   <= 1'b1;
                fault_r <= !in_window;
            end
        end
    end
endmodule

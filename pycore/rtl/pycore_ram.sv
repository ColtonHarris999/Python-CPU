`include "pycore_defs.svh"

// Behavioral backing store for the unified L2 (memory_system_plan.md P2).
//
// Two physical arrays share one 128-bit req/ack port:
//   * data_mem — PYCORE_RAM_BYTES (16 MB) covering the data map.
//   * code_mem — packed 128-bit view of the Harvard code space, addressed
//     at PYCORE_CODE_ADDR_BASE in the unified namespace.
//
// Local calls (do not change the §0 port contract, the architectural
// memory map the core sees, or retired results):
//   * Code lives in a side array rather than past the 16 MB data window
//     (0x0100_0000 is just above RAM_BYTES). Hex preload matches today's
//     PROG_HEX / CODE_RAM_HEX plusargs.
//   * DATA_LIMIT defaults to the current 128 KB dmem so out-of-range
//     accesses still fault. P5 widens this when strings move into dmem.
//
// Timing: a request is captured the cycle `req_i` is high. `ack_o` pulses
// `t_first_i` cycles later (min 1, matching today's SRAM bank). A line
// burst (`line_i`) then delivers the remaining beats `t_beat` cycles apart.
module pycore_ram #(
    parameter int    ADDR_WIDTH  = PYCORE_ADDR_WIDTH,
    parameter int    DATA_WIDTH  = PYCORE_DMEM_DATA_WIDTH,
    parameter int    LINE_BYTES  = PYCORE_LINE_BYTES,
    parameter int    RAM_BYTES   = PYCORE_RAM_BYTES,
    parameter int    T_BEAT      = PYCORE_RAM_T_BEAT,
    parameter int    DATA_LIMIT  = PYCORE_DMEM_BYTES,
    parameter logic [31:0] CODE_BASE = PYCORE_CODE_ADDR_BASE,
    parameter string DMEM_HEX     = "",
    parameter string PROG_HEX     = "",
    parameter string CODE_RAM_HEX = "",
    parameter string DMEM_PLUSARG     = "DMEM_HEX",
    parameter string PROG_PLUSARG     = "PROG_HEX",
    parameter string CODE_RAM_PLUSARG = "CODE_RAM_HEX"
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,
    input  int                    t_first_i,
    input  logic                  req_i,
    input  logic                  we_i,
    input  logic                  line_i,
    input  logic [DATA_WIDTH/8-1:0] wstrb_i,
    input  logic [ADDR_WIDTH-1:0] addr_i,
    input  logic [DATA_WIDTH-1:0] wdata_i,
    output logic                  ack_o,
    output logic                  last_o,
    output logic [DATA_WIDTH-1:0] rdata_o,
    output logic                  fault_o
);
    localparam int BYTE_SHIFT      = $clog2(DATA_WIDTH / 8);
    localparam int BEATS           = LINE_BYTES / (DATA_WIDTH / 8);
    localparam int BEAT_W          = $clog2(BEATS);
    localparam int DATA_WORDS      = RAM_BYTES / (DATA_WIDTH / 8);
    localparam int CODE_BYTES      = PYCORE_CODE_RAM_BYTE_BASE
                                   + (PYCORE_CODE_RAM_SLOTS << 3);
    localparam int CODE_WORDS      = CODE_BYTES / (DATA_WIDTH / 8);
    localparam int CODE_ROM_WORDS  = PYCORE_CODE_RAM_BYTE_BASE / (DATA_WIDTH / 8);
    localparam int ROM_SLOTS       = PYCORE_CODE_RAM_BYTE_BASE >> 3;
    localparam int RAM_SLOTS       = PYCORE_CODE_RAM_SLOTS;

    logic [DATA_WIDTH-1:0] data_mem [0:DATA_WORDS-1];
    logic [DATA_WIDTH-1:0] code_arr [0:CODE_WORDS-1];

    typedef enum logic [1:0] { ST_IDLE, ST_WAIT, ST_BEAT } state_e;
    state_e state_r;

    logic                   cap_we_r;
    logic                   cap_line_r;
    logic [DATA_WIDTH/8-1:0] cap_wstrb_r;
    logic [ADDR_WIDTH-1:0]  cap_addr_r;
    logic [BEAT_W-1:0]      beat_r;
    int                     wait_r;
    logic                   ack_r;
    logic                   last_r;
    logic                   fault_r;
    logic [DATA_WIDTH-1:0]  rdata_r;

    function automatic int t_first_eff();
        t_first_eff = (t_first_i < 1) ? 1 : t_first_i;
    endfunction

    function automatic int t_beat_eff();
        t_beat_eff = (T_BEAT < 1) ? 1 : T_BEAT;
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] beat_addr(
        input logic [ADDR_WIDTH-1:0] base,
        input logic [BEAT_W-1:0] beat
    );
        beat_addr = {base[ADDR_WIDTH-1:$clog2(LINE_BYTES)], {$clog2(LINE_BYTES){1'b0}}}
                  + (ADDR_WIDTH'(beat) << BYTE_SHIFT);
    endfunction

    // Index/fault/rdata are module wires, not function-local NBA RHS.
    // Function-local indices used as NBA RHS come back as 0 in this sim.
    wire [ADDR_WIDTH-1:0] idle_addr = addr_i;
    wire [ADDR_WIDTH-1:0] cap_beat_addr =
        cap_line_r ? beat_addr(cap_addr_r, beat_r) : cap_addr_r;

    wire idle_is_code = (idle_addr >= ADDR_WIDTH'(CODE_BASE));
    wire cap_is_code  = (cap_beat_addr >= ADDR_WIDTH'(CODE_BASE));
    wire [ADDR_WIDTH-1:0] idle_coff = idle_addr - ADDR_WIDTH'(CODE_BASE);
    wire [ADDR_WIDTH-1:0] cap_coff  = cap_beat_addr - ADDR_WIDTH'(CODE_BASE);

    wire idle_fault = idle_is_code
        ? ((idle_coff >= ADDR_WIDTH'(CODE_BYTES)) ||
           (we_i && (idle_coff < ADDR_WIDTH'(PYCORE_CODE_RAM_BYTE_BASE))))
        : (idle_addr >= ADDR_WIDTH'(DATA_LIMIT));
    wire cap_fault = cap_is_code
        ? ((cap_coff >= ADDR_WIDTH'(CODE_BYTES)) ||
           (cap_we_r && (cap_coff < ADDR_WIDTH'(PYCORE_CODE_RAM_BYTE_BASE))))
        : (cap_beat_addr >= ADDR_WIDTH'(DATA_LIMIT));

    wire [ADDR_WIDTH-BYTE_SHIFT-1:0] idle_data_idx = idle_addr >> BYTE_SHIFT;
    wire [ADDR_WIDTH-BYTE_SHIFT-1:0] idle_code_idx = idle_coff >> BYTE_SHIFT;
    wire [ADDR_WIDTH-BYTE_SHIFT-1:0] cap_data_idx  = cap_beat_addr >> BYTE_SHIFT;
    wire [ADDR_WIDTH-BYTE_SHIFT-1:0] cap_code_idx  = cap_coff >> BYTE_SHIFT;

    wire [DATA_WIDTH-1:0] idle_rdata = idle_is_code
        ? ((idle_code_idx < CODE_WORDS) ? code_arr[idle_code_idx] : '0)
        : ((idle_data_idx < DATA_WORDS) ? data_mem[idle_data_idx] : '0);
    wire [DATA_WIDTH-1:0] cap_rdata = cap_is_code
        ? ((cap_code_idx < CODE_WORDS) ? code_arr[cap_code_idx] : '0)
        : ((cap_data_idx < DATA_WORDS) ? data_mem[cap_data_idx] : '0);

    function automatic logic [DATA_WIDTH-1:0] merge_strb(
        input logic [DATA_WIDTH-1:0] old_w,
        input logic [DATA_WIDTH-1:0] d,
        input logic [DATA_WIDTH/8-1:0] strb
    );
        merge_strb = old_w;
        for (int b = 0; b < DATA_WIDTH/8; b++) begin
            if (strb[b])
                merge_strb[8*b +: 8] = d[8*b +: 8];
        end
    endfunction

    initial begin
        int i;
        int wi;
        string dmem_path, prog_path, cram_path;
    logic [63:0] slot_tmp [0:RAM_SLOTS-1];

        dmem_path = DMEM_HEX;
        prog_path = PROG_HEX;
        cram_path = CODE_RAM_HEX;
        if (DMEM_PLUSARG.len() > 0)
            void'($value$plusargs({DMEM_PLUSARG, "=%s"}, dmem_path));
        if (PROG_PLUSARG.len() > 0)
            void'($value$plusargs({PROG_PLUSARG, "=%s"}, prog_path));
        if (CODE_RAM_PLUSARG.len() > 0)
            void'($value$plusargs({CODE_RAM_PLUSARG, "=%s"}, cram_path));

        if (dmem_path.len() > 0)
            $readmemh(dmem_path, data_mem);

        for (i = 0; i < RAM_SLOTS; i++)
            slot_tmp[i] = '0;
        if (prog_path.len() > 0)
            $readmemh(prog_path, slot_tmp);
        for (i = 0; i < ROM_SLOTS; i++) begin
            wi = i / 2;
            if (i[0] == 1'b0)
                code_arr[wi][63:0] = slot_tmp[i];
            else
                code_arr[wi][127:64] = slot_tmp[i];
        end

        for (i = 0; i < RAM_SLOTS; i++)
            slot_tmp[i] = '0;
        if (cram_path.len() > 0)
            $readmemh(cram_path, slot_tmp);
        for (i = 0; i < RAM_SLOTS; i++) begin
            wi = CODE_ROM_WORDS + (i / 2);
            if (i[0] == 1'b0)
                code_arr[wi][63:0] = slot_tmp[i];
            else
                code_arr[wi][127:64] = slot_tmp[i];
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic last_beat;
        int   nxt_wait;

        if (!rst_n_i) begin
            state_r     <= ST_IDLE;
            cap_we_r    <= 1'b0;
            cap_line_r  <= 1'b0;
            cap_wstrb_r <= '0;
            cap_addr_r  <= '0;
            beat_r      <= '0;
            wait_r      <= 0;
            ack_r       <= 1'b0;
            last_r      <= 1'b0;
            fault_r     <= 1'b0;
            rdata_r     <= '0;
        end else begin
            ack_r  <= 1'b0;
            last_r <= 1'b0;

            unique case (state_r)
                ST_IDLE: begin
                    if (req_i) begin
                        cap_we_r    <= we_i;
                        cap_line_r  <= line_i;
                        cap_wstrb_r <= wstrb_i;
                        cap_addr_r  <= addr_i;
                        beat_r      <= '0;
                        if (t_first_eff() <= 1) begin
                            last_beat = !line_i;
                            ack_r     <= 1'b1;
                            last_r    <= !line_i;
                            fault_r   <= idle_fault;
                            if (!idle_fault && we_i) begin
                                if (idle_is_code)
                                    code_arr[idle_code_idx] <=
                                        merge_strb(code_arr[idle_code_idx], wdata_i,
                                                   line_i ? {DATA_WIDTH/8{1'b1}} : wstrb_i);
                                else
                                    data_mem[idle_data_idx] <=
                                        merge_strb(data_mem[idle_data_idx], wdata_i,
                                                   line_i ? {DATA_WIDTH/8{1'b1}} : wstrb_i);
                            end
                            rdata_r <= idle_fault ? '0 : idle_rdata;
                            if (!last_beat) begin
                                beat_r <= BEAT_W'(1);
                                nxt_wait = t_beat_eff();
                                if (nxt_wait <= 1)
                                    state_r <= ST_BEAT;
                                else begin
                                    wait_r  <= nxt_wait;
                                    state_r <= ST_WAIT;
                                end
                            end
                        end else begin
                            wait_r  <= t_first_eff() - 1;
                            state_r <= ST_WAIT;
                        end
                    end
                end
                ST_WAIT: begin
                    if (wait_r <= 1) begin
                        last_beat = !cap_line_r || (beat_r == BEAT_W'(BEATS - 1));
                        ack_r     <= 1'b1;
                        last_r    <= !cap_line_r || (beat_r == BEAT_W'(BEATS - 1));
                        fault_r   <= cap_fault;
                        if (!cap_fault && cap_we_r) begin
                            if (cap_is_code)
                                code_arr[cap_code_idx] <=
                                    merge_strb(code_arr[cap_code_idx], wdata_i,
                                               cap_line_r ? {DATA_WIDTH/8{1'b1}} : cap_wstrb_r);
                            else
                                data_mem[cap_data_idx] <=
                                    merge_strb(data_mem[cap_data_idx], wdata_i,
                                               cap_line_r ? {DATA_WIDTH/8{1'b1}} : cap_wstrb_r);
                        end
                        rdata_r <= cap_fault ? '0 : cap_rdata;
                        if (last_beat)
                            state_r <= ST_IDLE;
                        else begin
                            beat_r <= beat_r + BEAT_W'(1);
                            nxt_wait = t_beat_eff();
                            if (nxt_wait <= 1)
                                state_r <= ST_BEAT;
                            else begin
                                wait_r  <= nxt_wait;
                                state_r <= ST_WAIT;
                            end
                        end
                    end else
                        wait_r <= wait_r - 1;
                end
                ST_BEAT: begin
                    last_beat = !cap_line_r || (beat_r == BEAT_W'(BEATS - 1));
                    ack_r     <= 1'b1;
                    last_r    <= !cap_line_r || (beat_r == BEAT_W'(BEATS - 1));
                    fault_r   <= cap_fault;
                    if (!cap_fault && cap_we_r) begin
                        if (cap_is_code)
                            code_arr[cap_code_idx] <=
                                merge_strb(code_arr[cap_code_idx], wdata_i,
                                           cap_line_r ? {DATA_WIDTH/8{1'b1}} : cap_wstrb_r);
                        else
                            data_mem[cap_data_idx] <=
                                merge_strb(data_mem[cap_data_idx], wdata_i,
                                           cap_line_r ? {DATA_WIDTH/8{1'b1}} : cap_wstrb_r);
                    end
                    rdata_r <= cap_fault ? '0 : cap_rdata;
                    if (last_beat)
                        state_r <= ST_IDLE;
                    else begin
                        beat_r <= beat_r + BEAT_W'(1);
                        nxt_wait = t_beat_eff();
                        if (nxt_wait <= 1)
                            state_r <= ST_BEAT;
                        else begin
                            wait_r  <= nxt_wait;
                            state_r <= ST_WAIT;
                        end
                    end
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end

    assign ack_o   = ack_r;
    assign last_o  = last_r;
    assign rdata_o = rdata_r;
    assign fault_o = fault_r;
endmodule

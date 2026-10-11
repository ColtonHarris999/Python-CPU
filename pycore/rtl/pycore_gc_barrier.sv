`include "pycore_defs.svh"

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// pycore_gc_barrier: the generational write barrier (gc_gen_protocol.md §3).
//
// Owner logging. A container operation that can store a reference to a
// younger object into an existing owner pulses log_i once, with the owner
// and the windows it will write (B1). The entry {kind, size, addr} goes
// through a direct-mapped dedup filter into the sequential store buffer
// (SSB). A filter hit drops a duplicate; a miss only ever duplicates an
// entry, it never loses one. The barrier never reads the mark bitmap: the
// engine's P_REMSET skips owners that turn out to be young (B4).
//
// Windows. permit_i adds windows without an entry (B2). op_begin_i empties
// them. A write the guard sees (wr_i: a managed write by a guarded master,
// outside the current run) that lies in no window is a guard hit (B3); the
// core turns it into a forced major. Windows count only for the container
// leg (wr_cont_i): another master never inherits an operation's windows.
//
// The SSB, the filter and the windows are emptied by clear_i, which the core
// raises when a collection ends (E4). A push into a full SSB is refused and
// reported on overflow_o, which forces a major (B6).
module pycore_gc_barrier #(
    parameter int SSB_ENTRIES = PYCORE_GC_REMSET_ENTRIES,
    parameter int FILTER      = 32,
    parameter int NWIN        = 8
) (
    input  logic         clk_i,
    input  logic         rst_n_i,
    input  logic         en_i,
    input  logic [7:0]   mutant_i,
    // Entries the SSB may hold (0: SSB_ENTRIES); tests shrink it.
    input  logic [31:0]  limit_i,
    input  logic         op_begin_i,
    input  logic         log_i,
    input  logic         permit_i,
    input  logic [2:0]   kind_i,
    // The entry's size field: 0 for a whole owner; a slot count for a
    // K_TUPLE range entry (Phase 5: one chunk of a large list's buffer).
    input  logic [31:0]  size_i,
    input  logic [31:0]  owner_i,
    // Up to three windows per pulse, {hi, lo}; hi <= lo: unused.
    input  logic [2:0][63:0] win_i,
    // B5: an owner in [drop_lo_i, drop_hi_i) is young; its log is dropped.
    input  logic [31:0]  drop_lo_i,
    input  logic [31:0]  drop_hi_i,
    // Guard input: a managed write the window test decides.
    input  logic         wr_i,
    input  logic         wr_cont_i,
    input  logic [31:0]  wr_addr_i,
    output logic         guard_hit_o,
    input  logic         clear_i,
    output logic         overflow_o,
    // SSB read port (engine P_REMSET, testbench dumps).
    output logic [31:0]  n_o,
    input  logic [31:0]  rd_idx_i,
    output logic [66:0]  rd_ent_o,
    // Counters since reset.
    output logic [31:0]  logs_o,
    output logic [31:0]  dups_o,
    output logic [31:0]  drops_o,
    output logic [31:0]  overflows_o
);
    localparam int SA = $clog2(SSB_ENTRIES);
    localparam int FA = $clog2(FILTER);
    localparam int WA = $clog2(NWIN + 1);

    logic [66:0] ssb_q [0:SSB_ENTRIES-1];
    logic [31:0] n_r;
    logic [66:0] flt_q [0:FILTER-1];
    logic [FILTER-1:0] flt_v_r;
    logic [NWIN-1:0][63:0] win_r;
    logic [WA-1:0] win_n_r;
    logic [31:0] logs_r, dups_r, drops_r, ovf_r;
    logic [31:0] limit;

    assign limit     = ((limit_i == 32'd0) || (limit_i > 32'(SSB_ENTRIES))) ? 32'(SSB_ENTRIES) : limit_i;
    assign n_o       = n_r;
    assign rd_ent_o  = ssb_q[rd_idx_i[SA-1:0]];
    assign logs_o    = logs_r;
    assign dups_o    = dups_r;
    assign drops_o   = drops_r;
    assign overflows_o = ovf_r;

    function automatic logic in_win(input logic [63:0] w, input logic [31:0] a);
        in_win = (a >= w[31:0]) && (a < w[63:32]);
    endfunction

    // Guard: windows already declared, or declared by this cycle's pulse
    // (a site raises its pulse in the cycle it issues its first write).
    logic covered;
    always_comb begin
        covered = 1'b0;
        for (int i = 0; i < NWIN; i++)
            if ((WA'(i) < win_n_r) && !op_begin_i && in_win(win_r[i], wr_addr_i)) covered = 1'b1;
        if (log_i || permit_i)
            for (int j = 0; j < 3; j++)
                if (in_win(win_i[j], wr_addr_i)) covered = 1'b1;
        // Mutant 83: windows ignored (every write into old memory is a hit).
        if (mutant_i == 8'd83) covered = 1'b0;
    end
    assign guard_hit_o = en_i && wr_i && !(wr_cont_i && covered);

    // Filter: direct-mapped on the owner's granule address; a hit needs the
    // whole entry. Mutant 82 hits on the slot alone.
    logic [66:0]   ent;
    logic [FA-1:0] fidx;
    logic          fhit, drop, push;
    assign ent  = {kind_i, size_i, owner_i};
    assign fidx = owner_i[4 +: FA] ^ owner_i[4 + FA +: FA];
    assign fhit = flt_v_r[fidx] && ((flt_q[fidx] == ent) || (mutant_i == 8'd82));
    // Mutant 85 drops every owner below the bump pointer, old ones too.
    assign drop = (owner_i < drop_hi_i) &&
                  ((owner_i >= drop_lo_i) || (mutant_i == 8'd85));
    assign push = en_i && log_i && !drop && !fhit;
    // Mutant 87: a full SSB drops the entry without forcing a major.
    assign overflow_o = push && (n_r >= limit) && (mutant_i != 8'd87);

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            n_r <= '0;
            flt_v_r <= '0;
            win_n_r <= '0;
            logs_r <= '0; dups_r <= '0; drops_r <= '0; ovf_r <= '0;
        end else if (clear_i) begin
            n_r <= '0;
            flt_v_r <= '0;
            win_n_r <= '0;
        end else if (en_i) begin
            if (log_i) begin
                logs_r <= logs_r + 32'd1;
                if (drop) drops_r <= drops_r + 32'd1;
                else if (fhit) dups_r <= dups_r + 32'd1;
            end
            if (push) begin
                flt_q[fidx]   <= ent;
                flt_v_r[fidx] <= 1'b1;
                if (n_r < limit) begin
                    ssb_q[n_r[SA-1:0]] <= ent;
                    n_r <= n_r + 32'd1;
                end else begin
                    ovf_r <= ovf_r + 32'd1;
                end
            end
            // Windows: op_begin empties the set; a pulse appends its
            // non-empty windows. Past NWIN a window is lost, which only
            // turns a later write into a guard hit.
            begin
                logic [WA-1:0] k;
                k = op_begin_i ? '0 : win_n_r;
                if (log_i || permit_i)
                    for (int j = 0; j < 3; j++)
                        if ((win_i[j][63:32] > win_i[j][31:0]) && (k < WA'(NWIN))) begin
                            win_r[k] <= win_i[j];
                            k = k + WA'(1);
                        end
                win_n_r <= k;
            end
        end
    end
endmodule

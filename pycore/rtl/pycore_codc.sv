`include "pycore_defs.svh"

// Code-object descriptor cache (memory_system_plan.md P6).
// Combinational result cache, not a line cache: lookup_i/key_i produce
// hit_o/payload_o the same cycle. Fill and LRU update on the posedge.
//
// 4 entries / 2-way → 2 sets. Set index is (addr >> LINE_BYTES) & (SETS-1)
// so a 64 B-aligned code object lands in one set. Payload is the five
// CALL field-read results packed as:
//   [63:0]     entry_slot
//   [191:64]   co_consts
//   [319:192]  co_names
//   [447:320]  metadata
//   [575:448]  co_defaults
//
// cache_en_i=0 is a miss/pass-through: hit_o is 0, fill/lookup are ignored.
// Flush clears every valid bit (MAKE_FUNCTION, code release, trap_res, reset).
module pycore_codc #(
    parameter int ENTRIES   = PYCORE_CODC_ENTRIES,
    parameter int WAYS      = PYCORE_CODC_WAYS,
    parameter int KEY_W     = PYCORE_ADDR_WIDTH,
    parameter int PAYLOAD_W = PYCORE_CODC_PAYLOAD_W,
    parameter int LINE_BYTES = PYCORE_LINE_BYTES
) (
    input  logic                       clk_i,
    input  logic                       rst_n_i,
    input  logic                       cache_en_i,

    input  logic                       lookup_i,
    input  logic [KEY_W-1:0]           lookup_key_i,
    output logic                       hit_o,
    output logic [PAYLOAD_W-1:0]       payload_o,

    input  logic                       fill_i,
    input  logic [KEY_W-1:0]           fill_key_i,
    input  logic [PAYLOAD_W-1:0]       fill_payload_i,

    input  logic                       flush_i,

    output logic [PYCORE_PERF_CNT_WIDTH-1:0] hit_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] miss_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] fill_count_o,
    output logic [PYCORE_PERF_CNT_WIDTH-1:0] flush_count_o
);
    localparam int SETS    = ENTRIES / WAYS;
    localparam int SET_W   = (SETS <= 1) ? 1 : $clog2(SETS);
    localparam int WAY_W   = $clog2(WAYS);
    localparam int AGE_W   = $clog2(WAYS);
    localparam int AGE_PACK = WAYS * AGE_W;
    localparam int LINE_SHIFT = $clog2(LINE_BYTES);

    logic valid_r   [0:SETS-1][0:WAYS-1];
    logic [KEY_W-1:0]     key_r     [0:SETS-1][0:WAYS-1];
    logic [PAYLOAD_W-1:0] payload_r [0:SETS-1][0:WAYS-1];
    logic [AGE_PACK-1:0]  ages_r    [0:SETS-1];

    logic [SET_W-1:0] lookup_set, fill_set;
    logic             lookup_hit, fill_hit;
    logic [WAY_W-1:0] lookup_way, fill_hit_way, fill_way;
    logic [PAYLOAD_W-1:0] lookup_payload;
    logic [AGE_PACK-1:0] ages_n  [0:SETS-1];
    logic [WAY_W-1:0] touch_way  [0:SETS-1];

    function automatic logic [SET_W-1:0] set_index(input logic [KEY_W-1:0] addr);
        logic [KEY_W-1:0] shifted;
        shifted = addr >> LINE_SHIFT;
        if (SETS <= 1)
            set_index = '0;
        else
            set_index = shifted[SET_W-1:0];
    endfunction

    function automatic logic [AGE_PACK-1:0] ident_ages();
        ident_ages = '0;
        for (int w = 0; w < WAYS; w++)
            ident_ages[w*AGE_W +: AGE_W] = AGE_W'(w);
    endfunction

    // Victim from packed ages only — do not route through pycore_cache_lru's
    // touch port or fill_way and victim_o form a combinational loop.
    function automatic logic [WAY_W-1:0] ages_victim(
        input logic [AGE_PACK-1:0] packed_ages
    );
        logic [AGE_W-1:0] max_age;
        logic [WAY_W-1:0] v;
        v       = '0;
        max_age = packed_ages[0 +: AGE_W];
        for (int w = 1; w < WAYS; w++) begin
            if (packed_ages[w*AGE_W +: AGE_W] >= max_age) begin
                max_age = packed_ages[w*AGE_W +: AGE_W];
                v       = WAY_W'(w);
            end
        end
        ages_victim = v;
    endfunction

    assign lookup_set = set_index(lookup_key_i);
    assign fill_set   = set_index(fill_key_i);

    always_comb begin
        lookup_hit     = 1'b0;
        lookup_way     = '0;
        lookup_payload = '0;
        if (cache_en_i) begin
            for (int w = 0; w < WAYS; w++) begin
                if (valid_r[lookup_set][w] &&
                    (key_r[lookup_set][w] == lookup_key_i)) begin
                    lookup_hit     = 1'b1;
                    lookup_way     = WAY_W'(w);
                    lookup_payload = payload_r[lookup_set][w];
                end
            end
        end
    end

    assign hit_o     = lookup_i && lookup_hit;
    assign payload_o = lookup_payload;

    always_comb begin
        fill_hit     = 1'b0;
        fill_hit_way = '0;
        if (cache_en_i) begin
            for (int w = 0; w < WAYS; w++) begin
                if (valid_r[fill_set][w] &&
                    (key_r[fill_set][w] == fill_key_i)) begin
                    fill_hit     = 1'b1;
                    fill_hit_way = WAY_W'(w);
                end
            end
        end
    end

    always_comb begin
        logic found_inv;
        found_inv = 1'b0;
        fill_way  = ages_victim(ages_r[fill_set]);
        if (fill_hit)
            fill_way = fill_hit_way;
        else begin
            for (int w = 0; w < WAYS; w++) begin
                if (!valid_r[fill_set][w] && !found_inv) begin
                    fill_way  = WAY_W'(w);
                    found_inv = 1'b1;
                end
            end
        end
    end

    genvar gs;
    generate
        for (gs = 0; gs < SETS; gs++) begin : g_lru
            always_comb begin
                if (fill_i && cache_en_i && (fill_set == SET_W'(gs)))
                    touch_way[gs] = fill_way;
                else
                    touch_way[gs] = lookup_way;
            end
            pycore_cache_lru #(.WAYS(WAYS)) u_lru (
                .ages_i(ages_r[gs]),
                .touch_way_i(touch_way[gs]),
                .ages_o(ages_n[gs]),
                .victim_o()
            );
        end
    endgenerate

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (int s = 0; s < SETS; s++) begin
                ages_r[s] <= ident_ages();
                for (int w = 0; w < WAYS; w++) begin
                    valid_r[s][w]   <= 1'b0;
                    key_r[s][w]     <= '0;
                    payload_r[s][w] <= '0;
                end
            end
            hit_count_o   <= '0;
            miss_count_o  <= '0;
            fill_count_o  <= '0;
            flush_count_o <= '0;
        end else begin
            if (flush_i) begin
                for (int s = 0; s < SETS; s++) begin
                    ages_r[s] <= ident_ages();
                    for (int w = 0; w < WAYS; w++)
                        valid_r[s][w] <= 1'b0;
                end
                flush_count_o <= flush_count_o + PYCORE_PERF_CNT_WIDTH'(1);
            end else if (cache_en_i && fill_i) begin
                valid_r[fill_set][fill_way]   <= 1'b1;
                key_r[fill_set][fill_way]     <= fill_key_i;
                payload_r[fill_set][fill_way] <= fill_payload_i;
                ages_r[fill_set]              <= ages_n[fill_set];
                fill_count_o <= fill_count_o + PYCORE_PERF_CNT_WIDTH'(1);
            end else if (cache_en_i && lookup_i && lookup_hit) begin
                ages_r[lookup_set] <= ages_n[lookup_set];
            end

            if (cache_en_i && lookup_i && !flush_i) begin
                if (lookup_hit)
                    hit_count_o <= hit_count_o + PYCORE_PERF_CNT_WIDTH'(1);
                else
                    miss_count_o <= miss_count_o + PYCORE_PERF_CNT_WIDTH'(1);
            end
        end
    end
endmodule

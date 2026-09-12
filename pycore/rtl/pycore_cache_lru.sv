`include "pycore_defs.svh"

// True LRU for a single cache set. Ages are packed WAYS * AGE_W bits,
// age 0 = MRU, age WAYS-1 = LRU. Split out so tb_cache_lru can cover every
// access order for 4- and 8-way without instantiating a full cache.
//
// The inventory names this "pseudo-LRU"; the P2 TB asks for victim
// selection over every access order, which is true LRU. True LRU is a
// local call: same port, same victim-on-miss contract.
module pycore_cache_lru #(
    parameter int WAYS = 4
) (
    input  logic [WAYS*$clog2(WAYS)-1:0] ages_i,
    input  logic [$clog2(WAYS)-1:0]      touch_way_i,
    output logic [WAYS*$clog2(WAYS)-1:0] ages_o,
    output logic [$clog2(WAYS)-1:0]      victim_o
);
    localparam int WAY_W = $clog2(WAYS);
    localparam int AGE_W = $clog2(WAYS);

    logic [AGE_W-1:0] ages_in  [0:WAYS-1];
    logic [AGE_W-1:0] ages_out [0:WAYS-1];
    logic [AGE_W-1:0] touch_age;
    logic [WAY_W-1:0] victim;
    logic [AGE_W-1:0] max_age;

    always_comb begin
        for (int w = 0; w < WAYS; w++) begin
            ages_in[w] = ages_i[w*AGE_W +: AGE_W];
        end
        touch_age = ages_in[touch_way_i];
        for (int w = 0; w < WAYS; w++) begin
            if (w[WAY_W-1:0] == touch_way_i)
                ages_out[w] = '0;
            else if (ages_in[w] < touch_age)
                ages_out[w] = ages_in[w] + AGE_W'(1);
            else
                ages_out[w] = ages_in[w];
        end
        victim  = '0;
        max_age = ages_in[0];
        for (int w = 1; w < WAYS; w++) begin
            if (ages_in[w] >= max_age) begin
                max_age = ages_in[w];
                victim  = w[WAY_W-1:0];
            end
        end
    end

    always_comb begin
        for (int w = 0; w < WAYS; w++) begin
            ages_o[w*AGE_W +: AGE_W] = ages_out[w];
        end
    end

    assign victim_o = victim;
endmodule

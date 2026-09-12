`include "pycore_defs.svh"

// Directed LRU coverage: after touching every way of a set in order P,
// the victim is P[0] (least recently touched). Runs every permutation for
// 4-way and 8-way (memory_system_plan.md §6).
module tb_cache_lru;
    localparam int WAYS4 = 4;
    localparam int AGE4  = $clog2(WAYS4);
    localparam int PACK4 = WAYS4 * AGE4;
    localparam int WAYS8 = 8;
    localparam int AGE8  = $clog2(WAYS8);
    localparam int PACK8 = WAYS8 * AGE8;

    logic [PACK4-1:0] ages4, ages4_n;
    logic [AGE4-1:0]  touch4, victim4;
    logic [PACK8-1:0] ages8, ages8_n;
    logic [AGE8-1:0]  touch8, victim8;

    pycore_cache_lru #(.WAYS(WAYS4)) dut4 (
        .ages_i(ages4),
        .touch_way_i(touch4),
        .ages_o(ages4_n),
        .victim_o(victim4)
    );
    pycore_cache_lru #(.WAYS(WAYS8)) dut8 (
        .ages_i(ages8),
        .touch_way_i(touch8),
        .ages_o(ages8_n),
        .victim_o(victim8)
    );

    function automatic logic [PACK4-1:0] ident4();
        ident4 = '0;
        for (int w = 0; w < WAYS4; w++)
            ident4[w*AGE4 +: AGE4] = AGE4'(w);
    endfunction

    function automatic logic [PACK8-1:0] ident8();
        ident8 = '0;
        for (int w = 0; w < WAYS8; w++)
            ident8[w*AGE8 +: AGE8] = AGE8'(w);
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    initial begin
        int perm4 [0:3];
        int perm8 [0:7];
        int n4, n8;
        ages4 = ident4();
        touch4 = '0;
        ages8 = ident8();
        touch8 = '0;
        #1;
        check(victim4 == 2'(WAYS4-1), "4-way identity victim is LRU way");
        check(victim8 == 3'(WAYS8-1), "8-way identity victim is LRU way");

        n4 = 0;
        perm4 = '{0, 1, 2, 3};
        begin : permute4
            // Heap's algorithm for 4 elements.
            int c [0:3];
            int i;
            int tmp;
            for (i = 0; i < 4; i++) c[i] = 0;
            forever begin
                ages4 = ident4();
                #1;
                for (int k = 0; k < 4; k++) begin
                    touch4 = AGE4'(perm4[k]);
                    #1;
                    ages4 = ages4_n;
                    #1;
                end
                check(victim4 == AGE4'(perm4[0]),
                      $sformatf("4-way perm victim %0d != %0d", victim4, perm4[0]));
                n4++;
                i = 0;
                while (i < 4 && c[i] >= i) begin
                    c[i] = 0;
                    i++;
                end
                if (i >= 4) disable permute4;
                tmp = perm4[i];
                if (i[0] == 1'b0) begin
                    perm4[i] = perm4[0];
                    perm4[0] = tmp;
                end else begin
                    perm4[i] = perm4[c[i]];
                    perm4[c[i]] = tmp;
                end
                c[i]++;
            end
        end
        check(n4 == 24, $sformatf("expected 24 4-way perms, got %0d", n4));

        n8 = 0;
        for (int w = 0; w < 8; w++) perm8[w] = w;
        begin : permute8
            int c [0:7];
            int i;
            int tmp;
            for (i = 0; i < 8; i++) c[i] = 0;
            forever begin
                ages8 = ident8();
                #1;
                for (int k = 0; k < 8; k++) begin
                    touch8 = AGE8'(perm8[k]);
                    #1;
                    ages8 = ages8_n;
                    #1;
                end
                check(victim8 == AGE8'(perm8[0]),
                      $sformatf("8-way perm victim %0d != %0d", victim8, perm8[0]));
                n8++;
                i = 0;
                while (i < 8 && c[i] >= i) begin
                    c[i] = 0;
                    i++;
                end
                if (i >= 8) disable permute8;
                tmp = perm8[i];
                if (i[0] == 1'b0) begin
                    perm8[i] = perm8[0];
                    perm8[0] = tmp;
                end else begin
                    perm8[i] = perm8[c[i]];
                    perm8[c[i]] = tmp;
                end
                c[i]++;
            end
        end
        check(n8 == 40320, $sformatf("expected 40320 8-way perms, got %0d", n8));

        $display("PASS: pycore_cache_lru 4-way (24) and 8-way (40320) access orders");
        $finish;
    end
endmodule

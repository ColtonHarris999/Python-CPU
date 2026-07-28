`ifndef _vivado_sv
`define _vivado_sv

///////
// Note that for reasons that can't be understood, Vivado runs
// very slow if you turn off optimizatoin around BRAMs.  So
// we go through most HW builds with these switches disabled.
// and only enable them for final result runs.

//`define syn_optimize
`ifdef syn_optimize
`define syn_parallel_case		(* parallel_case *)
`define syn_ram_no_collision	(* rw_addr_collision = "no" *) 
`define syn_dont_touch			(* dont_touch="yes" *)
`else
`define syn_parallel_case
`define syn_ram_no_collision
`define syn_dont_touch
`endif

`endif


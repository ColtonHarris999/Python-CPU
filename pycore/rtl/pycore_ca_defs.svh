// Container-accelerator command ids. Python, C and the excore fallback
// consume the same numbers (accelerator_split_plan.md §6.1).
`ifndef PYCORE_CA_DEFS_SVH
`define PYCORE_CA_DEFS_SVH
localparam logic [6:0] PY_CA_L_APPEND = 7'd1;
localparam logic [6:0] PY_CA_L_EXTEND = 7'd2;
localparam logic [6:0] PY_CA_L_DEL    = 7'd3;
`endif

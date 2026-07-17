`ifndef _base_
`define _base_

typedef logic bool;
// Useful macros to make the code more readable
localparam true = 1'b1;
localparam false = 1'b0;
localparam one = 1'b1;
localparam zero = 1'b0;

//// Adjust this based on the synthesis tool in use
`include "vivado.sv"
`endif

`ifndef _system_
`define _system_

// Change between 64 and 32 bit system




`ifdef _64bit
`define __64bit__
`define word_size 64
`define word_address_size 64

`else

`define __32bit__
`define word_size 32
`define word_address_size 32
`endif

// universal
`define word_size_bytes (`word_size/8)
`define word_address_size_bytes (`word_address_size/8)

// how much added bits are put into memory requests.  Arbitrary but div 4 ideal
`define user_tag_size 16

`endif

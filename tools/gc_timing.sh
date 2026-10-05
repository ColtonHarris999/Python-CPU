#!/usr/bin/env bash
# Logic-depth estimate for the GC engine (pycore/docs/gc.md, "Clock and
# timing"). Converts pycore_gc.sv with sv2v, shrinks every on-chip array to
# 16 entries (the arrays are read combinationally and would otherwise
# synthesize to ~1M flops; their read-mux delay is measured separately), maps
# to the SkyWater sky130 hd library with Yosys + ABC, and prints ABC's
# worst register-to-register delay and its start/end points.
#
#   tools/gc_timing.sh [out_dir]          # ~20 min, ~6 GB RAM
#
# Needs sv2v, yosys and the sky130 hd typical liberty. Set SKY130_LIB to the
# .lib, or the script downloads it from OpenROAD-flow-scripts.
# The delay has no wire load and no flop overhead: add ~0.4 ns (clk->q plus
# setup) and expect 20-30% more after placement.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/gc_timing}
mkdir -p "$OUT"
LIB=${SKY130_LIB:-$OUT/sky130_fd_sc_hd__tt_025C_1v80.lib}
if [ ! -f "$LIB" ]; then
    curl -sSL -o "$LIB" \
        https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
fi
sv2v -DSYNTHESIS -I "$ROOT/pycore/rtl" "$ROOT/pycore/rtl/pycore_gc.sv" > "$OUT/gc.v"
sed -i \
    -e 's/localparam signed \[31:0\] BM_WORDS = PYCORE_GC_BITMAP_WORDS;/localparam signed [31:0] BM_WORDS = 16;/' \
    -e 's/localparam signed \[31:0\] RUN_ONCHIP = 1024;/localparam signed [31:0] RUN_ONCHIP = 16;/' \
    -e 's/localparam signed \[31:0\] SHADOW_WORDS = 256;/localparam signed [31:0] SHADOW_WORDS = 16;/' \
    -e 's/parameter signed \[31:0\] MSTACK_ONCHIP = 256;/parameter signed [31:0] MSTACK_ONCHIP = 16;/' \
    "$OUT/gc.v"
[ "$(grep -c '= 16;' "$OUT/gc.v")" -ge 4 ] || { echo "gc_timing: array parameters not found" >&2; exit 1; }
cat > "$OUT/abc.script" <<'EOF'
strash
dch -f
map -D 1000
topo
stime -p
buffer
upsize -D 1000
dnsize -D 1000
stime -p
EOF
cat > "$OUT/syn.ys" <<EOF
read_verilog -sv $OUT/gc.v
synth -top pycore_gc -flatten
dfflibmap -liberty $LIB
abc -liberty $LIB -script $OUT/abc.script
stat -liberty $LIB
EOF
yosys -l "$OUT/syn.log" "$OUT/syn.ys" > /dev/null
grep -h "Delay =" "$OUT/syn.log" | tail -1
grep -h "Start-point" "$OUT/syn.log" | tail -1

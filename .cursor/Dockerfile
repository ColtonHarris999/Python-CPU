FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# System toolchain for the PyCore two-core simulator:
#   - verilator: SystemVerilog simulator. Debian trixie ships 5.032, which the
#     RTL requires (it slices function-call return values, unsupported by the
#     older 5.020 in Ubuntu's repos).
#   - build-essential / make: C++ toolchain Verilator emits and drives.
#   - git / curl / ca-certificates: repository and network basics.
# The python:3.14-slim base provides both `python3.14` (image-boot tooling) and
# `python3` (excore RV32 assembler tooling).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        make \
        verilator \
        git \
        curl \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

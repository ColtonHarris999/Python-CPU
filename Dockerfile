FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    make \
    ca-certificates \
    verilator \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

CMD ["make", "sim"]

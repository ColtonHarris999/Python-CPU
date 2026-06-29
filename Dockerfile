FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make verilator \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work

CMD ["make", "all-tests"]

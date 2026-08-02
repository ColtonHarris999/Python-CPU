# ---- frontend build -------------------------------------------------------
FROM node:22-bookworm-slim AS webbuild
WORKDIR /web
COPY sim_ui/web/package.json sim_ui/web/package-lock.json* ./
RUN npm install
COPY sim_ui/web/ ./
RUN npm run build

# ---- runtime / sim image --------------------------------------------------
FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV SIM_UI_HOST=0.0.0.0
ENV SIM_UI_PORT=8000

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make verilator \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Server deps (image tools use stdlib + in-tree modules).
COPY sim_ui/requirements.txt /tmp/sim_ui_requirements.txt
RUN pip install --no-cache-dir -r /tmp/sim_ui_requirements.txt

# Pre-copied frontend dist so the UI works even when the bind mount is older.
COPY --from=webbuild /web/dist /opt/sim_ui_web_dist

# Repo is typically bind-mounted at /work; also copy a baseline for image-only runs.
COPY . /work
RUN mkdir -p /work/sim_ui/web && \
    rm -rf /work/sim_ui/web/dist && \
    cp -a /opt/sim_ui_web_dist /work/sim_ui/web/dist

EXPOSE 8000

CMD ["make", "all-tests"]

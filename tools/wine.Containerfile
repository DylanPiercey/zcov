FROM docker.io/library/debian:12-slim
RUN dpkg --add-architecture i386 && apt-get update && \
    apt-get install -y --no-install-recommends wine wine64 && \
    rm -rf /var/lib/apt/lists/*
ENV WINEDEBUG=-all
ENV WINEPREFIX=/wine
RUN wineboot --init 2>/dev/null || true

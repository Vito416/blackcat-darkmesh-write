FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LUA_PATH="?.lua;?/init.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua;/usr/share/lua/5.4/?.lua;/usr/share/lua/5.4/?/init.lua;/root/.luarocks/share/lua/5.4/?.lua;/root/.luarocks/share/lua/5.4/?/init.lua" \
    LUA_CPATH="?.so;/usr/local/lib/lua/5.4/?.so;/usr/lib/lua/5.4/?.so;/usr/local/lib/lua/5.4/loadall.so;/root/.luarocks/lib/lua/5.4/?.so"

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      lua5.4 lua5.4-dev luarocks \
      libsodium-dev libssl-dev libsqlite3-dev \
      build-essential ca-certificates git curl python3 python3-pip cmake && \
    rm -rf /var/lib/apt/lists/*

# Preinstall rocks from lockfile when present
COPY ops/rocks.lock /tmp/rocks.lock
RUN if [ -f /tmp/rocks.lock ]; then \
      while read -r name ver; do \
        case "$name" in \#*|"") continue ;; \
        esac; \
        luarocks --lua-version=5.4 install --local "$name" "$ver"; \
      done < /tmp/rocks.lock; \
    fi

# Copy source
COPY . /app

# Default command: open shell; override in docker-compose
CMD ["bash"]

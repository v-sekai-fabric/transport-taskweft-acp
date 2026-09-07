# syntax=docker/dockerfile:1
# The hosted door as one Elixir release: the OpenBao-gated MCP bridge, the executor
# WebSocket endpoint, and the store helper in fabric mode (weft_fdb on FoundationDB).
# Stage 1 builds the release and the helper; stage 2 is a slim runtime with the
# FoundationDB client library the helper links against.

ARG ELIXIR_IMAGE=docker.io/hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20260824-slim
ARG RUNTIME_IMAGE=docker.io/debian:bookworm-slim
ARG FDB_CLIENTS_DEB=https://github.com/apple/foundationdb/releases/download/7.3.79/foundationdb-clients_7.3.79-1_amd64.deb

FROM ${ELIXIR_IMAGE} AS build
ARG FDB_CLIENTS_DEB

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates curl libsqlite3-dev \
  && curl -fsSL -o /tmp/fdb-clients.deb "${FDB_CLIENTS_DEB}" \
  && dpkg -i /tmp/fdb-clients.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/fdb-clients.deb

ENV MIX_ENV=prod

RUN mix archive.install github hexpm/hex branch latest --force
RUN curl -fsSL -o /usr/local/bin/rebar3 https://github.com/erlang/rebar3/releases/latest/download/rebar3 \
  && chmod +x /usr/local/bin/rebar3 \
  && mix local.rebar rebar3 /usr/local/bin/rebar3 --force

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY c_src c_src
COPY Makefile ./
# fabric-store's VFS arrives through the goal manifest's linkfile; the build context
# must carry thirdparty/store/{fdb_vfs.c,fdb_keys.h}.
COPY thirdparty thirdparty
RUN make WEFT_FABRIC=1 > /tmp/weft_sql.log 2>&1 || { grep -E "error|Error" /tmp/weft_sql.log; exit 1; }
RUN mix compile
RUN mix release taskweft_acp_deploy

FROM ${RUNTIME_IMAGE} AS app
ARG FDB_CLIENTS_DEB

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl libsqlite3-0 git \
  && curl -fsSL -o /tmp/fdb-clients.deb "${FDB_CLIENTS_DEB}" \
  && dpkg -i /tmp/fdb-clients.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/fdb-clients.deb

ENV MIX_ENV=prod \
    PORT=8080 \
    LANG=C.UTF-8 \
    TASKWEFT_ACP_STORE=fabric \
    TASKWEFT_ACP_SERVE=1

WORKDIR /app
COPY --from=build /app/_build/prod/rel/taskweft_acp_deploy ./

RUN useradd --create-home app && chown -R app:app /app
USER app

EXPOSE 8080
CMD ["/app/bin/taskweft_acp_deploy", "start"]

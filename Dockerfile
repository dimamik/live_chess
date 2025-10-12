# Multi-stage release build for the LiveChess Phoenix application.

ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.2
ARG DEBIAN_VERSION=bookworm-20250407-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install packages required for compiling Elixir deps and assets.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git nodejs npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Hex and Rebar once in the build image.
RUN mix local.hex --force \
    && mix local.rebar --force

ENV MIX_ENV="prod"

# Fetch deps based on lockfile before copying the whole project (improves caching).
COPY mix.exs mix.lock ./
RUN mix deps.get --only ${MIX_ENV}
RUN mkdir config

# Copy configs needed at compile-time so dependency recompilation happens when configs change.
COPY config/config.exs config/${MIX_ENV}.exs config/

# Bring in assets before compiling deps so any dependency on asset files invalidates the cache.
COPY assets assets

RUN mix deps.compile
RUN mix assets.setup

COPY priv priv
COPY lib lib

# Compile and digest static assets.
RUN mix assets.deploy

# Compile the application and build the release.
RUN mix compile
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses5 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Generate UTF-8 locale expected by Elixir.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody:nogroup /app

ENV MIX_ENV="prod"

# Copy only the release artifacts produced by the builder stage.
COPY --from=builder --chown=nobody:nogroup /app/_build/${MIX_ENV}/rel/live_chess ./

RUN chmod +x /app/bin/start

USER nobody

CMD ["/app/bin/start"]

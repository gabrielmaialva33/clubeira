ARG BUILDER_IMAGE="docker.io/hexpm/elixir:1.20.2-erlang-29.0.5-debian-trixie-20260713-slim@sha256:082d330c6c7cae0d79f14b12d51e6b9cc972c622cb54175cbf6db2ccc25939be"
ARG RUNNER_IMAGE="docker.io/debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258"

FROM ${BUILDER_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod --check-locked

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix compile --warnings-as-errors

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl libncurses6 libstdc++6 locales openssl tini \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PORT=4000

WORKDIR /app
RUN chown nobody:nogroup /app

COPY --from=builder --chown=nobody:nogroup /app/_build/prod/rel/clubeira ./

USER nobody
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl --fail --silent --show-error "http://127.0.0.1:${PORT}/health" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]

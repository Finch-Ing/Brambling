# syntax=docker/dockerfile:1

# ---- Build ----
FROM swift:6.4-noble AS build
WORKDIR /src

# Resolve dependencies first so they stay cached when only the sources change.
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
# Package.swift declares the test target, so SwiftPM needs its folder even for a release build.
COPY Tests ./Tests
# Static Swift runtime: the runtime image needs no toolchain.
RUN swift build -c release --static-swift-stdlib \
    && mkdir -p /out \
    && cp "$(swift build -c release --show-bin-path)/Brambling" /out/

# ---- Runtime ----
FROM ubuntu:noble

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates tzdata curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/Brambling /app/Brambling
# Vapor looks for Resources/ and Public/ relative to the working directory.
COPY Resources ./Resources
COPY Public ./Public
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV BRAMBLING_DATA=/data \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC \
    LOG_LEVEL=info

VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/app/Brambling", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]

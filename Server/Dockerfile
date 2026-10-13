# syntax=docker/dockerfile:1
#
# Builds natively for the host architecture, so building on a Raspberry Pi
# (as Dokploy does) yields an arm64 image and building on a VPS yields amd64.

FROM rust:1-slim-bookworm AS builder
WORKDIR /build

# cmake is only a fallback for the aws-lc crypto build; the default path needs just a C compiler.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

# Dependency layer: build against stub sources so this layer stays cached
# until Cargo.toml or Cargo.lock change.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
    && echo 'fn main() {}' > src/main.rs \
    && touch src/lib.rs \
    && cargo build --release --locked \
    && rm -rf src

COPY src ./src
# Bump mtimes so cargo rebuilds the crate instead of reusing the stub.
RUN touch src/main.rs src/lib.rs \
    && cargo build --release --locked \
    && cp target/release/xnotch-cloud /xnotch-cloud \
    && mkdir /data-empty

# Distroless "cc" ships glibc, libgcc, CA certificates and a nonroot user (uid 65532).
FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder /xnotch-cloud /usr/local/bin/xnotch-cloud
# Owned by the runtime user so a fresh named volume mounted here is writable.
COPY --from=builder --chown=65532:65532 /data-empty /data

ENV PORT=8080 \
    DATA_DIR=/data
USER 65532:65532
EXPOSE 8080
VOLUME /data

# The binary probes itself, so no curl or wget is needed in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/xnotch-cloud", "--healthcheck"]

ENTRYPOINT ["/usr/local/bin/xnotch-cloud"]

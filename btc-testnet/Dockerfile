# 本地构建兜底（Docker Hub 不可用时）：./scripts/pull-image.sh --build
# 详见 README.md「镜像拉取」

FROM debian:bookworm-slim

ARG BITCOIN_VERSION=31.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r bitcoin \
    && useradd -r -m -d /home/bitcoin -g bitcoin bitcoin

RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) BC_ARCH=x86_64 ;; \
         arm64) BC_ARCH=aarch64 ;; \
         armhf) BC_ARCH=arm-linux-gnueabihf ;; \
         *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL \
         "https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-${BC_ARCH}-linux-gnu.tar.gz" \
         -o /tmp/bitcoin.tar.gz \
    && tar -xzf /tmp/bitcoin.tar.gz -C /usr/local --strip-components=1 \
         "bitcoin-${BITCOIN_VERSION}/bin/bitcoind" \
         "bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli" \
         "bitcoin-${BITCOIN_VERSION}/bin/bitcoin-tx" \
    && rm /tmp/bitcoin.tar.gz \
    && bitcoind --version | head -1

USER bitcoin
WORKDIR /home/bitcoin
VOLUME ["/home/bitcoin/.bitcoin"]
EXPOSE 38332 38333

ENTRYPOINT ["bitcoind"]
CMD ["-printtoconsole"]

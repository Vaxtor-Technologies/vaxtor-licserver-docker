# ==========================================
# Vaxtor License Server (Sentinel LDK License Manager - hasplmd)
# Multi-architecture image: linux/amd64, linux/arm64
# ==========================================
FROM debian:trixie-slim

ARG TARGETARCH
ARG VERSION=10.13.1
ENV DEBIAN_FRONTEND=noninteractive
ENV AKSUSBD_VERSION=${VERSION}

# 1. Install runtime dependencies
#    - ca-certificates/curl: download aksusbd, talk to EMS (licensing.vaxtor.com) and to the local hasplmd
#    - libxml2-utils (xmllint): parse the EMS activation response
#    - tini: minimal init (PID 1), forwards signals and reaps zombies
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini libxml2-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Manually download and install the Sentinel LDK License Manager (dynamic per architecture, no dinst required)
RUN case "$TARGETARCH" in \
         amd64) HASP_ARCH="x86_64" ;; \
         arm64) HASP_ARCH="arm64" ;; \
         *) echo "[ERROR] Unsupported architecture: $TARGETARCH" && exit 1 ;; \
       esac \
    && cd /tmp \
    && curl -fsSL https://nexus.vaxtor.com/repository/sentinel/aksusbd-${VERSION}.tar -o aksusbd.tar \
    && tar xf aksusbd.tar \
    && cd aksusbd-${VERSION} \
    && mkdir -p /opt/hasplm/templates /opt/hasplm/vlib \
    && install -c -m 555 -g root -o root bin/hasplmd_${HASP_ARCH} /usr/sbin/hasplmd \
    && install -c -m 644 -g root -o root bin/*.alp /opt/hasplm/templates \
    && tar -xf bin/help.tar -C /opt/hasplm \
    && chown -R root:root /opt/hasplm/help \
    && chmod -R a=rX /opt/hasplm/help \
    && install -c -m 555 -g root -o root haspvlib_${HASP_ARCH}_97461.so /opt/hasplm/vlib/ \
    && cd / \
    && rm -rf /tmp/aksusbd*

# 3. Default License Manager configuration (seeded into /etc/hasplm on first start)
COPY hasplm.ini /opt/hasplm/hasplm.ini

# 4. Container management scripts
COPY --chmod=755 entrypoint.sh activate.sh /usr/local/bin/

# 1947/tcp: clients and Admin Control Center (ACC) | 1947/udp: license server discovery (broadcast)
EXPOSE 1947/tcp 1947/udp

# /var/hasplm: installed licenses (CRITICAL) | /etc/hasplm: License Manager configuration (hasplm.ini)
VOLUME ["/var/hasplm", "/etc/hasplm"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -s -o /dev/null http://127.0.0.1:1947 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

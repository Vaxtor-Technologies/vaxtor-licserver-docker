#!/bin/bash
set -euo pipefail

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

err() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

CONFIG_DIR="/etc/hasplm"
DATA_DIR="/var/hasplm"
DIST_DIR="/opt/hasplm"
VENDOR_ID="97461"
HASP_PID=""

prepare_config() {
    mkdir -p "$CONFIG_DIR"

    # Seed the default configuration only once: changes made from the ACC are kept in the volume
    if [ ! -f "$CONFIG_DIR/hasplm.ini" ]; then
        log "No hasplm.ini found. Installing default configuration..."
        cp "$DIST_DIR/hasplm.ini" "$CONFIG_DIR/hasplm.ini"
    else
        log "Using existing configuration $CONFIG_DIR/hasplm.ini"
    fi

    # ACC templates and help always come from the image, so an image upgrade also upgrades the ACC
    rm -rf "$CONFIG_DIR/templates" "$CONFIG_DIR/help"
    ln -s "$DIST_DIR/templates" "$CONFIG_DIR/templates"
    ln -s "$DIST_DIR/help" "$CONFIG_DIR/help"
}

prepare_data() {
    # The License Manager installs/upgrades the Vaxtor vendor library from the update directory
    mkdir -p "$DATA_DIR/update"
    cp "$DIST_DIR"/vlib/*.so "$DATA_DIR/update/"
}

stop_hasp_daemon() {
    if [ -n "$HASP_PID" ] && kill -0 "$HASP_PID" 2>/dev/null; then
        log "Stopping License Manager..."
        kill -TERM "$HASP_PID" 2>/dev/null || true
        wait "$HASP_PID" 2>/dev/null || true
    fi
    exit 0
}

start_hasp_daemon() {
    log "Starting License Manager (hasplmd)..."
    /usr/sbin/hasplmd -f &
    HASP_PID=$!

    local max_wait=30
    local counter=0

    log "Waiting for License Manager to be ready on port 1947..."
    while ! curl -s --output /dev/null http://127.0.0.1:1947; do
        if ! kill -0 "$HASP_PID" 2>/dev/null; then
            err "License Manager process exited unexpectedly."
            exit 1
        fi
        sleep 1
        counter=$((counter + 1))

        if [ "$counter" -ge "$max_wait" ]; then
            err "License Manager failed to bind port 1947 within ${max_wait} seconds."
            exit 1
        fi
    done
    log "License Manager is ready."
}

has_license() {
    compgen -G "$DATA_DIR/installed/$VENDOR_ID/*_base.v2c" >/dev/null
}

log "=== Initializing Vaxtor License Server ($(uname -m) Environment, aksusbd ${AKSUSBD_VERSION:-unknown}) ==="

# 1. Prepare configuration and data directories
prepare_config
prepare_data

# 2. Start the License Manager and forward stop signals to it
trap stop_hasp_daemon TERM INT
start_hasp_daemon

# 3. License activation
if has_license; then
    log "License found in $DATA_DIR. Skipping activation."
elif [ -n "${PRODUCT_KEY:-}" ]; then
    log "No license installed. Activating license with provided Product Key..."
    if /usr/local/bin/activate.sh "$PRODUCT_KEY"; then
        log "License server activated successfully."
    else
        err "Automatic activation failed. The License Manager keeps running: check the Product Key and the"
        err "connection to https://licensing.vaxtor.com, or activate it manually from the Admin Control Center."
    fi
else
    log "No license installed and no PRODUCT_KEY provided."
    log "Activate the license manually from the Admin Control Center: http://<server-ip>:1947"
fi

log "Vaxtor License Server is running. Admin Control Center available on port 1947."

# 4. Keep the License Manager in the foreground
set +e
wait "$HASP_PID"
exit_code=$?
err "License Manager stopped (exit code ${exit_code})."
exit "$exit_code"

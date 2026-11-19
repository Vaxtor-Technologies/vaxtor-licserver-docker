#!/bin/bash
set -euo pipefail

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

err() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# Validate input
if [ -z "${1:-}" ]; then
  err "Usage: $0 <PRODUCT_KEY>"
  exit 1
fi

PRODUCT_KEY="$1"
VENDOR_ID="97461"
LM_URL="http://127.0.0.1:1947"
EMS_URL="https://licensing.vaxtor.com/ems/v710/ws"
TEMP_DIR=$(mktemp -d)
COOKIE_FILE="$TEMP_DIR/cookie"
FINGERPRINT_FILE="$TEMP_DIR/host_fingerprint.c2v"
LICENSE_FILE="$TEMP_DIR/license.v2c"

# Cleanup trap: Ensures the temporary directory is deleted upon script exit, even on failure
trap 'rm -rf "$TEMP_DIR"' EXIT

# 1. Check dependencies
command -v curl >/dev/null 2>&1 || { err "curl not found."; exit 1; }
command -v xmllint >/dev/null 2>&1 || { err "libxml2-utils (xmllint) not found."; exit 1; }

# 2. Extract Host Fingerprint from the local License Manager
log "Extracting host fingerprint..."
if ! curl -sf -o "$FINGERPRINT_FILE" "$LM_URL/download/my.fp?$VENDOR_ID" || ! grep -q "<hasp_info>" "$FINGERPRINT_FILE"; then
  err "Failed to extract host fingerprint from the License Manager."
  exit 1
fi

# 3. EMS Login
log "Connecting to License Server..."
LOGIN_RESPONSE=$(curl -s -c "$COOKIE_FILE" --write-out '%{http_code}' --output /dev/null -X POST \
  -H "User-Agent: Vaxtor" \
  "$EMS_URL/loginByProductKey.ws?productKey=$PRODUCT_KEY" || true)

if [ "$LOGIN_RESPONSE" != "200" ]; then
  err "Authentication with License Server failed. HTTP Code: $LOGIN_RESPONSE"
  exit 1
fi

# 4. Request Activation
log "Requesting activation..."
ACTIVATION_BODY="<activation>
    <activationInput>
        <activationAttribute>
            <attributeValue><![CDATA[$(cat "$FINGERPRINT_FILE")]]></attributeValue>
            <attributeName>C2V</attributeName>
        </activationAttribute>
        <comments>Activated from Docker License Server ($(hostname))</comments>
    </activationInput>
</activation>"

ACTIVATION_RESPONSE=$(curl -s -L -b "$COOKIE_FILE" \
  -H "User-Agent: Vaxtor" \
  -H "Content-Type: Application/xml;charset=UTF-8" \
  -d "$ACTIVATION_BODY" \
  "$EMS_URL/productKey/$PRODUCT_KEY/activation.ws" || true)

# 5. Parse XML and save the license (V2C)
log "Processing activation response..."
ACTIVATION_STRING=$(xmllint --xpath "string(//activationString)" - <<< "$ACTIVATION_RESPONSE" 2>/dev/null || true)
if [ -n "$ACTIVATION_STRING" ]; then
  printf '%s' "$ACTIVATION_STRING" > "$LICENSE_FILE"
fi

if [ ! -s "$LICENSE_FILE" ]; then
  err "Could not extract activationString or response is invalid."
  [ -n "$ACTIVATION_RESPONSE" ] && err "EMS response: $ACTIVATION_RESPONSE"
  exit 1
fi

# 6. Apply license to the local License Manager (same as ACC "Update/Attach")
log "Applying license file to the License Manager..."
APPLY_RESPONSE=$(curl -s -w '\n%{http_code}' -X POST \
  -F "check_in_file=@$LICENSE_FILE" \
  "$LM_URL/_int_/checkin_file.html" || true)
APPLY_CODE=$(tail -n1 <<< "$APPLY_RESPONSE")
# The ACC always answers HTTP 200: the real result is the "var error = N;" value of the page (0 = success)
APPLY_ERROR=$(sed -n 's/^[[:space:]]*var error[[:space:]]*=[[:space:]]*\([0-9]*\);.*/\1/p' <<< "$APPLY_RESPONSE" | head -n1)

if [ "$APPLY_CODE" != "200" ]; then
  err "Could not upload the license file to the License Manager. HTTP Code: $APPLY_CODE"
  exit 1
fi

if [ "${APPLY_ERROR:-}" != "0" ]; then
  err "License Manager rejected the license file. Sentinel error code: ${APPLY_ERROR:-unknown}"
  exit 1
fi

# 7. Verify that the license is installed
for _ in $(seq 1 10); do
  if compgen -G "/var/hasplm/installed/$VENDOR_ID/*_base.v2c" >/dev/null; then
    log "License successfully activated and attached."
    exit 0
  fi
  sleep 1
done

err "The license file was uploaded but no installed license was found in /var/hasplm/installed/$VENDOR_ID."
exit 1

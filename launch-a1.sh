set -u

: "${OCI_TENANCY_OCID:?set OCI_TENANCY_OCID}"
: "${AVAILABILITY_DOMAIN:?set AVAILABILITY_DOMAIN}"
: "${SUBNET_ID:?set SUBNET_ID}"
: "${IMAGE_ID:?set IMAGE_ID}"
: "${SSH_PUBLIC_KEY:?set SSH_PUBLIC_KEY}"

COMPARTMENT_ID="${COMPARTMENT_ID:-$OCI_TENANCY_OCID}"  # root compartment by default
INSTANCE_NAME="${INSTANCE_NAME:-a1-free}"
SHAPE="VM.Standard.A1.Flex"
OCPUS="${OCPUS:-2}"                      # Always Free A1 total is currently 2 OCPUs / 12 GB
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"  # 200 GB of block storage is free in total
RETRY_SECONDS="${RETRY_SECONDS:-90}"
RUN_MINUTES="${RUN_MINUTES:-345}"        # GitHub ends jobs at 6 h, so stop a bit earlier
GATE_ON_CAPACITY_REPORT="${GATE_ON_CAPACITY_REPORT:-false}"

SSH_KEY_FILE="$(mktemp)"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_KEY_FILE"
DEADLINE=$(( $(date +%s) + RUN_MINUTES * 60 ))

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# True if a non-terminated instance with this name already exists (prevents duplicates).
instance_exists() {
  oci compute instance list --compartment-id "$COMPARTMENT_ID" \
      --display-name "$INSTANCE_NAME" --all 2>/dev/null |
    jq -e '[.data[]? | select(.["lifecycle-state"] != "TERMINATED" and .["lifecycle-state"] != "TERMINATING")] | length > 0' \
      >/dev/null 2>&1
}

# Asks OCI's Compute Capacity Report. Returns 1 only if it says OUT_OF_HOST_CAPACITY;
# if the call fails for any reason it returns 0 so that we still try to launch.
capacity_report() {
  local status
  status=$(oci compute compute-capacity-report create \
      --availability-domain "$AVAILABILITY_DOMAIN" \
      --compartment-id "$OCI_TENANCY_OCID" \
      --shape-availabilities "[{\"instanceShape\":\"$SHAPE\",\"instanceShapeConfig\":{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}}]" \
      2>/dev/null | jq -r '.data["shape-availabilities"][0]["availability-status"] // empty' 2>/dev/null)
  log "  capacity report: ${status:-no answer}"
  [ "$status" != "OUT_OF_HOST_CAPACITY" ]
}

# Optional alerts, only used if the matching variables are set.
#  - ntfy.sh push notification: set NTFY_TOPIC (install the ntfy app and subscribe to that topic)
#  - SMS via Twilio: set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM and ALERT_PHONE
notify() {
  local msg="$1"
  if [ -n "${NTFY_TOPIC:-}" ]; then
    curl -s -m 20 -H "Title: Oracle A1 VM" -H "Priority: high" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null \
      && log "ntfy alert sent."
  fi
  if [ -n "${TWILIO_ACCOUNT_SID:-}" ] && [ -n "${ALERT_PHONE:-}" ]; then
    curl -s -m 20 -u "$TWILIO_ACCOUNT_SID:${TWILIO_AUTH_TOKEN:-}" \
      "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/Messages.json" \
      --data-urlencode "To=$ALERT_PHONE" --data-urlencode "From=${TWILIO_FROM:-}" \
      --data-urlencode "Body=$msg" >/dev/null && log "SMS request sent."
  fi
}

# Inside GitHub Actions: switch the workflow off so it stops running once we have the VM.
disable_workflow() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && command -v gh >/dev/null 2>&1; then
    gh workflow disable "$GITHUB_WORKFLOW" --repo "$GITHUB_REPOSITORY" \
      && log "Workflow disabled - no more retries."
  fi
}

attempt=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  attempt=$((attempt + 1))
  started=$(date +%s)
  log "attempt #$attempt"

  if instance_exists; then
    log "Instance '$INSTANCE_NAME' already exists - nothing left to do."
    disable_workflow
    exit 0
  fi

  if capacity_report || [ "$GATE_ON_CAPACITY_REPORT" != "true" ]; then
    out=$(oci compute instance launch --no-retry \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
        --display-name "$INSTANCE_NAME" \
        --ssh-authorized-keys-file "$SSH_KEY_FILE" 2>&1)
    rc=$?

    if [ "$rc" -eq 0 ]; then
      log "SUCCESS - Oracle accepted the launch request (state: $(jq -r '.data["lifecycle-state"]' <<<"$out" 2>/dev/null))."
      notify "Your Oracle A1 VM '$INSTANCE_NAME' was created! Check Compute > Instances in the OCI console."
      disable_workflow
      exit 0
    fi

    # Retry on capacity errors (HTTP 500), throttling (429) and network hiccups.
    # Anything else (bad OCID, auth, limit exceeded...) will never fix itself: stop and show it.
    http=$(grep -oE '"status": *[0-9]+' <<<"$out" | grep -oE '[0-9]+$' | head -1)
    case "${http:-0}" in
      429|5??|0) log "  launch failed (${http:-network issue}) - normally 'Out of host capacity'; will retry" ;;
      *) echo "$out"; log "Non-retryable error (HTTP $http) - fix the setting it mentions and run again."; exit 1 ;;
    esac
  else
    log "  skipping launch (capacity report says no capacity)"
  fi

  spent=$(( $(date +%s) - started ))
  if [ "$spent" -lt "$RETRY_SECONDS" ]; then sleep $(( RETRY_SECONDS - spent )); fi
done

log "Time budget used up - the next queued run takes over."

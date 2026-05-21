#!/bin/sh
# Bootstrap entrypoint for semgrep-network-broker.
#
# When SCM_TYPE is set, this script regenerates a WireGuard keypair, writes a
# minimal config.yaml to ${CONFIG_DIR}, then execs the broker. The pubkey is
# auto-registered against the Semgrep API using SEMGREP_APP_TOKEN and the
# deployment id parsed from the broker's -d/--deployment-id flag — both are
# required on first boot. If the registration HTTP call fails (bad token,
# network blip, etc.) the broker still starts and a manual-registration
# banner is printed to `docker logs`.
#
# When SCM_TYPE is unset, the script is a pass-through to the broker binary —
# preserving the original ENTRYPOINT behavior for genkey/pubkey/relay/dump and
# normal `-c ... -d ...` invocations.

set -eu

BROKER_BIN="${BROKER_BIN:-/usr/bin/semgrep-network-broker}"
CONFIG_DIR="${CONFIG_DIR:-/emt}"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SEMGREP_HOSTNAME="${SEMGREP_HOSTNAME:-semgrep.dev}"

if [ -n "${SCM_TYPE:-}" ]; then
    if [ -z "${SCM_BASE_URL:-}" ]; then
        echo "bootstrap: SCM_BASE_URL must be set when SCM_TYPE is set" >&2
        exit 1
    fi

    case "${SCM_TYPE}" in
        github|gitlab|bitbucket|azuredevops) ;;
        *)
            echo "bootstrap: SCM_TYPE must be one of: github, gitlab, bitbucket, azuredevops (got: '${SCM_TYPE}')" >&2
            exit 1
            ;;
    esac

    if [ -z "${SCM_ALLOW_CODE_ACCESS:-}" ]; then
        echo "bootstrap: SCM_ALLOW_CODE_ACCESS must be set to 'true' or 'false' when SCM_TYPE is set" >&2
        exit 1
    fi

    case "${SCM_ALLOW_CODE_ACCESS}" in
        true|false) ;;
        *)
            echo "bootstrap: SCM_ALLOW_CODE_ACCESS must be 'true' or 'false' (got: '${SCM_ALLOW_CODE_ACCESS}')" >&2
            exit 1
            ;;
    esac

    if [ ! -d "${CONFIG_DIR}" ]; then
        echo "bootstrap: ${CONFIG_DIR} does not exist — mount your config directory, e.g. -v /opt/semgrep-broker:${CONFIG_DIR}" >&2
        exit 1
    fi

    # SCM_BASE_URL is the host base (e.g., https://gitlab.example.com).
    # Strip trailing slash, then append the per-SCM API path for the SCM block.
    # The original host base is reused as the broad allowlist pattern.
    BASE_URL="${SCM_BASE_URL%/}"

    case "${SCM_TYPE}" in
        github)      API_URL="${BASE_URL}/api/v3" ;;
        gitlab)      API_URL="${BASE_URL}/api/v4" ;;
        bitbucket)   API_URL="${BASE_URL}/rest/api/latest" ;;
        azuredevops) API_URL="${BASE_URL}" ;; # Azure DevOps URL shape varies; pass through as-is.
    esac

    if [ -f "${CONFIG_FILE}" ]; then
        echo "bootstrap: ${CONFIG_FILE} already exists — reusing it. Delete the file to force regeneration." >&2
    else
        if [ ! -w "${CONFIG_DIR}" ]; then
            echo "bootstrap: ${CONFIG_DIR} is not writable by UID $(id -u). chown the host directory to that UID, or run the container with --user." >&2
            exit 1
        fi

        # Validate first-boot prerequisites BEFORE generating a key or writing
        # config.yaml — otherwise a failed validation would leave a stale,
        # unregistered key on the volume and the idempotency check on the next
        # run would silently reuse it.
        if [ -z "${SEMGREP_APP_TOKEN:-}" ]; then
            echo "bootstrap: SEMGREP_APP_TOKEN must be set on first boot so the pubkey can be auto-registered with Semgrep" >&2
            exit 1
        fi

        # Parse the deployment id from the broker's -d / --deployment-id flag
        # so users don't have to pass the same number twice (once for the
        # broker, once for the registration call).
        DEPLOYMENT_ID=""
        NEXT_IS_DID=0
        for arg in "$@"; do
            if [ "${NEXT_IS_DID}" -eq 1 ]; then
                DEPLOYMENT_ID="${arg}"
                break
            fi
            case "${arg}" in
                -d|--deployment-id)  NEXT_IS_DID=1 ;;
                -d=*)                DEPLOYMENT_ID="${arg#-d=}"; break ;;
                --deployment-id=*)   DEPLOYMENT_ID="${arg#--deployment-id=}"; break ;;
            esac
        done

        if [ -z "${DEPLOYMENT_ID}" ]; then
            echo "bootstrap: -d / --deployment-id must be passed to the broker so the pubkey can be auto-registered with Semgrep" >&2
            exit 1
        fi

        PRIVATE_KEY="$("${BROKER_BIN}" genkey)"
        PUBLIC_KEY="$(printf '%s' "${PRIVATE_KEY}" | "${BROKER_BIN}" pubkey)"

        # Build the allowlist block. If SCM_ALLOWLIST_FILE points to a readable
        # non-empty file, indent its contents 4 spaces to fit under `allowlist:`
        # and use that. Otherwise fall back to the broad-start default.
        if [ -n "${SCM_ALLOWLIST_FILE:-}" ]; then
            if [ ! -f "${SCM_ALLOWLIST_FILE}" ]; then
                echo "bootstrap: SCM_ALLOWLIST_FILE='${SCM_ALLOWLIST_FILE}' not found or not a regular file" >&2
                exit 1
            fi
            if [ ! -r "${SCM_ALLOWLIST_FILE}" ]; then
                echo "bootstrap: SCM_ALLOWLIST_FILE='${SCM_ALLOWLIST_FILE}' is not readable by UID $(id -u)" >&2
                exit 1
            fi
            if [ ! -s "${SCM_ALLOWLIST_FILE}" ]; then
                echo "bootstrap: SCM_ALLOWLIST_FILE='${SCM_ALLOWLIST_FILE}' is empty — refusing to start broker with an empty allowlist" >&2
                exit 1
            fi
            ALLOWLIST_BLOCK="$(sed 's/^/    /' "${SCM_ALLOWLIST_FILE}")"
        else
            ALLOWLIST_BLOCK="$(cat <<YAML
    # Broad start: any path under the SCM host, all common methods. Tighten
    # later by replacing this block with specific URL patterns (see README),
    # or set SCM_ALLOWLIST_FILE to bootstrap with your own allowlist.
    - url: "${BASE_URL}/*"
      methods: [GET, POST, PUT, PATCH, DELETE]
YAML
)"
        fi

        umask 077
        cat > "${CONFIG_FILE}" <<YAML
# Generated by semgrep-network-broker bootstrap on $(date -u +%FT%TZ).
# Contains a WireGuard private key — do not commit or share.
inbound:
  wireguard:
    privateKey: ${PRIVATE_KEY}
  ${SCM_TYPE}:
    baseUrl: ${API_URL}
    allowCodeAccess: ${SCM_ALLOW_CODE_ACCESS}
  allowlist:
${ALLOWLIST_BLOCK}
YAML

        # Auto-register the pubkey with Semgrep. On HTTP failure we fall
        # through to the manual banner; the broker still starts so registration
        # can be completed by hand.
        REGISTERED=0
        REG_URL="https://${SEMGREP_HOSTNAME}/api/broker/${DEPLOYMENT_ID}/config"
        REG_BODY="$(printf '{"public_key":"%s"}' "${PUBLIC_KEY}")"
        # curl prints '000' for http_code on connection failure and exits
        # non-zero. `|| true` keeps `set -e` happy; the empty-string guard
        # below catches any other unexpected output.
        REG_HTTP_CODE="$(curl -sS -o /tmp/bootstrap_reg.out -w '%{http_code}' \
            -X POST "${REG_URL}" \
            -H "Authorization: Bearer ${SEMGREP_APP_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "${REG_BODY}" || true)"
        case "${REG_HTTP_CODE}" in
            ''|*[!0-9]*) REG_HTTP_CODE="000" ;;
        esac
        if [ "${REG_HTTP_CODE}" -ge 200 ] && [ "${REG_HTTP_CODE}" -lt 300 ]; then
            REGISTERED=1
        else
            REG_ERR_BODY="$(cat /tmp/bootstrap_reg.out 2>/dev/null || true)"
            echo "bootstrap: auto-registration to ${REG_URL} failed (HTTP ${REG_HTTP_CODE}). Falling back to manual instructions." >&2
            if [ -n "${REG_ERR_BODY}" ]; then
                echo "bootstrap: response body: ${REG_ERR_BODY}" >&2
            fi
        fi
        rm -f /tmp/bootstrap_reg.out

        if [ "${REGISTERED}" -eq 1 ]; then
            BANNER_TEXT="
================================================================================
  Semgrep Network Broker — public key auto-registered with Semgrep
--------------------------------------------------------------------------------
  Deployment:     ${DEPLOYMENT_ID}
  Public key:     ${PUBLIC_KEY}
  Config:         ${CONFIG_FILE}

  No further action needed. Within ~60s logs should show
  'Established connectivity with Semgrep'.

  Bootstrap will NOT regenerate keys on subsequent container starts as long as
  ${CONFIG_FILE} exists. Delete that file if you ever need to rotate.
================================================================================
"
        else
            BANNER_TEXT="
================================================================================
  Semgrep Network Broker — REGISTER THIS PUBLIC KEY at https://${SEMGREP_HOSTNAME}
--------------------------------------------------------------------------------
  ${PUBLIC_KEY}
--------------------------------------------------------------------------------
  Config:         ${CONFIG_FILE}

  Steps:
    1. Open https://${SEMGREP_HOSTNAME} and navigate to your org's Network Broker
       settings (under SCM / integrations).
    2. Paste the public key above into the registration form.
    3. The broker is already running and retrying heartbeats. Within ~60s of
       registration, logs will show 'Established connectivity with Semgrep' —
       no restart needed.

  (Auto-registration was attempted but failed — see the 'auto-registration ...
  failed' line above for the HTTP status and response body.)

  To re-display this banner later:  docker logs <container-name>

  Bootstrap will NOT regenerate keys on subsequent container starts as long as
  ${CONFIG_FILE} exists. Delete that file if you ever need to rotate.
================================================================================
"
        fi
        # Print to both streams so it surfaces regardless of how the container
        # is launched (detached, attached, captured to a logger, etc.).
        printf '%s\n' "${BANNER_TEXT}" >&2
        printf '%s\n' "${BANNER_TEXT}"
    fi
fi

exec "${BROKER_BIN}" "$@"

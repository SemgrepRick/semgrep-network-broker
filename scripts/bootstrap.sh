#!/bin/sh
# Bootstrap entrypoint for semgrep-network-broker.
#
# When SCM_TYPE or SCM_CONFIG_FILE is set, this script regenerates a WireGuard
# keypair, writes a minimal config.yaml to ${CONFIG_DIR}, then execs the
# broker. The pubkey is auto-registered against the Semgrep API using
# SEMGREP_APP_TOKEN and the deployment id (from SEMGREP_DEPLOYMENT_ID or the
# broker's -d/--deployment-id flag) — both are required on first boot. If the
# registration HTTP call fails (bad token, network blip, etc.) the broker
# still starts and a manual-registration banner is printed to `docker logs`.
#
# Two bootstrap modes:
#   - Single-SCM (SCM_TYPE set): bootstrap generates the per-SCM config block
#     (baseUrl, allowCodeAccess) and a broad allowlist for SCM_BASE_URL.
#   - Multi-SCM / bring-your-own (SCM_CONFIG_FILE set, SCM_TYPE unset): the
#     bootstrap-generated config is wireguard-only; the user's file is layered
#     on top via a second `-c` flag at exec time. The user's file is a normal
#     broker config snippet — they can define multiple `inbound.github:` /
#     `inbound.gitlab:` blocks and the broker will auto-populate the curated
#     per-SCM allowlists, or provide their own `inbound.allowlist:` entries.
#
# SCM_CONFIG_FILE can also be combined with SCM_TYPE to overlay extra config on
# top of the single-SCM-generated scaffold (e.g., to replace the default broad
# allowlist with a tightened one). Viper merges maps; arrays replace.
#
# Config persistence is tied to the container, not a mounted volume:
# ${CONFIG_DIR} lives in the container's writable layer, so config.yaml
# survives `docker restart` / host reboots under --restart=always, but a fresh
# `docker run` regenerates the keypair and re-registers with Semgrep.
#
# When neither SCM_TYPE nor SCM_CONFIG_FILE is set, the script is a
# pass-through to the broker binary — preserving the original ENTRYPOINT
# behavior for genkey/pubkey/relay/dump and normal `-c ... -d ...` invocations.

set -eu

BROKER_BIN="${BROKER_BIN:-/usr/bin/semgrep-network-broker}"
CONFIG_DIR="${CONFIG_DIR:-/var/lib/semgrep-network-broker}"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SEMGREP_HOSTNAME="${SEMGREP_HOSTNAME:-semgrep.dev}"

if [ -n "${SCM_TYPE:-}" ] || [ -n "${SCM_CONFIG_FILE:-}" ]; then
    # Validate SCM_CONFIG_FILE up front so we fail fast — it's used on every
    # exec (both first boot and restart), not just when generating config.
    if [ -n "${SCM_CONFIG_FILE:-}" ]; then
        if [ ! -f "${SCM_CONFIG_FILE}" ]; then
            echo "bootstrap: SCM_CONFIG_FILE='${SCM_CONFIG_FILE}' not found or not a regular file" >&2
            exit 1
        fi
        if [ ! -r "${SCM_CONFIG_FILE}" ]; then
            echo "bootstrap: SCM_CONFIG_FILE='${SCM_CONFIG_FILE}' is not readable by UID $(id -u)" >&2
            exit 1
        fi
        if [ ! -s "${SCM_CONFIG_FILE}" ]; then
            echo "bootstrap: SCM_CONFIG_FILE='${SCM_CONFIG_FILE}' is empty — refusing to start broker with an empty overlay" >&2
            exit 1
        fi
    fi

    # SCM_TYPE-specific validation and base-url derivation. When SCM_TYPE is
    # unset (multi-SCM / bring-your-own mode), bootstrap skips the per-SCM
    # `inbound.${SCM_TYPE}:` config block and the default broad allowlist; the
    # user's SCM_CONFIG_FILE supplies everything via the `-c` overlay.
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
    fi

    if [ ! -d "${CONFIG_DIR}" ]; then
        echo "bootstrap: ${CONFIG_DIR} does not exist — the image pre-creates it; set CONFIG_DIR or mount a writable directory if you're overriding the default" >&2
        exit 1
    fi

    # Resolve the deployment id on every invocation (not just first boot) — the
    # broker needs `-d <id>` whether or not bootstrap is generating a new config,
    # and we may need to inject it into the exec line below. CLI flag wins; env
    # var is the fallback so users can configure it alongside the other -e vars.
    DEPLOYMENT_ID=""
    DEPLOYMENT_ID_FROM_ARGS=0
    NEXT_IS_DID=0
    for arg in "$@"; do
        if [ "${NEXT_IS_DID}" -eq 1 ]; then
            DEPLOYMENT_ID="${arg}"
            DEPLOYMENT_ID_FROM_ARGS=1
            break
        fi
        case "${arg}" in
            -d|--deployment-id)  NEXT_IS_DID=1 ;;
            -d=*)                DEPLOYMENT_ID="${arg#-d=}"; DEPLOYMENT_ID_FROM_ARGS=1; break ;;
            --deployment-id=*)   DEPLOYMENT_ID="${arg#--deployment-id=}"; DEPLOYMENT_ID_FROM_ARGS=1; break ;;
        esac
    done

    if [ -z "${DEPLOYMENT_ID}" ] && [ -n "${SEMGREP_DEPLOYMENT_ID:-}" ]; then
        DEPLOYMENT_ID="${SEMGREP_DEPLOYMENT_ID}"
    fi

    if [ -z "${DEPLOYMENT_ID}" ]; then
        echo "bootstrap: deployment id is required — set SEMGREP_DEPLOYMENT_ID or pass -d <id> after the image name" >&2
        exit 1
    fi

    if [ -f "${CONFIG_FILE}" ]; then
        echo "bootstrap: ${CONFIG_FILE} already exists — reusing it. (Config persists across 'docker restart' for this container; a fresh 'docker run' would regenerate.)" >&2
    else
        if [ ! -w "${CONFIG_DIR}" ]; then
            echo "bootstrap: ${CONFIG_DIR} is not writable by UID $(id -u). chown the host directory to that UID, or run the container with --user." >&2
            exit 1
        fi

        # Validate first-boot prerequisites BEFORE generating a key or writing
        # config.yaml — otherwise a failed validation would leave a stale,
        # unregistered key in the container layer that the idempotency check
        # would silently reuse on the next `docker restart`.
        if [ -z "${SEMGREP_APP_TOKEN:-}" ]; then
            echo "bootstrap: SEMGREP_APP_TOKEN must be set on first boot so the pubkey can be auto-registered with Semgrep" >&2
            exit 1
        fi

        PRIVATE_KEY="$("${BROKER_BIN}" genkey)"
        PUBLIC_KEY="$(printf '%s' "${PRIVATE_KEY}" | "${BROKER_BIN}" pubkey)"

        # Build the per-SCM block + default allowlist when SCM_TYPE is set. In
        # multi-SCM / bring-your-own mode (SCM_TYPE unset, SCM_CONFIG_FILE set),
        # the bootstrap-generated config is wireguard-only — the user's
        # SCM_CONFIG_FILE supplies the SCM block(s) and/or allowlist via the
        # `-c` overlay added at exec time.
        SCM_AND_ALLOWLIST_BLOCK=""
        if [ -n "${SCM_TYPE:-}" ]; then
            SCM_AND_ALLOWLIST_BLOCK="
  ${SCM_TYPE}:
    baseUrl: ${API_URL}
    allowCodeAccess: ${SCM_ALLOW_CODE_ACCESS}
  allowlist:
    # Broad start: any path under the SCM host, all common methods. Tighten
    # later by replacing this block with specific URL patterns (see README),
    # or set SCM_CONFIG_FILE to overlay your own allowlist on top.
    - url: \"${BASE_URL}/*\"
      methods: [GET, POST, PUT, PATCH, DELETE]"
        fi

        umask 077
        cat > "${CONFIG_FILE}" <<YAML
# Generated by semgrep-network-broker bootstrap on $(date -u +%FT%TZ).
# Contains a WireGuard private key — do not commit or share.
inbound:
  wireguard:
    privateKey: ${PRIVATE_KEY}${SCM_AND_ALLOWLIST_BLOCK}
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

  No further action needed. Within ~30s logs should show
  'Established connectivity with Semgrep'.

  Config persists across 'docker restart' / host reboots for this container.
  A fresh 'docker run' will generate a new keypair and re-register with
  Semgrep automatically.
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

  Config persists across 'docker restart' / host reboots for this container.
  A fresh 'docker run' will generate a new keypair and re-register with
  Semgrep automatically.
================================================================================
"
        fi
        # Print to both streams so it surfaces regardless of how the container
        # is launched (detached, attached, captured to a logger, etc.).
        printf '%s\n' "${BANNER_TEXT}" >&2
        printf '%s\n' "${BANNER_TEXT}"
    fi

    # Bootstrap wrote (or reused) ${CONFIG_FILE}, so inject `-c ${CONFIG_FILE}`
    # automatically — the user doesn't need to repeat the path on the docker
    # command line. If SCM_CONFIG_FILE is set, layer it on top as a second `-c`
    # so the user's SCM blocks / allowlist / overrides merge in (maps merge,
    # arrays replace; see README). Any additional `-c` flags from "$@" land
    # after both and overlay on top of those.
    #
    # If the deployment id came from SEMGREP_DEPLOYMENT_ID (env), inject `-d`
    # too so the broker sees it. If it came from `-d` on the CLI it's already
    # in "$@".
    if [ -n "${SCM_CONFIG_FILE:-}" ]; then
        if [ "${DEPLOYMENT_ID_FROM_ARGS:-0}" -eq 0 ]; then
            exec "${BROKER_BIN}" -c "${CONFIG_FILE}" -c "${SCM_CONFIG_FILE}" -d "${DEPLOYMENT_ID}" "$@"
        fi
        exec "${BROKER_BIN}" -c "${CONFIG_FILE}" -c "${SCM_CONFIG_FILE}" "$@"
    fi
    if [ "${DEPLOYMENT_ID_FROM_ARGS:-0}" -eq 0 ] && [ -n "${DEPLOYMENT_ID:-}" ]; then
        exec "${BROKER_BIN}" -c "${CONFIG_FILE}" -d "${DEPLOYMENT_ID}" "$@"
    fi
    exec "${BROKER_BIN}" -c "${CONFIG_FILE}" "$@"
fi

exec "${BROKER_BIN}" "$@"

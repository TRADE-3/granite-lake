#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

CONFIG_KEYS=(
  VAULT_ADDR
  VAULT_HOST_PORT
  VAULT_TOKEN
  NODE_ENV
  CLIENT_ID
  VAULT_KV_MOUNT
)

SECRET_KEYS=(
  SUI_PRIVATE_KEY
)

is_config_key() {
  local key="$1"

  for config_key in "${CONFIG_KEYS[@]}"; do
    [[ "${key}" == "${config_key}" ]] && return 0
  done

  return 1
}

is_secret_key() {
  local key="$1"

  for secret_key in "${SECRET_KEYS[@]}"; do
    [[ "${key}" == "${secret_key}" ]] && return 0
  done

  return 1
}

load_env_file() {
  local file="$1"

  if [[ ! -f "${file}" ]]; then
    return
  fi

  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="${value%$'\r'}"
    value="${value%%#*}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    if is_config_key "${key}"; then
      export "${key}=${value}"
    elif is_secret_key "${key}" && [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    elif [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done < "${file}"
}

load_env_file "${ENV_FILE}"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_HOST_PORT:-8200}}"
VAULT_TOKEN="${VAULT_TOKEN:-dev-root-token}"
NODE_ENV="${NODE_ENV:-development}"
CLIENT_ID="${CLIENT_ID:-domain_demo}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_SECRET_PATH="${NODE_ENV}/${CLIENT_ID}/static"

export VAULT_ADDR
export VAULT_TOKEN

if [[ "${VAULT_ADDR}" == http://vault:* ]]; then
  VAULT_ADDR="http://127.0.0.1:${VAULT_ADDR#http://vault:}"
  export VAULT_ADDR
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "Missing Vault CLI. Install it first: https://developer.hashicorp.com/vault/install"
  exit 1
fi

if ! vault status >/dev/null 2>&1; then
  echo "Could not reach local Vault at ${VAULT_ADDR}."
  echo "Start it first with: docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env up --build -d vault"
  exit 1
fi

kv_args=()
written_names=()
skipped_names=()

append_secret() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" || "${value}" == vault://* ]]; then
    skipped_names+=("${name}")
    return
  fi

  kv_args+=("${name}=${value}")
  written_names+=("${name}")
}

prompt_secret() {
  local name="$1"
  local current_value="${!name:-}"

  if [[ -n "${current_value}" && "${current_value}" != vault://* ]]; then
    append_secret "${name}" "${current_value}"
    return
  fi

  local value
  printf "%s (leave blank to skip): " "${name}"
  read -r -s value || value=""
  printf "\n"
  append_secret "${name}" "${value}"
}

echo "Writing local Vault KV secrets"
echo "Env file: ${ENV_FILE}"
echo "Vault address: ${VAULT_ADDR}"
echo "Secret path: ${VAULT_KV_MOUNT}/${VAULT_SECRET_PATH}"
echo "Client: ${CLIENT_ID}"
echo "Environment: ${NODE_ENV}"
echo

for secret_key in "${SECRET_KEYS[@]}"; do
  prompt_secret "${secret_key}"
done

if [[ "${#kv_args[@]}" -eq 0 ]]; then
  echo "No secret values were provided. Nothing written."
  echo "Skipped: ${skipped_names[*]:-(none)}"
  exit 0
fi

write_error=""
if ! write_error="$(vault kv patch "${VAULT_KV_MOUNT}/${VAULT_SECRET_PATH}" "${kv_args[@]}" 2>&1)"; then
  if [[ "${write_error}" == *"Code: 404"* || "${write_error}" == *" 404"* ]]; then
    if ! write_error="$(vault kv put "${VAULT_KV_MOUNT}/${VAULT_SECRET_PATH}" "${kv_args[@]}" 2>&1)"; then
      echo
      echo "Failed to create secrets in Vault."
      echo "${write_error}"
      echo "Using VAULT_ADDR=${VAULT_ADDR}"
      echo "Using token from ${ENV_FILE} or your shell environment."
      exit 1
    fi
  else
    echo
    echo "Failed to write secrets to Vault."
    echo "${write_error}"
    echo "Using VAULT_ADDR=${VAULT_ADDR}"
    echo "Using token from ${ENV_FILE} or your shell environment."
    echo "If Vault was recreated, restart it with the same VAULT_TOKEN or update .env to match the current dev root token."
    exit 1
  fi
fi

echo "Wrote ${#kv_args[@]} secret value(s) to ${VAULT_KV_MOUNT}/${VAULT_SECRET_PATH}."
echo "Written: ${written_names[*]}"
echo "Skipped: ${skipped_names[*]:-(none)}"

if command -v node >/dev/null 2>&1; then
  stored_names="$(
    vault kv get -format=json "${VAULT_KV_MOUNT}/${VAULT_SECRET_PATH}" \
      | node -e 'let input = ""; process.stdin.on("data", (chunk) => input += chunk); process.stdin.on("end", () => { const parsed = JSON.parse(input); console.log(Object.keys(parsed.data.data).sort().join(", ")); });'
  )"
  echo "Stored keys now: ${stored_names}"
else
  echo "Verify names with: VAULT_ADDR=${VAULT_ADDR} VAULT_TOKEN='<token>' vault kv get -format=json ${VAULT_KV_MOUNT}/${VAULT_SECRET_PATH}"
fi

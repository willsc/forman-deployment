#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

API_BASE="${FOREMAN_PUBLIC_URL}/api"
AUTH="${FOREMAN_ADMIN_USER}:${FOREMAN_ADMIN_PASSWORD}"
TMP_BODY="$(mktemp)"
trap 'rm -f "${TMP_BODY}"' EXIT

log() {
  printf '[configure] %s\n' "$*"
}

fail() {
  printf '[configure] %s\n' "$*" >&2
  exit 1
}

api_get() {
  local path="$1"
  curl -fsS -u "${AUTH}" -H 'Accept: application/json' "${API_BASE}${path}"
}

api_post() {
  local path="$1"
  local body="$2"
  printf '%s' "${body}" > "${TMP_BODY}"
  curl -sS -u "${AUTH}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -w '\nHTTP_STATUS:%{http_code}\n' -X POST --data @"${TMP_BODY}" "${API_BASE}${path}"
}

api_put() {
  local path="$1"
  local body="$2"
  printf '%s' "${body}" > "${TMP_BODY}"
  curl -sS -u "${AUTH}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -w '\nHTTP_STATUS:%{http_code}\n' -X PUT --data @"${TMP_BODY}" "${API_BASE}${path}"
}

parse_api_response() {
  local response="$1"
  local status body
  status="$(printf '%s' "${response}" | sed -n 's/^HTTP_STATUS://p' | tail -n1)"
  body="$(printf '%s' "${response}" | sed '/^HTTP_STATUS:/d')"
  if [[ -z "${status}" ]]; then
    printf '%s' "${body}"
    return 0
  fi
  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    printf '[configure] API request failed with HTTP %s\n%s\n' "${status}" "${body}" >&2
    return 1
  fi
  printf '%s' "${body}"
}

lookup_id() {
  local path="$1"
  local search="$2"
  api_get "${path}?search=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "${search}")&per_page=200" \
    | jq -r '.results[0].id // empty'
}

ensure_named_resource() {
  local path="$1"
  local search="$2"
  local body="$3"
  local id

  id="$(lookup_id "${path}" "${search}")"
  if [[ -z "${id}" ]]; then
    log "Creating resource for ${path} with search ${search}"
    id="$(parse_api_response "$(api_post "${path}" "${body}")" | jq -r '.id // empty')"
    if [[ -z "${id}" ]]; then
      printf '[configure] Resource creation for %s did not return an id\n' "${path}" >&2
      return 1
    fi
  fi
  printf '%s' "${id}"
}

require_id() {
  local label="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    fail "Missing id for ${label}"
  fi
}

file_text_or_empty() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    cat "${path}"
  fi
}

ensure_common_parameter() {
  local name="$1"
  local value="$2"
  local id body
  id="$(lookup_id "/common_parameters" "name=\"${name}\"")"
  body="$(jq -nc --arg name "${name}" --arg value "${value}" '{common_parameter:{name:$name,value:$value}}')"
  if [[ -z "${id}" ]]; then
    log "Creating common parameter ${name}"
    id="$(parse_api_response "$(api_post "/common_parameters" "${body}")" | jq -r '.id // empty')"
  else
    parse_api_response "$(api_put "/common_parameters/${id}" "${body}")" >/dev/null
  fi
  require_id "common parameter ${name}" "${id}"
}

ORG_ID="$(ensure_named_resource "/organizations" "name=\"${FOREMAN_ORGANIZATION}\"" "{\"organization\":{\"name\":\"${FOREMAN_ORGANIZATION}\"}}")"
LOC_ID="$(ensure_named_resource "/locations" "name=\"${FOREMAN_LOCATION}\"" "{\"location\":{\"name\":\"${FOREMAN_LOCATION}\"}}")"
DOMAIN_ID="$(ensure_named_resource "/domains" "name=\"${PXE_DOMAIN}\"" "{\"domain\":{\"name\":\"${PXE_DOMAIN}\"}}")"
PROXY_ID="$(ensure_named_resource "/smart_proxies" "name=\"${FOREMAN_PROXY_NAME}\"" "{\"smart_proxy\":{\"name\":\"${FOREMAN_PROXY_NAME}\",\"url\":\"${FOREMAN_PROXY_URL}\"}}")"
UBUNTU_MEDIA_ID="$(ensure_named_resource "/media" "name=\"Ubuntu 24.04.4 Desktop\"" "{\"medium\":{\"name\":\"Ubuntu 24.04.4 Desktop\",\"path\":\"${PROXY_HTTP_URL}/ubuntu/24.04.4\",\"os_family\":\"Debian\"}}")"
WINDOWS_MEDIA_ID="$(ensure_named_resource "/media" "name=\"Windows 11 ISO\"" "{\"medium\":{\"name\":\"Windows 11 ISO\",\"path\":\"${PROXY_HTTP_URL}/windows/11\"}}")"

require_id "organization" "${ORG_ID}"
require_id "location" "${LOC_ID}"
require_id "domain" "${DOMAIN_ID}"
require_id "smart proxy" "${PROXY_ID}"
require_id "ubuntu media" "${UBUNTU_MEDIA_ID}"
require_id "windows media" "${WINDOWS_MEDIA_ID}"

SUBNET_SEARCH="network=\"${PXE_SUBNET}\" and mask=\"${PXE_NETMASK}\""
SUBNET_ID="$(lookup_id "/subnets" "${SUBNET_SEARCH}")"

if [[ -z "${SUBNET_ID}" ]]; then
  DHCP_ID_JSON="null"
  if [[ "${PROXY_DHCP_MODE}" == "managed" ]]; then
    DHCP_ID_JSON="${PROXY_ID}"
  fi

  SUBNET_BODY="$(jq -nc \
    --arg name "PXE ${PXE_SUBNET}" \
    --arg network "${PXE_SUBNET}" \
    --arg mask "${PXE_NETMASK}" \
    --arg gateway "${PXE_GATEWAY}" \
    --arg dns_primary "$(printf '%s' "${PXE_DNS_SERVERS}" | cut -d, -f1)" \
    --argjson domain_ids "[${DOMAIN_ID}]" \
    --argjson location_ids "[${LOC_ID}]" \
    --argjson organization_ids "[${ORG_ID}]" \
    --argjson tftp_id "${PROXY_ID}" \
    --argjson httpboot_id "${PROXY_ID}" \
    --argjson dhcp_id "${DHCP_ID_JSON}" \
    '{
      subnet: {
        name: $name,
        network: $network,
        mask: $mask,
        gateway: $gateway,
        dns_primary: $dns_primary,
        ipam: "DHCP",
        boot_mode: "DHCP",
        domain_ids: $domain_ids,
        location_ids: $location_ids,
        organization_ids: $organization_ids,
        tftp_id: $tftp_id,
        httpboot_id: $httpboot_id,
        dhcp_id: $dhcp_id
      }
    }')"
  SUBNET_ID="$(parse_api_response "$(api_post "/subnets" "${SUBNET_BODY}")" | jq -r '.id // empty')"
else
  DHCP_ID_JSON="null"
  if [[ "${PROXY_DHCP_MODE}" == "managed" ]]; then
    DHCP_ID_JSON="${PROXY_ID}"
  fi
  SUBNET_BODY="$(jq -nc \
    --argjson domain_ids "[${DOMAIN_ID}]" \
    --argjson location_ids "[${LOC_ID}]" \
    --argjson organization_ids "[${ORG_ID}]" \
    --argjson tftp_id "${PROXY_ID}" \
    --argjson httpboot_id "${PROXY_ID}" \
    --argjson dhcp_id "${DHCP_ID_JSON}" \
    '{subnet:{domain_ids:$domain_ids,location_ids:$location_ids,organization_ids:$organization_ids,tftp_id:$tftp_id,httpboot_id:$httpboot_id,dhcp_id:$dhcp_id}}')"
  parse_api_response "$(api_put "/subnets/${SUBNET_ID}" "${SUBNET_BODY}")" >/dev/null
fi

ensure_common_parameter "provision_method" "ubuntu"
ensure_common_parameter "ubuntu_autoinstall_username" "${UBUNTU_AUTOINSTALL_USERNAME}"
ensure_common_parameter "ubuntu_autoinstall_password" "${UBUNTU_AUTOINSTALL_PASSWORD}"
ensure_common_parameter "ubuntu_autoinstall_realname" "${UBUNTU_AUTOINSTALL_REALNAME}"
ensure_common_parameter "ubuntu_autoinstall_hostname" "${UBUNTU_AUTOINSTALL_HOSTNAME}"
ensure_common_parameter "ubuntu_autoinstall_locale" "${UBUNTU_AUTOINSTALL_LOCALE}"
ensure_common_parameter "ubuntu_autoinstall_keyboard" "${UBUNTU_AUTOINSTALL_KEYBOARD}"
ensure_common_parameter "ubuntu_autoinstall_timezone" "${UBUNTU_AUTOINSTALL_TIMEZONE}"
ensure_common_parameter "ubuntu_packages" "$(file_text_or_empty "${ROOT_DIR}/config/ubuntu-packages.txt")"
ensure_common_parameter "windows_image_name" "${WINDOWS_IMAGE_NAME}"
ensure_common_parameter "windows_local_admin_user" "${WINDOWS_LOCAL_ADMIN_USER}"
ensure_common_parameter "windows_local_admin_password" "${WINDOWS_LOCAL_ADMIN_PASSWORD}"
ensure_common_parameter "windows_computer_name" "${WINDOWS_COMPUTER_NAME}"
ensure_common_parameter "windows_locale" "${WINDOWS_LOCALE}"
ensure_common_parameter "windows_target_disk" "${WINDOWS_TARGET_DISK}"
ensure_common_parameter "windows_winget_packages" "$(file_text_or_empty "${ROOT_DIR}/config/windows-winget-packages.txt")"
ensure_common_parameter "windows_postinstall_ps1" "$(file_text_or_empty "${ROOT_DIR}/config/windows-postinstall.ps1")"

printf 'Configured organization %s (%s)\n' "${FOREMAN_ORGANIZATION}" "${ORG_ID}"
printf 'Configured location %s (%s)\n' "${FOREMAN_LOCATION}" "${LOC_ID}"
printf 'Configured domain %s (%s)\n' "${PXE_DOMAIN}" "${DOMAIN_ID}"
printf 'Configured smart proxy %s (%s)\n' "${FOREMAN_PROXY_NAME}" "${PROXY_ID}"
printf 'Configured Ubuntu media (%s) and Windows media (%s)\n' "${UBUNTU_MEDIA_ID}" "${WINDOWS_MEDIA_ID}"
printf 'Configured subnet %s (%s)\n' "${PXE_SUBNET}" "${SUBNET_ID}"

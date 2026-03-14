#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

log() {
  printf '[%s] [prepare] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

MEDIA_ROOT="${MEDIA_ROOT:-${ROOT_DIR}/media}"
ISO_CACHE="${ROOT_DIR}/.iso-cache"
CONFIG_ROOT="${ROOT_DIR}/config"
HTTP_BOOT_ROOT="${MEDIA_ROOT}/boot"
AUTOINSTALL_ROOT="${MEDIA_ROOT}/autoinstall"
UBUNTU_AUTOINSTALL_ROOT="${AUTOINSTALL_ROOT}/ubuntu"
WINDOWS_AUTOINSTALL_ROOT="${AUTOINSTALL_ROOT}/windows"
UBUNTU_SRC="${MEDIA_ROOT}/ubuntu/24.04.4"
WINDOWS_SRC="${MEDIA_ROOT}/windows/11"
WINDOWS_OEM_ROOT="${WINDOWS_SRC}/sources/\$OEM\$/\$\$/Setup/Scripts"
WINDOWS_WIM_XML="${WINDOWS_SRC}/sources/install.wim.xml"
TFTP_ROOT="${MEDIA_ROOT}/tftpboot"
UBUNTU_PACKAGES_FILE="${CONFIG_ROOT}/ubuntu-packages.txt"
WINDOWS_WINGET_FILE="${CONFIG_ROOT}/windows-winget-packages.txt"
WINDOWS_POSTINSTALL_FILE="${CONFIG_ROOT}/windows-postinstall.ps1"
UBUNTU_AUTOINSTALL_USERNAME="${UBUNTU_AUTOINSTALL_USERNAME:-admin}"
UBUNTU_AUTOINSTALL_PASSWORD="${UBUNTU_AUTOINSTALL_PASSWORD:-admin}"
UBUNTU_AUTOINSTALL_REALNAME="${UBUNTU_AUTOINSTALL_REALNAME:-Ubuntu Admin}"
UBUNTU_AUTOINSTALL_HOSTNAME="${UBUNTU_AUTOINSTALL_HOSTNAME:-ubuntu-client}"
UBUNTU_AUTOINSTALL_LOCALE="${UBUNTU_AUTOINSTALL_LOCALE:-en_GB.UTF-8}"
UBUNTU_AUTOINSTALL_KEYBOARD="${UBUNTU_AUTOINSTALL_KEYBOARD:-gb}"
UBUNTU_AUTOINSTALL_TIMEZONE="${UBUNTU_AUTOINSTALL_TIMEZONE:-Etc/UTC}"
WINDOWS_IMAGE_NAME="${WINDOWS_IMAGE_NAME:-Windows 11 Pro}"
WINDOWS_LOCAL_ADMIN_USER="${WINDOWS_LOCAL_ADMIN_USER:-admin}"
WINDOWS_LOCAL_ADMIN_PASSWORD="${WINDOWS_LOCAL_ADMIN_PASSWORD:-admin}"
WINDOWS_COMPUTER_NAME="${WINDOWS_COMPUTER_NAME:-WIN11-%SERIAL%}"
WINDOWS_LOCALE="${WINDOWS_LOCALE:-en-GB}"
WINDOWS_TARGET_DISK="${WINDOWS_TARGET_DISK:-0}"

mkdir -p \
  "${HTTP_BOOT_ROOT}" \
  "${UBUNTU_SRC}" \
  "${WINDOWS_SRC}" \
  "${TFTP_ROOT}" \
  "${UBUNTU_AUTOINSTALL_ROOT}" \
  "${WINDOWS_AUTOINSTALL_ROOT}" \
  "${WINDOWS_OEM_ROOT}" \
  "${CONFIG_ROOT}"

extract_iso() {
  local iso="$1"
  local target="$2"

  if [[ -f "${target}/.extracted" ]]; then
    log "Reusing extracted media in ${target}"
    return
  fi

  rm -rf "${target:?}/"*
  log "Extracting $(basename "${iso}") into ${target}"
  7z x -y "-o${target}" "${iso}" >/dev/null
  touch "${target}/.extracted"
}

download_wimboot() {
  local out="${HTTP_BOOT_ROOT}/wimboot"
  if [[ -s "${out}" ]]; then
    log "Reusing ${out}"
    return
  fi
  log "Downloading wimboot"
  curl -fL --retry 5 --retry-delay 5 --progress-bar -o "${out}" \
    "https://github.com/ipxe/wimboot/releases/latest/download/wimboot"
}

extract_windows_wim_metadata() {
  if [[ -s "${WINDOWS_WIM_XML}" ]]; then
    log "Reusing ${WINDOWS_WIM_XML}"
    return
  fi
  log "Extracting Windows WIM metadata"
  python3 - "${WINDOWS_SRC}/sources/install.wim" "${WINDOWS_WIM_XML}" <<'PY'
import subprocess
import sys

src = sys.argv[1]
dst = sys.argv[2]
raw = subprocess.check_output(["7z", "x", "-so", src, "[1].xml"])
text = raw.decode("utf-16le", errors="ignore").lstrip("\ufeff")
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
}

ensure_config_defaults() {
  if [[ ! -f "${UBUNTU_PACKAGES_FILE}" ]]; then
    cat > "${UBUNTU_PACKAGES_FILE}" <<'EOF'
# One Ubuntu package per line.
# Lines beginning with # are ignored.

openssh-server
qemu-guest-agent
EOF
  fi

  if [[ ! -f "${WINDOWS_WINGET_FILE}" ]]; then
    cat > "${WINDOWS_WINGET_FILE}" <<'EOF'
# One winget package id per line.
# Lines beginning with # are ignored.
# Example:
# Microsoft.PowerToys
# Git.Git
EOF
  fi

  if [[ ! -f "${WINDOWS_POSTINSTALL_FILE}" ]]; then
    cat > "${WINDOWS_POSTINSTALL_FILE}" <<'EOF'
# Additional PowerShell commands to run after Windows Setup completes.
# This script is copied into C:\Windows\Setup\Scripts\PostInstall.ps1.

Write-Host "Custom Windows post-install hook executed."
EOF
  fi
}

python3 - <<'PY' >/dev/null 2>&1 || true
import crypt  # noqa: F401
PY

ubuntu_password_hash() {
  python3 - "$UBUNTU_AUTOINSTALL_PASSWORD" <<'PY'
import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)
import crypt
import secrets
import sys

password = sys.argv[1]
salt = "$6$" + secrets.token_hex(8)
print(crypt.crypt(password, salt))
PY
}

ubuntu_package_yaml() {
  python3 - "${UBUNTU_PACKAGES_FILE}" <<'PY'
from pathlib import Path
import sys

items = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    items.append(line)

for item in items:
    print(f"      - {item}")
PY
}

detect_windows_image() {
  python3 - "${WINDOWS_SRC}/sources/install.wim" "${WINDOWS_IMAGE_NAME:-Windows 11 Pro}" <<'PY'
import re
import subprocess
import sys
from xml.etree import ElementTree as ET

wim_path = sys.argv[1]
requested = sys.argv[2].strip().lower()

raw = subprocess.check_output(["7z", "x", "-so", wim_path, "[1].xml"])
text = raw.decode("utf-16le", errors="ignore").lstrip("\ufeff")
root = ET.fromstring(text)

matches = []
for image in root.findall("IMAGE"):
    idx = image.attrib.get("INDEX", "")
    name = (image.findtext("NAME") or image.findtext("DISPLAYNAME") or "").strip()
    if name:
      matches.append((name, idx))

selected = None
for name, idx in matches:
    if name.lower() == requested:
        selected = (name, idx)
        break

if selected is None:
    for name, idx in matches:
        if requested in name.lower():
            selected = (name, idx)
            break

if selected is None:
    for name, idx in matches:
        if name.lower() == "windows 11 pro":
            selected = (name, idx)
            break

if selected is None and matches:
    selected = matches[0]

if selected is None:
    raise SystemExit("Unable to detect a Windows image in install.wim")

print(selected[0])
print(selected[1])
PY
}

xml_escape() {
  python3 - "$1" <<'PY'
import sys
from xml.sax.saxutils import escape

print(escape(sys.argv[1], {'"': '&quot;'}))
PY
}

windows_package_script() {
  python3 - "${WINDOWS_WINGET_FILE}" <<'PY'
from pathlib import Path
import sys

items = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    items.append(line)

if not items:
    print('Write-Host "No additional winget packages requested."')
else:
    print('if (Get-Command winget -ErrorAction SilentlyContinue) {')
    for item in items:
        safe = item.replace("'", "''")
        print(f"  winget install --id '{safe}' --accept-source-agreements --accept-package-agreements --silent --disable-interactivity")
    print('} else {')
    print('  Write-Warning "winget is not available; skipping package installation."')
    print('}')
PY
}

write_ubuntu_autoinstall() {
  local password_hash package_yaml
  password_hash="$(ubuntu_password_hash)"
  package_yaml="$(ubuntu_package_yaml)"

  cat > "${UBUNTU_AUTOINSTALL_ROOT}/meta-data" <<EOF
instance-id: ubuntu-autoinstall
local-hostname: ${UBUNTU_AUTOINSTALL_HOSTNAME}
EOF

  cat > "${UBUNTU_AUTOINSTALL_ROOT}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: ${UBUNTU_AUTOINSTALL_LOCALE}
  keyboard:
    layout: ${UBUNTU_AUTOINSTALL_KEYBOARD}
  timezone: ${UBUNTU_AUTOINSTALL_TIMEZONE}
  identity:
    hostname: ${UBUNTU_AUTOINSTALL_HOSTNAME}
    realname: "${UBUNTU_AUTOINSTALL_REALNAME}"
    username: ${UBUNTU_AUTOINSTALL_USERNAME}
    password: "${password_hash}"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
  packages:
${package_yaml}
  late-commands:
    - curtin in-target --target=/target systemctl enable ssh || true
EOF
}

write_windows_setup_scripts() {
  local winget_block
  winget_block="$(windows_package_script)"

  cp -f "${WINDOWS_POSTINSTALL_FILE}" "${WINDOWS_OEM_ROOT}/PostInstall.ps1"
  cat > "${WINDOWS_OEM_ROOT}/SetupComplete.cmd" <<'EOF'
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Install-Packages.ps1"
powershell.exe -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\PostInstall.ps1"
exit /b 0
EOF

  cat > "${WINDOWS_OEM_ROOT}/Install-Packages.ps1" <<EOF
\$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\Windows\Setup\Scripts\Install-Packages.log' -Append
${winget_block}
Stop-Transcript
EOF
}

write_windows_unattend() {
  local image_name image_index locale admin_user admin_password computer_name target_disk
  mapfile -t _win_image < <(detect_windows_image)
  image_name="${_win_image[0]}"
  image_index="${_win_image[1]}"
  locale="$(xml_escape "${WINDOWS_LOCALE}")"
  admin_user="$(xml_escape "${WINDOWS_LOCAL_ADMIN_USER}")"
  admin_password="$(xml_escape "${WINDOWS_LOCAL_ADMIN_PASSWORD}")"
  computer_name="$(xml_escape "${WINDOWS_COMPUTER_NAME}")"
  target_disk="${WINDOWS_TARGET_DISK}"

  cat > "${WINDOWS_AUTOINSTALL_ROOT}/Autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>${locale}</UILanguage>
      </SetupUILanguage>
      <InputLocale>${locale}</InputLocale>
      <SystemLocale>${locale}</SystemLocale>
      <UILanguage>${locale}</UILanguage>
      <UserLocale>${locale}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DynamicUpdate>
        <Enable>false</Enable>
      </DynamicUpdate>
      <DiskConfiguration>
        <Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <DiskID>${target_disk}</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>100</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/INDEX</Key>
              <Value>${image_index}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>${target_disk}</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>${computer_name}</ComputerName>
      <TimeZone>GMT Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>${locale}</InputLocale>
      <SystemLocale>${locale}</SystemLocale>
      <UILanguage>${locale}</UILanguage>
      <UserLocale>${locale}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>${admin_user}</Username>
        <Password>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>${admin_password}</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>${admin_user}</Name>
            <Group>Administrators</Group>
            <DisplayName>${admin_user}</DisplayName>
            <Password>
              <Value>${admin_password}</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <RegisteredOwner>${admin_user}</RegisteredOwner>
      <RegisteredOrganization>Foreman PXE</RegisteredOrganization>
    </component>
  </settings>
  <cpi:offlineImage cpi:source="wim://sources/install.wim#${image_name}" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
EOF
}

write_ipxe_menu() {
  cat > "${HTTP_BOOT_ROOT}/menu.ipxe" <<EOF
#!ipxe
chain ${FOREMAN_PROXY_URL}/boot.ipxe?mac=\${net0/mac}\&uuid=\${uuid}\&serial=\${serial} || shell
EOF
}

prepare_tftp_root() {
  mkdir -p "${TFTP_ROOT}"
}

ensure_config_defaults
log "Copying Ubuntu ISO into HTTP media root"
cp -f "${ISO_CACHE}/ubuntu-24.04.4-desktop-amd64.iso" "${UBUNTU_SRC}/ubuntu-24.04.4-desktop-amd64.iso"
extract_iso "${ISO_CACHE}/ubuntu-24.04.4-desktop-amd64.iso" "${UBUNTU_SRC}"
extract_iso "${ISO_CACHE}/windows11-x64.iso" "${WINDOWS_SRC}"
extract_windows_wim_metadata
download_wimboot
prepare_tftp_root
log "Writing Ubuntu autoinstall configuration"
write_ubuntu_autoinstall
log "Writing Windows unattended configuration"
write_windows_setup_scripts
write_windows_unattend
log "Writing iPXE menu"
write_ipxe_menu
log "PXE media prepared under ${MEDIA_ROOT}"

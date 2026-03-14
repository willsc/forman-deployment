from __future__ import annotations

import base64
import crypt
import json
import os
import secrets
import textwrap
from functools import lru_cache
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen
from xml.sax.saxutils import escape as xml_escape

from flask import Flask, Response, jsonify, request

app = Flask(__name__)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def read_package_file(path: str) -> list[str]:
    file_path = Path(path)
    if not file_path.exists():
        return []
    items = []
    for raw in file_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        items.append(line)
    return items


def read_text_file(path: str) -> str:
    file_path = Path(path)
    if not file_path.exists():
        return ""
    return file_path.read_text(encoding="utf-8").strip()


def foreman_auth_header() -> str:
    credentials = f"{env('FOREMAN_ADMIN_USER', 'admin')}:{env('FOREMAN_ADMIN_PASSWORD', 'admin')}"
    encoded = base64.b64encode(credentials.encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def foreman_api_base() -> str:
    return env("FOREMAN_PUBLIC_URL").rstrip("/") + "/api"


def foreman_request(path: str) -> Any:
    req = Request(f"{foreman_api_base()}{path}")
    req.add_header("Accept", "application/json")
    req.add_header("Authorization", foreman_auth_header())
    with urlopen(req, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))


def normalize_mac(value: str) -> str:
    cleaned = value.strip().lower().replace("-", ":")
    if cleaned.startswith("0x"):
        cleaned = cleaned[2:]
    return cleaned


def shell_quote_single(value: str) -> str:
    return value.replace("'", "''")


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def host_params_from_record(host: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for key in ("all_parameters", "parameters"):
        values = host.get(key) or []
        if isinstance(values, list):
            for param in values:
                name = param.get("name")
                value = param.get("value")
                if name and value is not None:
                    result[str(name)] = str(value)
    return result


def fetch_host_parameters(host_id: int) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        payload = foreman_request(f"/hosts/{host_id}/parameters?per_page=200")
    except Exception:
        return result

    values = payload.get("results", payload if isinstance(payload, list) else [])
    if isinstance(values, list):
        for param in values:
            name = param.get("name")
            value = param.get("value")
            if name and value is not None:
                result[str(name)] = str(value)
    return result


@lru_cache(maxsize=1)
def fetch_common_parameters() -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        payload = foreman_request("/common_parameters?per_page=200")
    except Exception:
        return result

    values = payload.get("results", payload if isinstance(payload, list) else [])
    if isinstance(values, list):
        for param in values:
            name = param.get("name")
            value = param.get("value")
            if name and value is not None:
                result[str(name)] = str(value)
    return result


def lookup_host(mac: str) -> dict[str, Any] | None:
    normalized = normalize_mac(mac)
    if not normalized:
        return None

    searches = [
        f'mac="{normalized}"',
        f'mac={normalized}',
    ]
    for search in searches:
        try:
            payload = foreman_request(f"/hosts?search={quote(search)}&per_page=20")
        except Exception:
            continue
        results = payload.get("results") or []
        if results:
            host = results[0]
            params = fetch_common_parameters().copy()
            params.update(host_params_from_record(host))
            if "id" in host:
                params.update(fetch_host_parameters(int(host["id"])))
            host["_resolved_params"] = params
            return host
    return None


def host_parameter(host: dict[str, Any], key: str, default: str = "") -> str:
    params = host.get("_resolved_params", {})
    if key in params:
        return params[key]
    return default


def default_ubuntu_hostname(host: dict[str, Any]) -> str:
    name = str(host.get("name") or host.get("certname") or "ubuntu-client")
    return name.split(".", 1)[0]


def default_windows_hostname(host: dict[str, Any]) -> str:
    name = str(host.get("name") or "WIN11")
    short = name.split(".", 1)[0]
    cleaned = "".join(ch for ch in short if ch.isalnum() or ch == "-")
    return cleaned[:15] or "WIN11"


def host_provision_method(host: dict[str, Any]) -> str:
    explicit = host_parameter(host, "provision_method", "").strip().lower()
    if explicit:
        return explicit

    explicit = host_parameter(host, "pxe_os", "").strip().lower()
    if explicit:
        if explicit in {"ubuntu", "ubuntu-24.04", "ubuntu-24.04.4", "ubuntu-desktop"}:
            return "ubuntu"
        if explicit in {"windows", "windows11", "windows-11"}:
            return "windows"

    os_name = str(host.get("operatingsystem_name") or "").lower()
    if "windows" in os_name:
        return "windows"
    if "ubuntu" in os_name:
        return "ubuntu"

    return "ubuntu"


def merged_ubuntu_packages(host: dict[str, Any]) -> list[str]:
    packages = list(read_package_file(env("UBUNTU_PACKAGES_FILE", "/config/ubuntu-packages.txt")))
    host_value = host_parameter(host, "ubuntu_packages", "").strip()
    if host_value:
        for raw in host_value.replace(",", "\n").splitlines():
            item = raw.strip()
            if item:
                packages.append(item)
    deduped = []
    seen = set()
    for item in packages:
        if item not in seen:
            deduped.append(item)
            seen.add(item)
    return deduped


def merged_windows_packages(host: dict[str, Any]) -> list[str]:
    packages = list(read_package_file(env("WINDOWS_WINGET_FILE", "/config/windows-winget-packages.txt")))
    host_value = host_parameter(host, "windows_winget_packages", "").strip()
    if host_value:
        for raw in host_value.replace(",", "\n").splitlines():
            item = raw.strip()
            if item:
                packages.append(item)
    deduped = []
    seen = set()
    for item in packages:
        if item not in seen:
            deduped.append(item)
            seen.add(item)
    return deduped


def ubuntu_password_hash(password: str) -> str:
    salt = "$6$" + secrets.token_hex(8)
    return crypt.crypt(password, salt)


def ubuntu_user_data(host: dict[str, Any]) -> str:
    username = host_parameter(host, "ubuntu_autoinstall_username", env("UBUNTU_AUTOINSTALL_USERNAME", "admin"))
    password = host_parameter(host, "ubuntu_autoinstall_password", env("UBUNTU_AUTOINSTALL_PASSWORD", "admin"))
    realname = host_parameter(host, "ubuntu_autoinstall_realname", env("UBUNTU_AUTOINSTALL_REALNAME", "Ubuntu Admin"))
    hostname = host_parameter(host, "ubuntu_autoinstall_hostname", default_ubuntu_hostname(host))
    locale = host_parameter(host, "ubuntu_autoinstall_locale", env("UBUNTU_AUTOINSTALL_LOCALE", "en_GB.UTF-8"))
    keyboard = host_parameter(host, "ubuntu_autoinstall_keyboard", env("UBUNTU_AUTOINSTALL_KEYBOARD", "gb"))
    timezone = host_parameter(host, "ubuntu_autoinstall_timezone", env("UBUNTU_AUTOINSTALL_TIMEZONE", "Etc/UTC"))
    packages = merged_ubuntu_packages(host)
    package_block = "\n".join(f"      - {item}" for item in packages) or "      []"

    return "\n".join(
        [
            "#cloud-config",
            "autoinstall:",
            "  version: 1",
            f"  locale: {locale}",
            "  keyboard:",
            f"    layout: {keyboard}",
            f"  timezone: {timezone}",
            "  identity:",
            f"    hostname: {hostname}",
            f"    realname: {yaml_quote(realname)}",
            f"    username: {username}",
            f'    password: "{ubuntu_password_hash(password)}"',
            "  ssh:",
            "    install-server: true",
            "    allow-pw: true",
            "  storage:",
            "    layout:",
            "      name: direct",
            "  packages:",
            package_block,
            "  late-commands:",
            "    - curtin in-target --target=/target systemctl enable ssh || true",
        ]
    ) + "\n"


def ubuntu_meta_data(host: dict[str, Any]) -> str:
    hostname = host_parameter(host, "ubuntu_autoinstall_hostname", default_ubuntu_hostname(host))
    return f"instance-id: host-{host.get('id', 'unknown')}\nlocal-hostname: {hostname}\n"


def windows_install_language(host: dict[str, Any]) -> str:
    return host_parameter(host, "windows_locale", env("WINDOWS_LOCALE", "en-GB"))


def windows_image_name(host: dict[str, Any]) -> str:
    return host_parameter(host, "windows_image_name", env("WINDOWS_IMAGE_NAME", "Windows 11 Pro"))


def detect_windows_image(image_name: str) -> tuple[str, str]:
    metadata_path = Path(env("WINDOWS_WIM_XML_PATH", "/media/windows/11/sources/install.wim.xml"))
    if metadata_path.exists():
        import xml.etree.ElementTree as ET

        root = ET.fromstring(metadata_path.read_text(encoding="utf-8"))
        images = [(img.findtext("NAME", ""), img.attrib.get("INDEX", "")) for img in root.findall("IMAGE")]
    else:
        images = [(image_name, "6")]

    target = image_name.strip().lower()
    for name, index in images:
        if name.strip().lower() == target:
            return name, index
    for name, index in images:
        if target in name.strip().lower():
            return name, index
    for name, index in images:
        if name.strip().lower() == "windows 11 pro":
            return name, index
    return images[0] if images else (image_name, "6")


def windows_first_logon_script(host: dict[str, Any]) -> str:
    packages = merged_windows_packages(host)
    commands = [
        "$ErrorActionPreference = 'Continue'",
        "Start-Transcript -Path 'C:\\Windows\\Temp\\Foreman-FirstLogon.log' -Append",
    ]
    if packages:
        commands.append("if (Get-Command winget -ErrorAction SilentlyContinue) {")
        for item in packages:
            commands.append(
                f"  winget install --id '{shell_quote_single(item)}' --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
            )
        commands.append("} else {")
        commands.append('  Write-Warning "winget is not available; skipping package installation."')
        commands.append("}")
    else:
        commands.append('Write-Host "No additional winget packages requested."')

    extra = host_parameter(host, "windows_postinstall_ps1", "").strip()
    if not extra:
        extra = read_text_file(env("WINDOWS_POSTINSTALL_FILE", "/config/windows-postinstall.ps1"))
    if extra:
        commands.append(extra)

    commands.append("Stop-Transcript")
    return "\n".join(commands) + "\n"


def windows_unattend(host: dict[str, Any]) -> str:
    locale = xml_escape(windows_install_language(host), {'"': "&quot;"})
    admin_user = xml_escape(
        host_parameter(host, "windows_local_admin_user", env("WINDOWS_LOCAL_ADMIN_USER", "admin")),
        {'"': "&quot;"},
    )
    admin_password = xml_escape(
        host_parameter(host, "windows_local_admin_password", env("WINDOWS_LOCAL_ADMIN_PASSWORD", "admin")),
        {'"': "&quot;"},
    )
    computer_name = xml_escape(
        host_parameter(host, "windows_computer_name", default_windows_hostname(host)),
        {'"': "&quot;"},
    )
    target_disk = host_parameter(host, "windows_target_disk", env("WINDOWS_TARGET_DISK", "0"))
    image_name, image_index = detect_windows_image(windows_image_name(host))
    proxy_url = env("FOREMAN_PROXY_URL").rstrip("/")
    first_logon_url = f"{proxy_url}/autoinstall/windows/{host['id']}/FirstLogon.ps1"

    return textwrap.dedent(
        f"""\
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <SetupUILanguage>
                <UILanguage>{locale}</UILanguage>
              </SetupUILanguage>
              <InputLocale>{locale}</InputLocale>
              <SystemLocale>{locale}</SystemLocale>
              <UILanguage>{locale}</UILanguage>
              <UserLocale>{locale}</UserLocale>
            </component>
            <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <DynamicUpdate>
                <Enable>false</Enable>
              </DynamicUpdate>
              <DiskConfiguration>
                <Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <DiskID>{target_disk}</DiskID>
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
                      <Value>{image_index}</Value>
                    </MetaData>
                  </InstallFrom>
                  <InstallTo>
                    <DiskID>{target_disk}</DiskID>
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
              <ComputerName>{computer_name}</ComputerName>
              <TimeZone>GMT Standard Time</TimeZone>
            </component>
          </settings>
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <InputLocale>{locale}</InputLocale>
              <SystemLocale>{locale}</SystemLocale>
              <UILanguage>{locale}</UILanguage>
              <UserLocale>{locale}</UserLocale>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>{admin_user}</Username>
                <Password>
                  <Value>{admin_password}</Value>
                  <PlainText>true</PlainText>
                </Password>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <Order>1</Order>
                  <Description>Foreman PXE first logon</Description>
                  <CommandLine>powershell.exe -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing '{first_logon_url}' -OutFile 'C:\\Windows\\Temp\\Foreman-FirstLogon.ps1'; powershell.exe -ExecutionPolicy Bypass -File 'C:\\Windows\\Temp\\Foreman-FirstLogon.ps1'"</CommandLine>
                </SynchronousCommand>
              </FirstLogonCommands>
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <AdministratorPassword>
                  <Value>{admin_password}</Value>
                  <PlainText>true</PlainText>
                </AdministratorPassword>
                <LocalAccounts>
                  <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                    <Name>{admin_user}</Name>
                    <Group>Administrators</Group>
                    <DisplayName>{admin_user}</DisplayName>
                    <Password>
                      <Value>{admin_password}</Value>
                      <PlainText>true</PlainText>
                    </Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <RegisteredOwner>{admin_user}</RegisteredOwner>
              <RegisteredOrganization>Foreman PXE</RegisteredOrganization>
            </component>
          </settings>
          <cpi:offlineImage cpi:source="wim://sources/install.wim#{xml_escape(image_name, {'"': '&quot;'})}" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
        </unattend>
        """
    )


def fallback_ipxe(reason: str) -> str:
    base = env("PROXY_HTTP_URL").rstrip("/")
    return textwrap.dedent(
        f"""\
        #!ipxe
        menu Foreman PXE Menu
        item local Local disk boot
        item ubuntu Ubuntu 24.04.4 Desktop Live Installer
        item windows Windows 11 Installer
        item shell iPXE shell
        choose target && goto ${{target}}

        :local
        sanboot --no-describe --drive 0x80 || goto failed

        :ubuntu
        kernel {base}/ubuntu/24.04.4/casper/vmlinuz ip=dhcp url={base}/ubuntu/24.04.4/ubuntu-24.04.4-desktop-amd64.iso autoinstall ds=nocloud-net\\;s={base}/autoinstall/ubuntu/
        initrd {base}/ubuntu/24.04.4/casper/initrd
        boot

        :windows
        kernel {base}/boot/wimboot
        initrd {base}/windows/11/bootmgr bootmgr
        initrd {base}/windows/11/boot/bcd BCD
        initrd {base}/windows/11/boot/boot.sdi boot.sdi
        initrd {base}/windows/11/sources/boot.wim boot.wim
        initrd {base}/autoinstall/windows/Autounattend.xml Autounattend.xml
        boot

        :shell
        shell

        :failed
        echo {reason}
        sleep 5
        shell
        """
    )


def host_boot_script(host: dict[str, Any]) -> str:
    method = host_provision_method(host)
    proxy_url = env("FOREMAN_PROXY_URL").rstrip("/")
    media_url = env("PROXY_HTTP_URL").rstrip("/")
    host_id = host["id"]

    if method.startswith("windows"):
        return textwrap.dedent(
            f"""\
            #!ipxe
            echo Foreman build host: {host.get('name', host_id)} (windows)
            kernel {media_url}/boot/wimboot
            initrd {media_url}/windows/11/bootmgr bootmgr
            initrd {media_url}/windows/11/boot/bcd BCD
            initrd {media_url}/windows/11/boot/boot.sdi boot.sdi
            initrd {media_url}/windows/11/sources/boot.wim boot.wim
            initrd {proxy_url}/autoinstall/windows/{host_id}/Autounattend.xml Autounattend.xml
            boot
            """
        )

    return textwrap.dedent(
        f"""\
        #!ipxe
        echo Foreman build host: {host.get('name', host_id)} (ubuntu)
        kernel {media_url}/ubuntu/24.04.4/casper/vmlinuz ip=dhcp url={media_url}/ubuntu/24.04.4/ubuntu-24.04.4-desktop-amd64.iso autoinstall ds=nocloud-net\\;s={proxy_url}/autoinstall/ubuntu/{host_id}/
        initrd {media_url}/ubuntu/24.04.4/casper/initrd
        boot
        """
    )


def text_response(body: str, status: int = 200, content_type: str = "text/plain; charset=utf-8") -> Response:
    return Response(body, status=status, content_type=content_type)


def features() -> list[str]:
    names = ["tftp", "httpboot"]
    if env("PROXY_DHCP_MODE", "managed") in {"managed", "external"}:
        names.append("dhcp")
    return names


def feature_map() -> dict[str, dict[str, Any]]:
    result = {}
    for name in features():
        settings: dict[str, Any] = {}
        if name == "httpboot":
            settings = {"http_port": 8081}
        result[name] = {
            "capabilities": [],
            "settings": settings,
            "state": "running",
        }
    return result


@app.get("/")
def root() -> Response:
    return jsonify({"service": "custom-smart-proxy-api", "status": "ok"})


@app.get("/version")
def version() -> Response:
    return jsonify({"version": "3.18-custom"})


@app.get("/features")
def feature_list_v1() -> Response:
    return jsonify(features())


@app.get("/v2/features")
def feature_list_v2() -> Response:
    return jsonify(feature_map())


@app.get("/boot.ipxe")
def boot_ipxe() -> Response:
    mac = request.args.get("mac", "")
    host = lookup_host(mac) if mac else None
    if host is None:
        return text_response(fallback_ipxe("No Foreman host matched this PXE client."))
    if not bool(host.get("build")):
        return text_response(fallback_ipxe(f"Foreman host {host.get('name', host['id'])} is not in build mode."))
    return text_response(host_boot_script(host))


@app.get("/autoinstall/ubuntu/<int:host_id>/user-data")
def ubuntu_user_data_route(host_id: int) -> Response:
    host = foreman_request(f"/hosts/{host_id}")
    host["_resolved_params"] = fetch_common_parameters().copy()
    host["_resolved_params"].update(host_params_from_record(host))
    host["_resolved_params"].update(fetch_host_parameters(host_id))
    return text_response(ubuntu_user_data(host), content_type="text/yaml; charset=utf-8")


@app.get("/autoinstall/ubuntu/<int:host_id>/meta-data")
def ubuntu_meta_data_route(host_id: int) -> Response:
    host = foreman_request(f"/hosts/{host_id}")
    host["_resolved_params"] = fetch_common_parameters().copy()
    host["_resolved_params"].update(host_params_from_record(host))
    host["_resolved_params"].update(fetch_host_parameters(host_id))
    return text_response(ubuntu_meta_data(host))


@app.get("/autoinstall/windows/<int:host_id>/Autounattend.xml")
def windows_autounattend_route(host_id: int) -> Response:
    host = foreman_request(f"/hosts/{host_id}")
    host["_resolved_params"] = fetch_common_parameters().copy()
    host["_resolved_params"].update(host_params_from_record(host))
    host["_resolved_params"].update(fetch_host_parameters(host_id))
    return text_response(windows_unattend(host), content_type="application/xml; charset=utf-8")


@app.get("/autoinstall/windows/<int:host_id>/FirstLogon.ps1")
def windows_first_logon_route(host_id: int) -> Response:
    host = foreman_request(f"/hosts/{host_id}")
    host["_resolved_params"] = fetch_common_parameters().copy()
    host["_resolved_params"].update(host_params_from_record(host))
    host["_resolved_params"].update(fetch_host_parameters(host_id))
    return text_response(
        windows_first_logon_script(host),
        content_type="text/plain; charset=utf-8",
    )


@app.errorhandler(HTTPError)
@app.errorhandler(URLError)
def http_error_handler(err: Exception) -> Response:
    return jsonify({"error": str(err)}), 502


@app.errorhandler(Exception)
def generic_error_handler(err: Exception) -> Response:
    return jsonify({"error": str(err)}), 500

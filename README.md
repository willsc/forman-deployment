# Foreman PXE Stack

This repository deploys:

- a Foreman application stack with Docker Compose, using the official `quay.io/foreman/foreman:3.18` app image
- a separate PXE service stack with Docker Compose, using custom `dnsmasq`, `tftp`, `nginx` HTTP boot, and a lightweight proxy feature API

This is a custom containerized design. It avoids running `foreman-installer` inside containers.

## Modes

- `managed`: `dnsmasq` provides DHCP leases and PXE boot options.
- `external`: `dnsmasq` runs in proxy-DHCP mode so an existing DHCP server keeps leasing addresses while PXE boot options still come from this stack.

## Media

- Ubuntu 24.04.4 Desktop ISO is downloaded automatically from the canonical Ubuntu URL.
- Windows 11 ISO can be derived from Microsoft’s workflow page, but for deterministic runs you should set `WINDOWS_11_ISO_URL` to a direct temporary Microsoft ISO link.
- Both Ubuntu and Windows media are rendered with unattended installation assets during `scripts/prepare-media.sh`.
- Foreman `Build` mode now controls whether a PXE client is provisioned or falls back to local boot.

## How It Works

- Foreman runs as a Rails app container backed by PostgreSQL.
- PXE clients get `undionly.kpxe` or `ipxe.efi` over TFTP.
- `dnsmasq` detects second-stage iPXE clients and chains them to `http://<next-server>:8081/boot/menu.ipxe`.
- Ubuntu and Windows 11 installer assets are served over HTTP from the `httpboot` container.
- Ubuntu uses cloud-init `autoinstall` data served from `media/autoinstall/ubuntu/`.
- Windows uses `Autounattend.xml` injected at WinPE boot plus `$OEM$` setup scripts copied from the extracted ISO tree.
- A small proxy API service on port `9090` exposes proxy features so Foreman can register the PXE stack through its REST API.
- The PXE entrypoint now chains to a Foreman-aware iPXE endpoint that looks up the booting host by MAC address, checks its `Build` flag in Foreman, and renders host-specific unattended data.

## Quick Start

```bash
cd /opt/foreman
bash scripts/deploy.sh
```

Interactive runs prompt:

- `Is there already a DHCP server on this LAN? [y/N]`
- `No` selects `managed`
- `Yes` selects `external`

For external DHCP coexistence:

```bash
cd /opt/foreman
PROXY_DHCP_MODE=external bash scripts/deploy.sh
```

## Important Variables

- `PROXY_DHCP_MODE`: `managed` when this stack should serve DHCP, `external` when another DHCP server already exists on the LAN. Interactive deploys will prompt for this unless you set it explicitly.
- `FOREMAN_PUBLIC_URL`: the URL used by the deployment scripts to call the Foreman API.
- `FOREMAN_PROXY_URL`: the URL used by Foreman to register the custom PXE proxy API.
- `PROXY_HTTP_URL`: the URL served to PXE/iPXE clients for boot menus and installer assets.
- `PXE_NEXT_SERVER`: the IP address PXE clients use for TFTP and HTTP boot.
- `WINDOWS_11_ISO_URL`: direct Microsoft ISO URL override.
- `UBUNTU_AUTOINSTALL_*`: default identity, hostname, locale, keyboard, and timezone used for Ubuntu unattended installs.
- `WINDOWS_IMAGE_NAME`: Windows edition selected from `sources/install.wim`. Defaults to `Windows 11 Pro`.
- `WINDOWS_LOCAL_ADMIN_USER` and `WINDOWS_LOCAL_ADMIN_PASSWORD`: local administrator created by Windows unattended setup.
- `WINDOWS_COMPUTER_NAME`: default hostname pattern used by Windows unattended setup.
- `WINDOWS_LOCALE`: locale used by Windows setup and OOBE.
- `WINDOWS_TARGET_DISK`: disk id wiped and repartitioned for the unattended Windows install. Default is `0`.

## Package Hooks

User-editable package and post-install hooks live in `config/`:

- [ubuntu-packages.txt](/opt/foreman/config/ubuntu-packages.txt): packages injected into Ubuntu autoinstall.
- [windows-winget-packages.txt](/opt/foreman/config/windows-winget-packages.txt): winget package ids installed after Windows setup completes.
- [windows-postinstall.ps1](/opt/foreman/config/windows-postinstall.ps1): arbitrary PowerShell commands run after Windows setup completes.

These files are rendered into:

- `media/autoinstall/ubuntu/user-data`
- `media/autoinstall/windows/Autounattend.xml`
- `media/windows/11/sources/$OEM$/$$/Setup/Scripts/*`

## Foreman-Driven Host Builds

To provision a host from Foreman instead of using the generic menu:

1. Create the host in Foreman with the correct MAC address on the PXE subnet.
2. Set the host `Build` flag to enabled.
3. Set or override Foreman parameters on the host or hostgroup.
4. Boot the machine from PXE.

When the machine boots, the proxy bridge queries Foreman by MAC address:

- if `Build` is `false`, the client falls back to local boot
- if `Build` is `true`, the bridge selects the provisioning path from Foreman parameters and serves host-specific unattended content

Primary Foreman parameters:

- `provision_method`: `ubuntu` or `windows`
- `ubuntu_autoinstall_username`
- `ubuntu_autoinstall_password`
- `ubuntu_autoinstall_realname`
- `ubuntu_autoinstall_hostname`
- `ubuntu_autoinstall_locale`
- `ubuntu_autoinstall_keyboard`
- `ubuntu_autoinstall_timezone`
- `ubuntu_packages`: newline-separated package list appended to the global Ubuntu package file
- `windows_image_name`: for example `Windows 11 Pro`
- `windows_local_admin_user`
- `windows_local_admin_password`
- `windows_computer_name`
- `windows_locale`
- `windows_target_disk`
- `windows_winget_packages`: newline-separated winget package ids appended to the global Windows package list
- `windows_postinstall_ps1`: additional PowerShell run at first logon

The deployment registers these as Foreman common parameters so they are available immediately in the UI and can be overridden per host.

## Layout

- `foreman/`: Foreman app stack and wrapper image around the official Foreman 3.18 app image.
- `smart-proxy/`: custom PXE stack with `dnsmasq`, `tftp`, `httpboot`, and proxy feature API services.
- `scripts/`: environment bootstrap, media download, media preparation, deployment, and Foreman API configuration.
- `media/`: extracted Ubuntu and Windows installer media plus HTTP boot assets.
- `logs/`: timestamped deployment logs.

## Logging

Deployment output is written to:

- `logs/deploy-YYYYMMDD-HHMMSS.log`

## Rebuild

To rebuild both stacks manually:

```bash
docker compose --env-file .env -f foreman/docker-compose.yml up -d --build --force-recreate
docker compose --env-file .env -f smart-proxy/docker-compose.yml up -d --build --force-recreate
```

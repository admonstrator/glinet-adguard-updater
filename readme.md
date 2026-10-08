<div align="center">

<img src="images/robbenlogo-glinet-small.webp" width="300" alt="GL.iNet AdGuard Home Logo" style="border-radius: 10px; margin: 20px 0;">

## AdGuard Home Updater for GL.iNet Routers

**Keep AdGuard Home up-to-date on your GL.iNet router with ease!**

[![Latest Release](https://img.shields.io/github/v/release/Admonstrator/glinet-adguard-updater?style=for-the-badge&logo=github&color=blue)](https://github.com/Admonstrator/glinet-adguard-updater/releases/latest) [![License](https://img.shields.io/github/license/Admonstrator/glinet-adguard-updater?style=for-the-badge)](LICENSE) [![Stars](https://img.shields.io/github/stars/Admonstrator/glinet-adguard-updater?style=for-the-badge)](https://github.com/Admonstrator/glinet-adguard-updater/stargazers)

---

## 💖 Support the Project

If you find this tool helpful, consider supporting its development:

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?style=for-the-badge&logo=github)](https://github.com/sponsors/admonstrator) [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/admon) [![Ko-fi](https://img.shields.io/badge/Ko--fi-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/admon) [![PayPal](https://img.shields.io/badge/PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/aaronviehl)

</div>

---

## 📖 About

This script automatically fetches and installs the latest AdGuard Home version, optimized specifically for GL.iNet routers. Keep your AdGuard Home installation current with just one command!

Created by [Admon](https://forum.gl-inet.com/u/admon/) for the GL.iNet community. Tested on nearly all GL.iNet routers with firmware 4.x.

> 🎖️ **Community Maintained** – Part of the [GL.iNet Toolbox](https://github.com/Admonstrator/glinet-toolbox) project
> ⚠️ **Independent Project** – Not officially affiliated with GL.iNet or AdGuard

---

## ✨ Features

- 🚀 **Automatic Updates** – Fetches and installs the latest AdGuard Home version
- 📦 **Tiny Version Support** – Uses pre-compressed binaries optimized for GL.iNet routers (6 MB vs 32 MB)
- 🎯 **Version Selection** – Install specific AdGuard Home versions
- 🧪 **Testing Channel** – Optionally install pre-compressed AdGuard Home betas
- 💾 **Query Logging Control** – Optionally enable query logging to file
- 🌐 **DNS Routing Control** – Optionally send upstream DNS queries via WAN only, bypassing an active VPN
- 🔄 **Persistence Support** – Make installations survive firmware upgrades
- 🛡️ **Safe Backups** – Automatic backup of your configuration before every change
- ↩️ **Restore** – Go back to the AdGuard Home version that shipped with your firmware
- ⚡ **Flexible Options** – Multiple flags for customized installations

---

## 📋 Requirements

| Requirement | Details |
|------------|---------|
| **Router** | GL.iNet router with firmware 4.x (including MT-6000 Flint 2 and GL-BE9300 Flint 3) |
| **Free Space** | At least 15 MB (can be bypassed with `--ignore-free-space`) |
| **AdGuard Home** | Pre-installed via GL.iNet firmware (deeply integrated) |

---

## 🚀 Quick Start

Run the updater without cloning the repository:

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh
```

> ⚠️ **Important:** Do not run this script as a cron job! Manual execution is recommended.

---

## 🎛️ Arguments

The `update-adguardhome.sh` script supports the following arguments:

| Argument | Description |
|----------|-------------|
| `--ignore-free-space` | Bypasses the free space check and disables backup creation. Use with caution on low-storage devices! ⚠️ Not recommended - could break your router if there's insufficient space! |
| `--select-release` | Displays available stable releases and lets you choose a specific version to install. |
| `--testing` | Installs the latest AdGuard Home **prerelease** (beta). ⚠️ Beta software - it can take DNS down for your whole network. |
| `--restore` | Restores the AdGuard Home version that shipped with your firmware and removes the persistence entries of this script. |
| `--force` | Answers every prompt automatically. Ideal for unattended runs. |
| `--force-upgrade` | Installs even if that version is already installed. Useful for reinstalling the same version. |
| `--log` | Shows timestamps in all log messages. Useful for debugging. |
| `--help` | Displays the help message with all available arguments. |

---

## 📚 Usage Examples

### Standard Update

Update to the latest stable release:

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh
```

### Select a Specific Version

Install a specific AdGuard Home version:

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh --select-release
```

The script will display available releases for you to choose from.

### Testing Versions

Install the latest AdGuard Home prerelease:

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh --testing
```

> **⚠️ Warning:** Beta software. A broken AdGuard Home takes DNS down for your whole network. So far the betas have only been tested on the GL.iNet Flint 4 (GL-BE14000), but a build is provided for every supported architecture.

To go back, run the script without any flag - it always installs the latest stable version - or use `--restore` for the version that shipped with your firmware.

### Restore the Firmware Version

Return to the AdGuard Home version that came with your firmware:

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh --restore
```

### Unattended Updates

Run without any prompts:

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh --force
```

> **ℹ️ Note:** `--force` keeps the query log in RAM, leaves the DNS routing as it is and makes the installation permanent.

### Low Storage Devices

For devices with limited free space (⚠️ use with caution):

```bash
wget -q https://app.gl-i.net/adguard -O update-adguardhome.sh && sh update-adguardhome.sh --ignore-free-space
```

> **⚠️ Warning:** This disables safety checks and backup creation. Could potentially break your router if there's not enough free space!

---

## 🔍 Key Features Explained

### 📦 Tiny-AdGuardHome

By default, the script uses pre-compressed AdGuard Home binaries that:
- 🔹 Save significant storage space (6 MB vs 32 MB)
- 🔹 Are optimized specifically for GL.iNet routers
- 🔹 Maintain full functionality
- 🔹 Are recommended for all GL.iNet devices

### 💾 Query Logging

By default, AdGuard Home on GL.iNet routers disables query logging to file to:
- 🔹 Prevent running out of storage space
- 🔹 Prevent flash memory wear
- 🔹 Optimize performance

The script will ask if you want to enable query logging after the update.

#### Manual Query Logging Control

**Enable query logging to file:**

```bash
sed -i '/^querylog:/,/^[^ ]/ s/^  file_enabled: .*/  file_enabled: true/' /etc/AdGuardHome/config.yaml
/etc/init.d/adguardhome restart
```

**Disable query logging to file:**

```bash
sed -i '/^querylog:/,/^[^ ]/ s/^  file_enabled: .*/  file_enabled: false/' /etc/AdGuardHome/config.yaml
/etc/init.d/adguardhome restart
```

### 🌐 Upstream DNS via WAN Only

By default, AdGuard Home sends its upstream DNS queries through the VPN when a tunnel is active. If the VPN tunnel cannot reach the upstream DNS servers configured in AdGuard Home, DNS resolution will fail.

The script will ask if you want AdGuard Home to send its upstream DNS queries via WAN only. If this is already active, it will ask if you want to restore the default instead. When you make the installation persistent, the setting is re-applied after a firmware upgrade.

> ⚠️ **Note:** With this option enabled, upstream DNS queries bypass the VPN tunnel.

#### Manual DNS Routing Control

**Send upstream DNS queries via WAN only:**

```bash
sed -i 's/explict_vpn/nonevpn/g' /etc/init.d/adguardhome
/etc/init.d/adguardhome restart
```

**Restore default (upstream DNS through VPN):**

```bash
cp /rom/etc/init.d/adguardhome /etc/init.d/adguardhome
/etc/init.d/adguardhome restart
```

> 💡 Restoring the stock init script also removes the multipath TCP fix. To re-apply it, run this before the restart:
>
> ```bash
> sed -i '/procd_set_param stderr 1/a\    procd_set_param env GODEBUG=multipathtcp=0' /etc/init.d/adguardhome
> ```

### 🧪 Testing Channel

Upstream publishes AdGuard Home betas as GitHub prereleases. This project builds them exactly like the stable versions - same architectures, same UPX compression, same checksums - and publishes them as a rolling **prerelease** in this repository.

Because GitHub excludes prereleases from "latest", a beta never reaches the normal update path: a plain run of the script, the `--select-release` menu and the version badge above only ever see stable releases. You get a beta only by asking for it with `--testing`.

```bash
sh update-adguardhome.sh --testing
```

Your configuration is backed up to `/root/AdGuardHome_config_backup/` before anything is changed. If the new binary does not start, the script puts the previous one back automatically.

> ⚠️ **Note:** AdGuard Home does not officially support downgrades. If it refuses to start after you go back from a beta, remove the configuration: `rm -rf /etc/AdGuardHome && /etc/init.d/adguardhome restart`

### ↩️ Restore

`--restore` brings back the AdGuard Home binary and init script that shipped with your firmware (from `/rom`), removes the persistence entries this script added and keeps your configuration. A config backup is created first.

```bash
sh update-adguardhome.sh --restore
```

### 🔄 Persistence Support

The script offers to make the installation persistent across firmware upgrades by:
- ✅ Adding necessary files to `/etc/sysupgrade.conf`
- ✅ Setting up automatic update checks via `/etc/rc.local`
- ✅ Preserving your AdGuard Home configuration and settings

> ⚠️ **Important:** Factory reset will NOT revert persistent installations!

---

## 🔙 Reverting Changes

The script can do this for you: `sh update-adguardhome.sh --restore` restores the firmware version of AdGuard Home and removes the persistence entries. The manual steps below are for the cases it cannot cover - for example if `/rom` is not available on your device.

Since AdGuard Home is deeply integrated into GL.iNet firmware, reverting changes manually requires several steps. Factory reset will **NOT** revert changes if you made the installation persistent!

### Manual Revert Steps

1. Remove the update check script from startup:
   ```bash
   sed -i '/enable-adguardhome-update-check/d' /etc/rc.local
   ```

2. Remove the update check script:
   ```bash
   rm /usr/bin/enable-adguardhome-update-check
   ```

3. Remove persistence entries from `/etc/sysupgrade.conf`:
   - `/root/AdGuardHome_backup.tar.gz`
   - `/etc/AdGuardHome`
   - `/usr/bin/AdGuardHome`
   - `/usr/bin/enable-adguardhome-update-check`
   - `/etc/rc.local`

4. Stop AdGuard Home:
   ```bash
   /etc/init.d/adguardhome stop
   ```

5. ⚠️ **Reset configuration (removes all settings and blocklists!):**
   ```bash
   rm -rf /etc/AdGuardHome
   ```

6. Start AdGuard Home:
   ```bash
   /etc/init.d/adguardhome start
   ```

### Restore from Backup

Configuration backups are located in `/root/AdGuardHome_config_backup/`, one timestamped archive per run. Older versions of this script wrote a single `/root/AdGuardHome_backup.tar.gz` instead.

Restore one of them with:

```bash
/etc/init.d/adguardhome stop
tar xzf /root/AdGuardHome_config_backup/<timestamp>.tar.gz -C /etc
/etc/init.d/adguardhome start
```

If issues persist after manual revert, you can restore AdGuard Home to its original state by re-flashing the firmware.

---

## 💡 Getting Help

Need assistance or have questions?

- 💬 [Join the discussion on GL.iNet Forum](https://forum.gl-inet.com/t/script-update-adguard-home/39398) – Community support
- 💬 [Join GL.iNet Discord](https://link.gl-inet.com/website-discord-support) – Real-time chat
- 🐛 [Report issues on GitHub](https://github.com/Admonstrator/glinet-adguard-updater/issues) – Bug reports and feature requests
- 📧 Contact via forum private message – For private inquiries

---

## ⚠️ Disclaimer

This script is provided **as-is** without any warranty. Use it at your own risk.

It may potentially:
- 🔥 Break your router, computer, or network
- 🔥 Cause unexpected system behavior
- 🔥 Even burn down your house (okay, probably not, but you get the idea)

**You have been warned!**

Always read the documentation carefully and understand what a script does before running it.

---

## 👥 Contributors

Special thanks to:

- All the testers and feedback providers in the GL.iNet forum!
- Copilot – Yeah, I am using AI to help write code. But I review and test everything thoroughly!

Want to contribute? Pull requests are welcome!

---

## 📜 License

This project is licensed under the **MIT License** – see the [LICENSE](LICENSE) file for details.

---

<div align="center">

## 🧰 Part of the GL.iNet Toolbox

This project is part of a comprehensive collection of tools for GL.iNet routers.

**Explore more tools and utilities:**

[![GL.iNet Toolbox](https://img.shields.io/badge/🧰_GL.iNet_Toolbox-Explore_All_Tools-blue?style=for-the-badge)](https://github.com/Admonstrator/glinet-toolbox)

*Discover Tailscale Updater, ACME Certificate Manager, and more community-driven projects!*

</div>

---

<div align="center">

**Made with ❤️ by [Admon](https://github.com/Admonstrator) for the GL.iNet Community**

⭐ If you find this useful, please star the repository!

</div>

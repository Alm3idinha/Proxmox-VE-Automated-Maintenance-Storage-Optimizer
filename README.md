# Proxmox VE Automated Maintenance & Storage Optimizer 🚀

An enterprise-grade Bash automation script designed for Proxmox VE hosts to perform deep, safe storage cleanup, resource auditing, and automated power-state management across all LXC Containers and Virtual Machines.

---

## ✨ Key Features

* **Smart Power State Management:** Automatically detects whether a CT or VM is running or stopped. It temporarily powers on offline machines, executes the routine, and safely powers them back off.
* **Deep & Safe Cleanup Pipeline:**
  * **APT Package Cache:** Cleans downloaded package archives (`apt-get clean`).
  * **Orphaned Dependencies:** Purges unneeded packages and config residuals (`apt-get autoremove --purge`).
  * **Systemd Journal Logs:** Enforces a strict 15-day retention policy (`journalctl --vacuum-time=15d`).
  * **Temporary Files:** Erases residual debris in `/tmp` and `/var/tmp`.
  * **Docker Prune:** Automatically targets nodes running Docker, cleaning unused containers, networks, images, and dangling volumes (`docker system prune -a --volumes`).
* **Thin Provisioning Recovery (`fstrim`):** Forces virtual disks to return unused blocks back to the physical Proxmox host storage pool.
* **Interactive Configuration Wizard:**
  * Prompt to skip specific VMs or CTs by their **IDs or Names** at runtime.
  * Prompt to automatically configure, enable, and start the `qemu-guest-agent` on VMs where it is disabled.
* **Timestamped Execution Logging:** Automatically generates an independent audit log per execution inside `/var/log/proxmox-maintenance/` (e.g., `maintenance-YYYY-MM-DD_HH-MM-SS.log`).
* **Color-Coded CLI Output:** Real-time ANSI-colored console feedback for full operational transparency.

---

## 📥 Installation & Usage

1. **SSH into your Proxmox Host** as `root`.
2. Create the script file:
   ```bash
   nano /usr/local/bin/proxmox-clean-all.sh
   ```
3. Paste the complete script code provided below, save (`Ctrl + O`, `Enter`) and exit (`Ctrl + X`).
4. Grant execution permissions:
   ```bash
   chmod +x /usr/local/bin/proxmox-clean-all.sh
   ```
5. Run the script manually:
   ```bash
   /usr/local/bin/proxmox-clean-all.sh
   ```

---

## ⏰ Automation via Cron

To schedule this script to run automatically every week (e.g., every Sunday at 3:00 AM):

1. Open the system crontab:
   ```bash
   crontab -e
   ```
2. Append the cron job line:
   ```cron
   0 3 * * 0 /usr/local/bin/proxmox-clean-all.sh
   ```
3. Save and close the editor. Each run will generate its own isolated log file in `/var/log/proxmox-maintenance/`.

---
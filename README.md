## 🐍 Medusa — VM Orchestration at Scale

<p align="center">
  <img src="https://raw.githubusercontent.com/mtors25/vms-orchestration-medusa/main/medusa-logo.png" width="500" alt="Medusa Overlord Logo"/>
</p>


**Medusa** enables large-scale VM orchestration using standard Microsoft ISO images, automating the full lifecycle from preparation to deployment with minimal manual intervention.

---

### ⚙️ Workflow Overview

Medusa follows a multi-stage process to prepare and deploy virtual machines according to your specifications:

#### 1. ISO Preparation & Payload Consolidation

* Automated using PowerShell and DCIM tooling
* Injects required configurations and payloads into the base ISO

#### 2. VM Orchestration via KubeVirt

* Shell scripts invoke KubeVirt templates to provision VM(s)
* Uses `sysprep` and `autounattend.xml` for zero-touch deployment

**Automated configuration includes:**

* Disk partitioning
* OS version selection
* Language settings
* Network configuration and hostname assignment
* Timezone and NTP setup
* Installation and configuration of:

  * QEMU Guest Agent
  * PowerShell 7
  * OpenSSH
  * Additional custom payloads
* Creation of local administrator account
* Post-install customization via PowerShell

#### 3. Finalization

* Automatic reboot after provisioning and configuration completes

---

### 🚀 Project Purpose

This project was built to simplify and streamline VM orchestration workflows in complex environments.

Feel free to use, modify, and adapt it to your needs.

---

### ⭐ Support

If you find this project useful:

* Give it a star ⭐
* Share feedback or suggestions
* Contributions are welcome

Your support helps improve the project and grow its visibility.

# Ansible — CCDC Red Team Automation

Automates the full Linux attack sequence across all target VMs in parallel.

## Files

| File | Purpose |
|------|---------|
| `inventory_2026-09-03.ini` | VM list for 2026-09-03 practice session — add your IPs here |
| `group_vars/all.yml` | Shared vars (C2 IP, implant filenames, staging path) |
| `ccdc_2026-09-03_practice.yml` | Main playbook — runs the full game plan |

## Quick Start

```bash
# 1. Install Ansible (one time)
pip install ansible

# 2. Add your VM IPs to the inventory
nano inventory_2026-09-03.ini

# 3. Test SSH connectivity
ansible -i inventory_2026-09-03.ini linux_targets -m ping

# 4. Dry run (no changes)
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml --check

# 5. Run everything against all VMs in parallel
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml
```

## Run Specific Stages Only

Tags let you run just one phase:

```bash
# Provision scored services only
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml --tags setup

# Download + plant implants only
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml --tags implants

# Run all COMBINED.sh attack modules only
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml --tags attack

# Clear history only
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml --tags cleanup
```

## Target a Single VM First

```bash
ansible-playbook -i inventory_2026-09-03.ini ccdc_2026-09-03_practice.yml --limit 192.168.x.x
```

## Verify After Running

```bash
# Check backdoor users
ansible -i inventory_2026-09-03.ini linux_targets -m shell -a "id johnredteam"

# Check rogue service is running
ansible -i inventory_2026-09-03.ini linux_targets -m shell -a "systemctl status sillyevilservice"

# Check cron job is planted
ansible -i inventory_2026-09-03.ini linux_targets -m shell -a "cat /etc/cron.d/grub-service"

# Check implant is running
ansible -i inventory_2026-09-03.ini linux_targets -m shell -a "ps aux | grep IMPLANT"
```

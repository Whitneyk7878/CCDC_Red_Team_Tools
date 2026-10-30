#!/usr/bin/env python3
"""
CCDC PAN-OS Training — Stateless Cleanup (PAN-OS 11.1.x)

Reverses all artifacts created by CCDC_PANOS_Setup_DirtyFirewall.py
WITHOUT requiring panos_exercise_state.json. Uses the hardcoded artifact
names documented in docs/panos/CCDC_PANOS_Overview.md.

Use this when the state file is unavailable (e.g. it was deleted, the
setup was run from a different machine, or you need to clean up manually).

Limitations vs. CCDC_PANOS_Cleanup.py:
  - Security profiles on rules cannot be restored (original values unknown)
  - DNS sinkhole config cannot be restored (original XML unknown)
  - Zone flood protection cannot be restored (original XML unknown)
  - Management plane permitted-IP list cannot be restored (original unknown)
  Each skipped item prints a [!] note so the instructor knows what needs
  manual attention after this script completes.
"""

import getpass
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PANOS_LIB = os.path.join(os.path.dirname(_HERE), "General_Scripts", "SetupScripts", "panos")
sys.path.insert(0, _HERE)
sys.path.insert(0, _PANOS_LIB)

from panos_lib import PanosAPI, DEVICE, VSYS
from CCDC_PANOS_Setup_DirtyFirewall import (
    ROGUE_ADMIN,
    ROGUE_SYSLOG_PROFILE,
    ROGUE_LOG_FWD,
    ROGUE_URL_PROFILE,
    ROGUE_RULE,
    ROGUE_AUTH_PROFILE,
)


def vsys(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']/vsys/entry[@name='{VSYS}']{path}"

def dev(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']{path}"

def net(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']/network{path}"

def _silent_delete(api, xpath):
    try:
        api.config_delete(xpath)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

def restore_rule_logging(api):
    """Re-enable log-end on every security rule (safe default: yes/no)."""
    rules = api.security_rules()
    for rule in rules:
        base = vsys(f"/rulebase/security/rules/entry[@name='{rule}']")
        api.config_set(f"{base}/log-end",   "<log-end>yes</log-end>")
        api.config_set(f"{base}/log-start", "<log-start>no</log-start>")
    print(f"    Re-enabled logging on {len(rules)} rules")


def remove_rogue_syslog(api):
    """Remove ExternalLogging syslog profile and log-setting from all rules."""
    # Remove log-setting from every security rule
    rules = api.security_rules()
    for rule in rules:
        _silent_delete(api, vsys(f"/rulebase/security/rules/entry[@name='{rule}']/log-setting"))
    print(f"    Removed log-setting from {len(rules)} rules")

    # Remove system-level syslog pointer if it points to our rogue profile
    try:
        result = api.config_get(dev("/deviceconfig/system/syslog"))
        if ROGUE_SYSLOG_PROFILE in (result.text or ""):
            api.config_delete(dev("/deviceconfig/system/syslog"))
            print("    Removed rogue system syslog pointer")
    except Exception:
        pass

    _silent_delete(api, vsys(f"/log-settings/profiles/entry[@name='{ROGUE_LOG_FWD}']"))
    print(f"    Deleted log forwarding profile '{ROGUE_LOG_FWD}'")

    _silent_delete(api, dev(f"/server-profile/syslog/entry[@name='{ROGUE_SYSLOG_PROFILE}']"))
    print(f"    Deleted syslog server profile '{ROGUE_SYSLOG_PROFILE}'")


def remove_url_allow_all(api):
    """Remove allow-all URL filtering profile and clear it from all rules."""
    rules = api.security_rules()
    for rule in rules:
        url_xpath = vsys(f"/rulebase/security/rules/entry[@name='{rule}']/profile-setting/profiles/url-filtering")
        try:
            result = api.config_get(url_xpath)
            if ROGUE_URL_PROFILE in (result.text or ""):
                api.config_delete(url_xpath)
        except Exception:
            pass
    print(f"    Removed rogue URL filtering from rules")

    _silent_delete(api, vsys(f"/profiles/url-filtering/entry[@name='{ROGUE_URL_PROFILE}']"))
    print(f"    Deleted URL filtering profile '{ROGUE_URL_PROFILE}'")


def skip_security_profiles(api):
    """Cannot restore original security profiles without the state file."""
    print("    [!] SKIPPED: security profile restore requires original values from state file")
    print("         Manually re-attach AV/IPS/anti-spyware profiles to each security rule")


def skip_dns_sinkholing(api):
    """Cannot restore original DNS sinkhole config without the state file."""
    print("    [!] SKIPPED: DNS sinkhole restore requires original XML from state file")
    print("         Manually re-add botnet-domains sinkhole to each anti-spyware profile")


def skip_app_id(api):
    """Cannot restore original App-ID application lists without the state file."""
    print("    [!] SKIPPED: App-ID application list restore requires original values from state file")
    print("         All rules are currently set to 'any'; manually tighten as needed")


def restore_ssl_decryption(api):
    """Re-enable all decryption rules by removing the disabled flag."""
    rules = api.decryption_rules()
    count = 0
    for rule in rules:
        xpath = vsys(f"/rulebase/decryption/rules/entry[@name='{rule}']/disabled")
        try:
            api.config_delete(xpath)
            count += 1
        except Exception:
            pass
    print(f"    Re-enabled {count} decryption rule(s)")


def remove_permissive_rule(api):
    """Delete the permit-all-traffic catch-all rule."""
    _silent_delete(api, vsys(f"/rulebase/security/rules/entry[@name='{ROGUE_RULE}']"))
    print(f"    Deleted rogue catch-all rule '{ROGUE_RULE}'")


def skip_zone_flood_protection(api):
    """Cannot restore original zone flood protection config without the state file."""
    print("    [!] SKIPPED: zone flood protection restore requires original XML from state file")
    print("         Manually re-add flood protection to each zone protection profile")


def skip_management_plane(api):
    """Cannot restore original permitted-IP list without the state file."""
    print("    [!] SKIPPED: management plane permitted-IP restore requires original values")
    print("         Manually re-add trusted management IPs to /deviceconfig/system/permitted-ip")


def remove_rogue_admin(api):
    """Delete the rogue netadmin superuser account."""
    _silent_delete(api, dev(f"/mgt-config/users/entry[@name='{ROGUE_ADMIN}']"))
    print(f"    Deleted rogue admin account '{ROGUE_ADMIN}'")


def restore_auth_profile(api):
    """Delete LocalBypass auth profile and clear the system auth-profile pointer."""
    # Remove system pointer first so it doesn't reference a deleted profile
    _silent_delete(api, dev("/deviceconfig/system/authentication-profile"))
    print("    Cleared system authentication-profile (reverts to default local auth)")

    _silent_delete(api, dev(f"/mgt-config/authentication-profile/entry[@name='{ROGUE_AUTH_PROFILE}']"))
    print(f"    Deleted rogue auth profile '{ROGUE_AUTH_PROFILE}'")


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

STEPS = [
    ("Restoring security rule logging",             restore_rule_logging),
    ("Removing rogue syslog configuration",         remove_rogue_syslog),
    ("Removing allow-all URL filtering",            remove_url_allow_all),
    ("Security profiles (stateless — skipped)",     skip_security_profiles),
    ("DNS sinkholing (stateless — skipped)",        skip_dns_sinkholing),
    ("App-ID restore (stateless — skipped)",        skip_app_id),
    ("Re-enabling SSL/TLS decryption rules",        restore_ssl_decryption),
    ("Removing permissive catch-all rule",          remove_permissive_rule),
    ("Zone flood protection (stateless — skipped)", skip_zone_flood_protection),
    ("Management plane (stateless — skipped)",      skip_management_plane),
    ("Removing rogue admin account",                remove_rogue_admin),
    ("Restoring authentication profile",            restore_auth_profile),
]


def run_stateless_cleanup(api):
    print("\n[*] Stateless cleanup — reversing known dirty-state artifacts...\n")
    for label, func in STEPS:
        print(f"[*] {label}...")
        try:
            func(api)
        except Exception as e:
            print(f"    [!] Error: {e}")

    api.commit("CCDC Training — Stateless Cleanup Complete")
    print("\n[+] Stateless cleanup complete. Committed to device.")
    print("[!] Review skipped items above — those require manual remediation.\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    host = input("Firewall IP: ").strip()
    use_key = input("Use existing API key? (y/N): ").strip().lower() == "y"
    if use_key:
        api_key = input("API key: ").strip()
        api = PanosAPI(host, api_key)
    else:
        username = input("Username: ").strip()
        password = getpass.getpass("Password: ")
        try:
            api = PanosAPI.from_credentials(host, username, password)
            print("[+] API key generated successfully.")
        except (ValueError, ConnectionError) as e:
            print(f"[!] {e}")
            api_key = input("API key: ").strip()
            api = PanosAPI(host, api_key)

    run_stateless_cleanup(api)

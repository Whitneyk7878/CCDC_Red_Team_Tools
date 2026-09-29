#!/usr/bin/env python3
"""
CCDC PAN-OS Training - Cleanup / Reset (PAN-OS 11.1.x)

Reverses all changes made by CCDC_PANOS_Setup_DirtyFirewall.py
using the saved state file. Run standalone or via CCDC_PANOS_Run.py.
"""

import getpass
import json
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(__file__))
from panos_lib import PanosAPI, DEVICE, VSYS
from CCDC_PANOS_Setup_DirtyFirewall import (
    STATE_FILE, ROGUE_ADMIN, ROGUE_SYSLOG_PROFILE, ROGUE_LOG_FWD,
    ROGUE_URL_PROFILE, ROGUE_RULE, ROGUE_AUTH_PROFILE,
)


def vsys(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']/vsys/entry[@name='{VSYS}']{path}"

def dev(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']{path}"

def net(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']/network{path}"


# ---------------------------------------------------------------------------
# Reversal functions
# ---------------------------------------------------------------------------

def restore_rule_logging(api, state):
    for rule, values in state.get("rule_logging", {}).items():
        base = vsys(f"/rulebase/security/rules/entry[@name='{rule}']")
        api.config_set(f"{base}/log-end",   f"<log-end>{values['log-end']}</log-end>")
        api.config_set(f"{base}/log-start", f"<log-start>{values['log-start']}</log-start>")
        print(f"    Restored logging on rule: {rule}")


def remove_rogue_syslog(api, state):
    # Restore system syslog setting
    orig = state.get("system_syslog", "")
    if orig:
        api.config_set(dev("/deviceconfig/system/syslog"), f"<syslog>{orig}</syslog>")
    else:
        api.config_delete(dev("/deviceconfig/system/syslog"))
    print("    Restored system syslog setting")

    # Remove rogue log-setting from security rules
    for rule, orig_setting in state.get("rule_log_setting", {}).items():
        base = vsys(f"/rulebase/security/rules/entry[@name='{rule}']")
        if orig_setting:
            api.config_set(f"{base}/log-setting", f"<log-setting>{orig_setting}</log-setting>")
        else:
            api.config_delete(f"{base}/log-setting")
    print(f"    Restored log-setting on {len(state.get('rule_log_setting', {}))} rules")

    # Delete rogue log forwarding profile
    api.config_delete(vsys(f"/log-settings/profiles/entry[@name='{ROGUE_LOG_FWD}']"))
    print(f"    Deleted log forwarding profile '{ROGUE_LOG_FWD}'")

    # Delete rogue syslog server profile
    api.config_delete(dev(f"/server-profile/syslog/entry[@name='{ROGUE_SYSLOG_PROFILE}']"))
    print(f"    Deleted syslog server profile '{ROGUE_SYSLOG_PROFILE}'")


def remove_url_allow_all(api, state):
    # Restore original URL profiles on rules
    for rule, orig_profile in state.get("rule_url_profile", {}).items():
        url_xpath = vsys(f"/rulebase/security/rules/entry[@name='{rule}']/profile-setting/profiles/url-filtering")
        if orig_profile:
            api.config_set(url_xpath, f"<url-filtering><member>{orig_profile}</member></url-filtering>")
        else:
            api.config_delete(url_xpath)
    print(f"    Restored URL filtering on {len(state.get('rule_url_profile', {}))} rules")

    # Delete rogue URL profile
    api.config_delete(vsys(f"/profiles/url-filtering/entry[@name='{ROGUE_URL_PROFILE}']"))
    print(f"    Deleted URL filtering profile '{ROGUE_URL_PROFILE}'")


def restore_security_profiles(api, state):
    for rule, saved_xml in state.get("rule_profiles", {}).items():
        if saved_xml:
            api.config_set(
                vsys(f"/rulebase/security/rules/entry[@name='{rule}']"),
                saved_xml,
            )
            print(f"    Restored security profiles on rule: {rule}")
        else:
            print(f"    Rule '{rule}' had no profiles originally — skipping")


def restore_dns_sinkholing(api, state):
    for profile, saved_xml in state.get("spyware_sinkhole", {}).items():
        if saved_xml:
            api.config_set(
                vsys(f"/profiles/spyware/entry[@name='{profile}']/botnet-domains"),
                saved_xml,
            )
            print(f"    Restored DNS sinkholing in spyware profile: {profile}")


def restore_app_id(api, state):
    for rule, members in state.get("rule_application", {}).items():
        xpath = vsys(f"/rulebase/security/rules/entry[@name='{rule}']/application")
        if members:
            members_xml = "".join(f"<member>{m}</member>" for m in members)
            api.config_edit(xpath, f"<application>{members_xml}</application>")
        else:
            api.config_edit(xpath, "<application><member>any</member></application>")
        print(f"    Restored App-ID on rule: {rule}")


def restore_ssl_decryption(api, state):
    for rule in state.get("decryption_rules_disabled", []):
        xpath = vsys(f"/rulebase/decryption/rules/entry[@name='{rule}']/disabled")
        api.config_delete(xpath)
        print(f"    Re-enabled decryption rule: {rule}")


def remove_permissive_rule(api, state):
    if state.get("rogue_rule_created"):
        api.config_delete(vsys(f"/rulebase/security/rules/entry[@name='{ROGUE_RULE}']"))
        print(f"    Deleted rogue rule: {ROGUE_RULE}")


def restore_zone_flood_protection(api, state):
    for profile, saved_xml in state.get("zone_flood", {}).items():
        if saved_xml:
            api.config_set(
                net(f"/profiles/zone-protection-profile/entry[@name='{profile}']"),
                saved_xml,
            )
            print(f"    Restored flood protection on zone profile: {profile}")


def restore_management_plane(api, state):
    if state.get("management_exposed"):
        saved_xml = state.get("permitted_ips", "")
        if saved_xml:
            api.config_set(dev("/deviceconfig/system"), saved_xml)
            print("    Restored management interface IP restrictions")
        else:
            print("    Management plane had no IP restrictions originally — skipping restore")


def remove_rogue_admin(api, state):
    if state.get("rogue_admin_created"):
        api.config_delete(dev(f"/mgt-config/users/entry[@name='{ROGUE_ADMIN}']"))
        print(f"    Deleted rogue admin: {ROGUE_ADMIN}")


def restore_auth_profile(api, state):
    if state.get("rogue_auth_profile_created"):
        orig = state.get("original_mgmt_auth_profile", "")
        if orig:
            api.config_set(
                dev("/deviceconfig/system/authentication-profile"),
                f"<authentication-profile>{orig}</authentication-profile>",
            )
        else:
            api.config_delete(dev("/deviceconfig/system/authentication-profile"))
        print(f"    Restored management auth profile: '{orig or 'none'}'")

        api.config_delete(dev(f"/mgt-config/authentication-profile/entry[@name='{ROGUE_AUTH_PROFILE}']"))
        print(f"    Deleted rogue auth profile: {ROGUE_AUTH_PROFILE}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

STEPS = [
    ("Restoring security rule logging",         restore_rule_logging),
    ("Removing rogue syslog configuration",     remove_rogue_syslog),
    ("Removing allow-all URL filtering",        remove_url_allow_all),
    ("Restoring security profiles on rules",    restore_security_profiles),
    ("Restoring DNS sinkholing",                restore_dns_sinkholing),
    ("Restoring App-ID on rules",               restore_app_id),
    ("Re-enabling SSL/TLS decryption",          restore_ssl_decryption),
    ("Removing permissive catch-all rule",      remove_permissive_rule),
    ("Restoring zone flood protection",         restore_zone_flood_protection),
    ("Restoring management plane restrictions", restore_management_plane),
    ("Removing rogue admin account",            remove_rogue_admin),
    ("Restoring authentication profile",        restore_auth_profile),
]


def run_cleanup(api):
    if not os.path.exists(STATE_FILE):
        print("[!] No state file found at:")
        print(f"    {STATE_FILE}")
        print("    Run the setup script first.")
        return

    with open(STATE_FILE) as f:
        state = json.load(f)

    print("\n[*] Reversing all dirty state changes...\n")
    for label, func in STEPS:
        print(f"[*] {label}...")
        try:
            func(api, state)
        except Exception as e:
            print(f"    [!] Skipped: {e}")

    api.commit("CCDC Training — Cleanup Complete")

    os.remove(STATE_FILE)
    print(f"\n[*] State file removed: {STATE_FILE}")
    print("[+] Cleanup complete. Firewall restored to pre-exercise state.\n")


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

    run_cleanup(api)

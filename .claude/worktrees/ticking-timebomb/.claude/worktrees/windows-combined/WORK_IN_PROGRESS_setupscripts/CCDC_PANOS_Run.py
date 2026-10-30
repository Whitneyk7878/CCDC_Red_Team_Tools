#!/usr/bin/env python3
"""
CCDC PAN-OS Training - Orchestrator (PAN-OS 11.1.x)

Interactive launcher for the dirty state setup and cleanup scripts.
Handles credentials once and passes a PanosAPI instance to either script.

Usage:
    python3 CCDC_PANOS_Run.py
"""

import getpass
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PANOS_LIB = os.path.join(os.path.dirname(_HERE), "General_Scripts", "SetupScripts", "panos")
sys.path.insert(0, _HERE)
sys.path.insert(0, _PANOS_LIB)
from panos_lib import PanosAPI
from CCDC_PANOS_Setup_DirtyFirewall import run_setup
from CCDC_PANOS_Cleanup import run_cleanup


BANNER = """
╔══════════════════════════════════════════════════════╗
║       CCDC PAN-OS Blue Team Training Script          ║
║       Target: Standalone PAN-OS 11.1.x               ║
╚══════════════════════════════════════════════════════╝
"""

MENU = """
  [1]  Apply dirty state  (start exercise)
  [2]  Run cleanup        (reset firewall)
  [3]  Exit
"""


def get_api() -> PanosAPI:
    host = input("Firewall management IP: ").strip()
    if not host:
        print("[!] No IP provided.")
        sys.exit(1)

    use_key = input("Use a pre-generated API key? (y/N): ").strip().lower() == "y"
    if use_key:
        api_key = input("API key: ").strip()
        return PanosAPI(host, api_key)

    username = input("Username: ").strip()
    password = getpass.getpass("Password: ")

    try:
        api = PanosAPI.from_credentials(host, username, password)
        print("[+] Authenticated — API key generated.")
        return api
    except ValueError as e:
        print(f"[!] Auth failed: {e}")
        print("[*] Enter API key manually as fallback.")
        api_key = input("API key: ").strip()
        return PanosAPI(host, api_key)
    except ConnectionError as e:
        print(f"[!] {e}")
        sys.exit(1)


def main():
    print(BANNER)
    api = get_api()

    while True:
        print(MENU)
        choice = input("Select option: ").strip()

        if choice == "1":
            confirm = input(
                "\n[!] This will apply misconfigurations to the firewall and commit.\n"
                "    Are you sure? (yes/N): "
            ).strip().lower()
            if confirm == "yes":
                run_setup(api)
            else:
                print("Cancelled.")

        elif choice == "2":
            confirm = input(
                "\n[!] This will reverse all dirty state changes and commit.\n"
                "    Are you sure? (yes/N): "
            ).strip().lower()
            if confirm == "yes":
                run_cleanup(api)
            else:
                print("Cancelled.")

        elif choice == "3":
            print("Exiting.")
            break

        else:
            print("Invalid option.")


if __name__ == "__main__":
    main()

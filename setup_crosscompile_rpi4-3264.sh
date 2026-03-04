#!/bin/bash

# ==============================================================================
# Cross-compilation Qt 5.15.2 pour Raspberry Pi 4
# Hôte    : Ubuntu 22.04 x86_64
# Cible   : Raspberry Pi OS Bookworm 32 bits (armhf) ou 64 bits (arm64)
#
# Toolchain : gcc-arm-linux-gnueabihf
# SQL       : QMYSQL (MariaDB) + SQLite intégré
#
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ==============================================================================
# Configuration — adaptez ces valeurs à votre environnement
# ==============================================================================
RPI_USER="pi"
RPI_HOST="192.168.0.102"
RPI_PORT="22"
LOCAL_USER=$(whoami)
LOCAL_GROUP=$(id -gn)
CROSS_DIR="$HOME/cross_rpi4"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

QT_SRC_URL="http://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz"
SYM_LINKER_URL="https://raw.githubusercontent.com/abhiTronix/raspberry-pi-cross-compilers/master/utils/SSymlinker"
RELATIVE_LINKS_SCRIPT_URL="https://raw.githubusercontent.com/riscv/riscv-poky/master/scripts/sysroot-relativelinks.py"

# Variables remplies dynamiquement par detect_rpi_arch()
ARCH_BITS=""
CROSS_COMPILE_PREFIX=""
QT_DEVICE=""
TOOLCHAIN_BIN="/usr/bin"
MKSPEC_SRC=""
MKSPEC_DST=""
PKG_CONFIG_ARCH_PATH=""
MYSQL_INCDIR=""
MYSQL_LIBDIR=""

# ==============================================================================
# Modules Qt à compiler après qtbase
# ==============================================================================
declare -A QT_MODULES=(
    ["qtdeclarative"]="https://code.qt.io/qt/qtdeclarative.git|5.15.2"
    ["qtquickcontrols"]="https://code.qt.io/qt/qtquickcontrols.git|5.15.2"
    ["qtquickcontrols2"]="https://code.qt.io/qt/qtquickcontrols2.git|5.15.2"
    ["qtvirtualkeyboard"]="https://code.qt.io/qt/qtvirtualkeyboard.git|5.15.2"
    ["qtwebsockets"]="https://code.qt.io/qt/qtwebsockets.git|5.15.2"
    ["qtcharts"]="https://code.qt.io/qt/qtcharts.git|5.15.2"
    ["qtconnectivity"]="https://code.qt.io/qt/qtconnectivity.git|5.15.2"
    ["qtmqtt"]="https://code.qt.io/qt/qtmqtt.git|5.15.2"
    ["qtserialport"]="https://code.qt.io/qt/qtserialport.git|5.15.2"
)

MODULES_TO_BUILD=(
    "qtdeclarative"
    "qtquickcontrols"
    "qtquickcontrols2"
    "qtvirtualkeyboard"
    "qtwebsockets"
    "qtcharts"
    "qtconnectivity"
    "qtmqtt"
    "qtserialport"
)

# ==============================================================================
# Utilitaires
# ==============================================================================
executer_locale() {
    echo -e "${GREEN}[LOCAL] $1${NC}"
    eval "$1"
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERREUR LOCALE] $1${NC}"
        exit 1
    fi
}

executer_distante() {
    echo -e "${BLUE}[SSH] $1${NC}"
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "$1"
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERREUR SSH] $1${NC}"
        exit 1
    fi
}

# ==============================================================================
# Détection architecture du RPi
# ==============================================================================
detect_rpi_arch() {
    echo -e "${YELLOW}=== Détection architecture RPi ===${NC}"

    RPI_ARCH=$(ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "uname -m" 2>/dev/null)
    if [ -z "$RPI_ARCH" ]; then
        echo -e "${RED}ERREUR : impossible de joindre le RPi via SSH.${NC}"
        exit 1
    fi
    RPI_DEB_ARCH=$(ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" \
        "dpkg --print-architecture" 2>/dev/null)

    echo -e "${YELLOW}  uname -m                  : $RPI_ARCH${NC}"
    echo -e "${YELLOW}  dpkg --print-architecture : $RPI_DEB_ARCH${NC}"

    if [[ "$RPI_DEB_ARCH" == "arm64" ]]; then
        ARCH_BITS=64
        CROSS_COMPILE_PREFIX="aarch64-linux-gnu-"
        QT_DEVICE="linux-aarch64-gnu-g++"
        MKSPEC_SRC="linux-arm-gnueabi-g++"
        MKSPEC_DST="linux-aarch64-gnu-g++"
        PKG_CONFIG_ARCH_PATH="aarch64-linux-gnu"
        echo -e "${YELLOW}  >>> Userland 64 bits (arm64)${NC}"

    elif [[ "$RPI_DEB_ARCH" == "armhf" ]]; then
        ARCH_BITS=32
        CROSS_COMPILE_PREFIX="arm-linux-gnueabihf-"
        QT_DEVICE="linux-rasp-pi4-v3d-g++"
        MKSPEC_SRC="linux-arm-gnueabi-g++"
        MKSPEC_DST="linux-arm-gnueabihf-g++"
        PKG_CONFIG_ARCH_PATH="arm-linux-gnueabihf"
        echo -e "${YELLOW}  >>> Userland 32 bits (armhf)${NC}"
        if [[ "$RPI_ARCH" == "aarch64" ]]; then
            echo -e "${YELLOW}      (noyau 64 bits + userland 32 bits — RPi OS Bookworm 32 bits)${NC}"
        fi

    else
        echo -e "${RED}Architecture Debian non reconnue : '$RPI_DEB_ARCH'${NC}"
        echo -e "${RED}Valeurs attendues : 'armhf' ou 'arm64'${NC}"
        exit 1
    fi

    MYSQL_INCDIR="$CROSS_DIR/sysroot/usr/include/mariadb"
    MYSQL_LIBDIR="$CROSS_DIR/sysroot/usr/lib/$PKG_CONFIG_ARCH_PATH"

    echo -e "${YELLOW}  Bits          : $ARCH_BITS${NC}"
    echo -e "${YELLOW}  Cross-compile : $CROSS_COMPILE_PREFIX${NC}"
    echo -e "${YELLOW}  Qt device     : $QT_DEVICE${NC}"
    echo -e "${YELLOW}  MYSQL_INCDIR  : $MYSQL_INCDIR${NC}"
    echo -e "${YELLOW}  MYSQL_LIBDIR  : $MYSQL_LIBDIR${NC}"
}

# ==============================================================================
# Installation toolchain croisée via apt
# ==============================================================================
install_cross_toolchain() {
    echo -e "${GREEN}=== Installation toolchain croisée ===${NC}"
    if [ "$ARCH_BITS" -eq 64 ]; then
        executer_locale "sudo apt install -y \
            gcc-aarch64-linux-gnu \
            g++-aarch64-linux-gnu \
            binutils-aarch64-linux-gnu"
        echo -e "${GREEN}  $(aarch64-linux-gnu-gcc --version | head -1)${NC}"
    else
        executer_locale "sudo apt install -y \
            gcc-arm-linux-gnueabihf \
            g++-arm-linux-gnueabihf \
            binutils-arm-linux-gnueabihf"
        echo -e "${GREEN}  $(arm-linux-gnueabihf-gcc --version | head -1)${NC}"
    fi
}

# ==============================================================================
# Patch Qt 5.15.2 pour gcc >= 11 — version sed
#
# Problème : Qt 5.15.2 utilise std::numeric_limits dans plusieurs fichiers
# sans inclure <limits>. gcc >= 11 est strict sur ce point et refuse de
# compiler avec "numeric_limits is not a member of std".
#
# Solution : insérer #include <limits> avant QT_BEGIN_NAMESPACE dans chaque
# fichier concerné, via sed.
#
# Fichiers connus affectés dans Qt 5.15.2 :
#   qfloat16.h, qbytearraymatcher.h, qoffsetstringarray_p.h,
#   qendian.h, qstring.h, qstringview.h
# ==============================================================================
patch_qt5_gcc11() {
    echo -e "${GREEN}=== Patch Qt 5.15.2 pour gcc >= 11 ===${NC}"

    local QT_SRC="$CROSS_DIR/qt-everywhere-src-5.15.2"

    if [ ! -d "$QT_SRC" ]; then
        echo -e "${RED}ERREUR : répertoire Qt source introuvable : $QT_SRC${NC}"
        exit 1
    fi

    local FILES_TO_PATCH="
        qtbase/src/corelib/global/qfloat16.h
        qtbase/src/corelib/text/qbytearraymatcher.h
        qtbase/src/corelib/tools/qoffsetstringarray_p.h
        qtbase/src/corelib/global/qendian.h
        qtbase/src/corelib/text/qstring.h
        qtbase/src/corelib/text/qstringview.h
    "

    local patched=0
    local already=0
    local skipped=0

    for rel_path in $FILES_TO_PATCH; do
        local full_path="$QT_SRC/$rel_path"

        if [ ! -f "$full_path" ]; then
            echo -e "${YELLOW}  [SKIP] Non trouvé : $rel_path${NC}"
            skipped=$((skipped + 1))
            continue
        fi

        if grep -q '#include <limits>' "$full_path"; then
            echo -e "${GREEN}  [OK]   Déjà patché : $rel_path${NC}"
            already=$((already + 1))
            continue
        fi

        if grep -q 'QT_BEGIN_NAMESPACE' "$full_path"; then
            # Insérer #include <limits> juste avant QT_BEGIN_NAMESPACE
            sed -i '/QT_BEGIN_NAMESPACE/i #include <limits>' "$full_path"
        else
            # Fallback : insérer après le dernier #include existant
            local last_include
            last_include=$(grep -n '^#include' "$full_path" | tail -1 | cut -d: -f1)
            if [ -n "$last_include" ]; then
                sed -i "${last_include}a #include <limits>" "$full_path"
            else
                echo -e "${YELLOW}  [WARN] Impossible de patcher : $rel_path${NC}"
                continue
            fi
        fi

        # Vérification que le patch a bien été appliqué
        if grep -q '#include <limits>' "$full_path"; then
            echo -e "${GREEN}  [PATCH] $rel_path${NC}"
            patched=$((patched + 1))
        else
            echo -e "${RED}  [ECHEC] Patch non appliqué : $rel_path${NC}"
        fi
    done

    echo -e "${GREEN}  Résultat : $patched patché(s), $already déjà OK, $skipped non trouvé(s)${NC}"
}

# ==============================================================================
# Mkspec Qt pour aarch64 (Qt 5 n'en fournit pas nativement)
# ==============================================================================
create_aarch64_mkspec() {
    [ "$ARCH_BITS" -ne 64 ] && return 0
    local DST="$CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs/$MKSPEC_DST"
    if [ -d "$DST" ]; then
        echo -e "${GREEN}Mkspec $MKSPEC_DST déjà présent.${NC}"
        return 0
    fi
    executer_locale "cp -R \
        $CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs/$MKSPEC_SRC $DST"
    cat > "$DST/qmake.conf" << 'EOF'
MAKEFILE_GENERATOR      = UNIX
CONFIG                 += incremental
QMAKE_INCREMENTAL_STYLE = sublib
include(../common/linux.conf)
include(../common/gcc-base-unix.conf)
include(../common/g++-unix.conf)
QMAKE_CC                = aarch64-linux-gnu-gcc
QMAKE_CXX               = aarch64-linux-gnu-g++
QMAKE_LINK              = aarch64-linux-gnu-g++
QMAKE_LINK_SHLIB        = aarch64-linux-gnu-g++
QMAKE_AR                = aarch64-linux-gnu-ar cqs
QMAKE_OBJCOPY           = aarch64-linux-gnu-objcopy
QMAKE_NM                = aarch64-linux-gnu-nm -P
QMAKE_STRIP             = aarch64-linux-gnu-strip
load(qt_config)
EOF
    echo -e "${GREEN}Mkspec aarch64 créé.${NC}"
}

# ==============================================================================
# Vérification MariaDB dans le sysroot
# ==============================================================================
verify_mysql_sysroot() {
    echo -e "${GREEN}=== Vérification MariaDB dans le sysroot ===${NC}"

    if [ ! -f "$MYSQL_INCDIR/mysql.h" ]; then
        echo -e "${RED}ERREUR : $MYSQL_INCDIR/mysql.h introuvable !${NC}"
        echo -e "${RED}libmariadb-dev doit être installé sur le RPi AVANT le rsync.${NC}"
        exit 1
    fi
    echo -e "${GREEN}  mysql.h : OK${NC}"

    MYSQL_LIB_FOUND=""
    for libname in "libmariadb.so" "libmariadbclient.so" "libmysqlclient.so"; do
        if [ -f "$MYSQL_LIBDIR/$libname" ]; then
            MYSQL_LIB_FOUND="$MYSQL_LIBDIR/$libname"
            break
        fi
    done

    if [ -z "$MYSQL_LIB_FOUND" ]; then
        echo -e "${YELLOW}  Recherche libmariadb dans tout le sysroot...${NC}"
        MYSQL_LIB_FOUND=$(find "$CROSS_DIR/sysroot" \
            -name "libmariadb*.so*" 2>/dev/null | head -1)
        if [ -n "$MYSQL_LIB_FOUND" ]; then
            MYSQL_LIBDIR=$(dirname "$MYSQL_LIB_FOUND")
            echo -e "${YELLOW}  MYSQL_LIBDIR ajusté : $MYSQL_LIBDIR${NC}"
        else
            echo -e "${RED}ERREUR : libmariadb.so introuvable dans le sysroot.${NC}"
            exit 1
        fi
    fi

    echo -e "${GREEN}  MYSQL_INCDIR  : $MYSQL_INCDIR${NC}"
    echo -e "${GREEN}  MYSQL_LIBDIR  : $MYSQL_LIBDIR${NC}"
    echo -e "${GREEN}  Bibliothèque  : $MYSQL_LIB_FOUND${NC}"
}

# ==============================================================================
# ==============================================================================
# DÉBUT DU SCRIPT PRINCIPAL
# ==============================================================================
# ==============================================================================

echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}  Cross-compilation Qt 5.15.2 + QMYSQL + SQLite — RPi4     ${NC}"
echo -e "${YELLOW}  Toolchain : gcc-arm-linux-gnueabihf (apt, pas de Linaro)  ${NC}"
echo -e "${YELLOW}  Patch gcc >= 11 : sed direct, fiable                      ${NC}"
echo -e "${YELLOW}============================================================${NC}"

# ==============================================================================
# SSH
# ==============================================================================
echo -e "${GREEN}=== Configuration SSH ===${NC}"
if [ ! -f "$SSH_KEY_PATH" ]; then
    executer_locale "ssh-keygen -t rsa -f $SSH_KEY_PATH -N ''"
else
    echo -e "${GREEN}Clé SSH existante : $SSH_KEY_PATH${NC}"
fi

if ! ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" \
    "grep -qF \"\$(cat $SSH_KEY_PATH.pub)\" ~/.ssh/authorized_keys" 2>/dev/null; then
    executer_locale "ssh-copy-id -i $SSH_KEY_PATH.pub -p $RPI_PORT $RPI_USER@$RPI_HOST"
else
    echo -e "${GREEN}Clé publique déjà présente sur le RPi.${NC}"
fi

# ==============================================================================
# Détection architecture — EN PREMIER
# ==============================================================================
detect_rpi_arch

# ==============================================================================
# Partie 1 : Configuration RPi4
# ORDRE CRITIQUE : MariaDB dev AVANT rsync sysroot
# ==============================================================================
echo -e "${BLUE}=== Partie 1 : Configuration RPi4 ===${NC}"

# --- WiringPi ---
echo -e "${BLUE}--- WiringPi ---${NC}"
if [ "$ARCH_BITS" -eq 32 ]; then DEB_ARCH_PKG="armhf"; else DEB_ARCH_PKG="arm64"; fi

WIRINGPI_URL=$(curl -s \
    https://api.github.com/repos/WiringPi/WiringPi/releases/latest \
    | grep "browser_download_url.*${DEB_ARCH_PKG}.deb" \
    | cut -d '"' -f 4)

if [ -n "$WIRINGPI_URL" ]; then
    echo -e "${BLUE}  URL : $WIRINGPI_URL${NC}"
    executer_distante "wget -O /tmp/wiringpi.deb '$WIRINGPI_URL'"
    # ; au lieu de && pour que apt-get -f s'exécute même si dpkg échoue
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" \
        "sudo dpkg -i /tmp/wiringpi.deb ; \
         sudo apt-get install -f -y && \
         rm -f /tmp/wiringpi.deb && \
         echo '  WiringPi installé.'"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Echec installation WiringPi.${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}  Aucun paquet WiringPi ${DEB_ARCH_PKG} — ignoré.${NC}"
fi

# --- deb-src ---
executer_distante \
    "sudo grep -q '^#deb-src' /etc/apt/sources.list && \
     sudo sed -i '/^#deb-src/s/^#//' /etc/apt/sources.list || true"

# --- Mise à jour système ---
executer_distante "sudo apt update && sudo apt upgrade -y"

# --- Dépendances Qt 5 ---
echo -e "${BLUE}--- Dépendances Qt 5 ---${NC}"
executer_distante "
    sudo apt-get build-dep -y \
        qt5-qmake libqt5gui5 libqt5webengine-data libqt5webkit5 || true
    sudo apt install -y \
        libudev-dev libinput-dev libts-dev \
        libxcb-xinerama0-dev libxcb-xinerama0 gdbserver \
        qtbase5-dev qtchooser qtbase5-dev-tools \
        libegl1-mesa-dev libgles2-mesa-dev libgbm-dev mesa-common-dev \
        libx11-xcb-dev libglu1-mesa-dev libxrender-dev libxi-dev \
        libxkbcommon-dev libxkbcommon-x11-dev fonts-texgyre libts-dev \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
        libopenal-dev pulseaudio bluez-tools libbluetooth-dev
    sudo apt install -y '^libxcb.*-dev' || true
"

# --- MariaDB dev — DOIT être AVANT le rsync ---
echo -e "${BLUE}--- MariaDB dev (AVANT rsync sysroot) ---${NC}"
executer_distante "
    sudo apt install -y libmariadb-dev libmariadb-dev-compat libmariadb3
    test -f /usr/include/mariadb/mysql.h \
        && echo '  [OK] mysql.h présent' \
        || echo '  [KO] mysql.h MANQUANT'
"
# Serveur MySQL local sur le RPi — décommentez si besoin :
# executer_distante "
#     sudo apt install -y mariadb-server mariadb-client
#     sudo systemctl enable mariadb && sudo systemctl start mariadb
# "

# --- Répertoires + sudoers ---
executer_distante "
    sudo gpasswd -a $RPI_USER render || true
    sudo mkdir -p /usr/local/qt5.15
    sudo chown $RPI_USER:$RPI_USER /usr/local/qt5.15
"

executer_distante "
    if ! sudo grep -qF '$LOCAL_USER ALL=NOPASSWD:/usr/bin/rsync' /etc/sudoers; then
        echo '$LOCAL_USER ALL=NOPASSWD:/usr/bin/rsync' | sudo tee --append /etc/sudoers
        echo '  Règle sudoers rsync ajoutée.'
    else
        echo '  Règle sudoers rsync déjà présente.'
    fi
    sudo visudo -c && echo '  sudoers valide.' || { echo 'ERREUR sudoers !'; exit 1; }
"

# --- SSymlinker ---
echo -e "${BLUE}--- SSymlinker ---${NC}"
executer_distante \
    "wget '$SYM_LINKER_URL' -O /tmp/SSymlinker && sudo chmod +x /tmp/SSymlinker"

for SYM_SRC in \
    "/usr/include/$PKG_CONFIG_ARCH_PATH/asm" \
    "/usr/include/$PKG_CONFIG_ARCH_PATH/gnu" \
    "/usr/include/$PKG_CONFIG_ARCH_PATH/bits" \
    "/usr/include/$PKG_CONFIG_ARCH_PATH/sys" \
    "/usr/include/$PKG_CONFIG_ARCH_PATH/openssl"; do
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "
        if [ -d '$SYM_SRC' ]; then
            /tmp/SSymlinker -s '$SYM_SRC' -d /usr/include \
                && echo '  [OK]   $SYM_SRC' \
                || echo '  [WARN] Lien existant : $SYM_SRC'
        else
            echo '  [SKIP] Absent : $SYM_SRC'
        fi
    "
done

for SYM_SRC in \
    "/usr/lib/$PKG_CONFIG_ARCH_PATH/crtn.o" \
    "/usr/lib/$PKG_CONFIG_ARCH_PATH/crt1.o" \
    "/usr/lib/$PKG_CONFIG_ARCH_PATH/crti.o"; do
    SYM_DST="/usr/lib/$(basename $SYM_SRC)"
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "
        if [ -f '$SYM_SRC' ]; then
            /tmp/SSymlinker -s '$SYM_SRC' -d '$SYM_DST' \
                && echo '  [OK]   $SYM_SRC' \
                || echo '  [WARN] Lien existant : $SYM_SRC'
        else
            echo '  [SKIP] Absent : $SYM_SRC'
        fi
    "
done

# ==============================================================================
# Partie 2 : Configuration PC Ubuntu hôte
# ==============================================================================
echo -e "${GREEN}=== Partie 2 : Configuration PC Ubuntu ===${NC}"

executer_locale "sudo apt update && sudo apt dist-upgrade -y"
executer_locale "sudo apt install -y \
    build-essential cmake unzip gfortran git bison \
    python3 python-is-python3 gperf pkg-config gdb-multiarch wget curl \
    flex texinfo gawk openssl pigz libncurses-dev autoconf automake tar \
    libxkbcommon-dev libxkbcommon-x11-dev \
    libx11-xcb-dev libglu1-mesa-dev libxrender-dev libxi-dev"
executer_locale "sudo apt-get install -y '^libxcb.*-dev'"

executer_locale "mkdir -p \
    $CROSS_DIR/build \
    $CROSS_DIR/sysroot/usr \
    $CROSS_DIR/sysroot/opt"
executer_locale "sudo chown -R $LOCAL_USER:$LOCAL_GROUP $CROSS_DIR"

install_cross_toolchain

# ==============================================================================
# Partie 3 : Synchronisation sysroot depuis le RPi
# APRÈS installation MariaDB (Partie 1) → headers inclus dans le rsync
# ==============================================================================
echo -e "${GREEN}=== Partie 3 : Synchronisation sysroot ===${NC}"
echo -e "${GREEN}    (headers MariaDB inclus dans ce rsync)${NC}"

executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
    $RPI_USER@$RPI_HOST:/lib $CROSS_DIR/sysroot"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
    $RPI_USER@$RPI_HOST:/usr/include $CROSS_DIR/sysroot/usr"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
    $RPI_USER@$RPI_HOST:/usr/lib $CROSS_DIR/sysroot/usr"

if ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "[ -d /opt/vc ]"; then
    executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
        $RPI_USER@$RPI_HOST:/opt/vc $CROSS_DIR/sysroot/opt/" || \
        executer_locale "scp -r \
            $RPI_USER@$RPI_HOST:/opt/vc $CROSS_DIR/sysroot/opt/"
else
    echo -e "${GREEN}/opt/vc absent (normal sur Bookworm).${NC}"
    executer_locale "mkdir -p $CROSS_DIR/sysroot/opt/vc"
fi

executer_locale "wget '$RELATIVE_LINKS_SCRIPT_URL' -O $CROSS_DIR/relative_links.py"
executer_locale "chmod +x $CROSS_DIR/relative_links.py"
executer_locale "$CROSS_DIR/relative_links.py $CROSS_DIR/sysroot"

verify_mysql_sysroot

# ==============================================================================
# Partie 4 : Sources Qt 5.15.2 + PATCH gcc >= 11
# ==============================================================================
echo -e "${GREEN}=== Partie 4 : Sources Qt 5.15.2 ===${NC}"

if [ ! -d "$CROSS_DIR/qt-everywhere-src-5.15.2" ]; then
    echo -e "${GREEN}Téléchargement sources Qt 5.15.2 (~600 Mo)...${NC}"
    executer_locale "wget '$QT_SRC_URL' -O $CROSS_DIR/qt-src.tar.xz"
    executer_locale "cd $CROSS_DIR && tar xfv qt-src.tar.xz && rm qt-src.tar.xz"
else
    echo -e "${GREEN}Sources Qt 5.15.2 déjà présentes.${NC}"
fi

# Patch COMPLET gcc >= 11 — sed direct, sans Python, sans heredoc
patch_qt5_gcc11

# Mkspec selon architecture
if [ "$ARCH_BITS" -eq 32 ]; then
    MKSPEC_DIR="$CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs"
    if [ ! -d "$MKSPEC_DIR/$MKSPEC_DST" ]; then
        executer_locale "cp -R $MKSPEC_DIR/$MKSPEC_SRC $MKSPEC_DIR/$MKSPEC_DST"
        executer_locale "sed -i \
            's/arm-linux-gnueabi-/arm-linux-gnueabihf-/g' \
            $MKSPEC_DIR/$MKSPEC_DST/qmake.conf"
        echo -e "${GREEN}Mkspec armhf créé.${NC}"
    else
        echo -e "${GREEN}Mkspec armhf déjà présent.${NC}"
    fi
else
    create_aarch64_mkspec
fi

# ==============================================================================
# Partie 5 : Compilation Qt 5.15.2 qtbase
# ==============================================================================
echo -e "${GREEN}=== Partie 5 : Compilation Qt 5.15.2 qtbase ===${NC}"
echo -e "${GREEN}    SQL      : -sql-sqlite -sql-mysql${NC}"
echo -e "${GREEN}    Device   : $QT_DEVICE${NC}"
echo -e "${GREEN}    Toolchain: $TOOLCHAIN_BIN/$CROSS_COMPILE_PREFIX (${ARCH_BITS} bits)${NC}"

executer_locale "rm -rf $CROSS_DIR/build && mkdir -p $CROSS_DIR/build"

executer_locale "
    cd $CROSS_DIR/build && \
    ../qt-everywhere-src-5.15.2/configure \
        -release \
        -opengl es2 \
        -eglfs \
        -no-feature-eglfs_brcm \
        -bundled-xcb-xinput \
        -device $QT_DEVICE \
        -device-option CROSS_COMPILE=$TOOLCHAIN_BIN/$CROSS_COMPILE_PREFIX \
        -sysroot $CROSS_DIR/sysroot \
        -prefix /usr/local/qt5.15 \
        -extprefix $CROSS_DIR/qt5.15 \
        -opensource -confirm-license \
        -skip qtscript \
        -skip qtwayland \
        -skip qtwebengine \
        -nomake tests \
        -make libs \
        -pkg-config \
        -no-use-gold-linker \
        -sql-sqlite \
        -sql-mysql \
        MYSQL_INCDIR=$MYSQL_INCDIR \
        MYSQL_LIBDIR=$MYSQL_LIBDIR \
        -v -recheck
"

# Vérification MySQL dans config.summary
echo -e "${YELLOW}=== Vérification détection MySQL ===${NC}"
if [ -f "$CROSS_DIR/build/config.summary" ]; then
    if grep -qi "mysql\|sqlite" "$CROSS_DIR/build/config.summary"; then
        echo -e "${GREEN}Lignes SQL :${NC}"
        grep -i "mysql\|sqlite" "$CROSS_DIR/build/config.summary"
    else
        echo -e "${RED}MySQL absent de config.summary — QMYSQL ne sera pas compilé !${NC}"
    fi
fi

echo -e "${GREEN}=== make -j$(nproc) ===${NC}"
executer_locale "cd $CROSS_DIR/build && make -j$(nproc)"

echo -e "${GREEN}=== make install ===${NC}"
executer_locale "cd $CROSS_DIR/build && make install"

# Vérification plugins
echo -e "${GREEN}=== Plugins SQL produits ===${NC}"
PLUGIN_DIR="$CROSS_DIR/qt5.15/plugins/sqldrivers"
if [ -d "$PLUGIN_DIR" ]; then
    ls -la "$PLUGIN_DIR/"
    [ -f "$PLUGIN_DIR/libqsqlmysql.so" ] \
        && echo -e "${GREEN}[OK] libqsqlmysql.so${NC}" \
        || echo -e "${RED}[KO] libqsqlmysql.so ABSENT${NC}"
    [ -f "$PLUGIN_DIR/libqsqlite.so" ] \
        && echo -e "${GREEN}[OK] libqsqlite.so${NC}" \
        || echo -e "${RED}[KO] libqsqlite.so ABSENT${NC}"
else
    echo -e "${RED}Dossier sqldrivers absent.${NC}"
fi

# ==============================================================================
# Partie 6 : Modules Qt supplémentaires
# ==============================================================================
echo -e "${YELLOW}=== Partie 6 : Modules Qt supplémentaires ===${NC}"

for module in "${MODULES_TO_BUILD[@]}"; do
    MODULE_ENTRY="${QT_MODULES[$module]}"
    url="${MODULE_ENTRY%%|*}"       # tout avant le premier |
    version="${MODULE_ENTRY##*|}"   # tout après le dernier |
    echo -e "${YELLOW}--- $module (v$version) ---${NC}"
    if [ ! -d "$CROSS_DIR/$module" ]; then
        executer_locale \
            "cd $CROSS_DIR && git clone $url -b v$version --depth 1 $module"
    else
        echo -e "${YELLOW}    Sources déjà présentes.${NC}"
    fi
    executer_locale "
        cd $CROSS_DIR/$module && \
        $CROSS_DIR/qt5.15/bin/qmake && \
        make -j$(nproc) && \
        make install
    "
    echo -e "${GREEN}    $module : OK${NC}"
done

# ==============================================================================
# Partie 7 : Déploiement sur le RPi
# ==============================================================================
echo -e "${GREEN}=== Partie 7 : Déploiement sur le RPi ===${NC}"

executer_locale "rsync -avz --rsync-path='sudo rsync' \
    $CROSS_DIR/qt5.15/ $RPI_USER@$RPI_HOST:/usr/local/qt5.15"

executer_distante "
    echo '/usr/local/qt5.15/lib' | sudo tee /etc/ld.so.conf.d/qt5pi.conf
    sudo ldconfig
    echo ''
    echo '--- Plugins SQL déployés ---'
    ls -la /usr/local/qt5.15/plugins/sqldrivers/ 2>/dev/null \
        || echo 'Dossier sqldrivers non trouvé'
    echo ''
    echo '--- Runtime libmariadb ---'
    ldconfig -p | grep mariadb || echo 'libmariadb non trouvée dans ldconfig'
"

# ==============================================================================
# Résumé final
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Qt 5.15.2 + QMYSQL + SQLite installés avec succès !     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Architecture  : ${ARCH_BITS} bits (${PKG_CONFIG_ARCH_PATH})  ${NC}"
echo -e "${GREEN}  Toolchain     : ${CROSS_COMPILE_PREFIX}gcc (apt)             ${NC}"
echo -e "${GREEN}  Qt staging PC : $CROSS_DIR/qt5.15                           ${NC}"
echo -e "${GREEN}  Qt sur RPi    : /usr/local/qt5.15                           ${NC}"
echo -e "${GREEN}  Plugins SQL   : /usr/local/qt5.15/plugins/sqldrivers/       ${NC}"
echo ""
echo -e "${YELLOW}  Dans votre .pro :                                         ${NC}"
echo -e "${YELLOW}    QT += sql                                               ${NC}"
echo -e "${YELLOW}  Vérifier les drivers au runtime :                        ${NC}"
echo -e "${YELLOW}    qDebug() << QSqlDatabase::drivers();                   ${NC}"
echo -e "${YELLOW}    // Attendu : (\"QSQLITE\", \"QMYSQL\")                ${NC}"
echo -e "${GREEN}============================================================${NC}"

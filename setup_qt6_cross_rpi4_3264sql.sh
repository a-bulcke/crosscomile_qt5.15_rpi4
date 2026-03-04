#!/bin/bash

# ==============================================================================
# Cross-compilation Qt 6.10 pour Raspberry Pi 4
# Hôte    : Ubuntu 22.04 x86_64
# Cible   : Raspberry Pi OS Bookworm 32 bits (armhf) ou 64 bits (arm64)
#
# Build   : CMake + Ninja (obligatoire en Qt 6)
#           qmake généré automatiquement et disponible après installation
#
# SQL     : QMYSQL (MariaDB) + SQLite intégré
#
# Architecture Qt 6 — deux builds obligatoires :
#   1. BUILD HOST   : qtbase + qtshadertools compilés pour x86_64
#                     → fournit les outils de build (moc, rcc, qmake, etc.)
#   2. BUILD TARGET : tous les modules cross-compilés pour ARM
#                     → ce qui sera déployé sur le RPi
#
# Détection architecture : dpkg --print-architecture en priorité
#   RPi OS Bookworm 32 bits : uname=aarch64, dpkg=armhf → mode 32 bits
#
# Corrections issues de l'expérience Qt 5 :
#   - sudoers : /usr/bin/rsync en dur, anti-doublon
#   - WiringPi : dpkg non bloquant + apt-get -f
#   - SSymlinker : vérification existence avant création lien
#   - MariaDB dev installé AVANT le rsync du sysroot
#   - URLs modules : https:// (git:// désactivé sur code.qt.io)
#   - Séparateur | dans les URLs (évite conflit avec : dans https://)
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
RPI_HOST="10.0.2.3"
RPI_PORT="22"
LOCAL_USER=$(whoami)
LOCAL_GROUP=$(id -gn)

QT_VERSION="6.10.0"
QT_VERSION_SHORT="6.10"

CROSS_DIR="$HOME/cross_rpi4_qt6"
QT_SRC_DIR="$CROSS_DIR/src"

# Build host (x86_64) — outils de build uniquement
QT_HOST_BUILD="$CROSS_DIR/host-build"
QT_HOST_INSTALL="$CROSS_DIR/host"

# Build target (ARM) — ce qui va sur le RPi
QT_TARGET_BUILD="$CROSS_DIR/target-build"
QT_TARGET_STAGING="$CROSS_DIR/target"   # installation locale (staging)
QT_TARGET_PREFIX="/usr/local/qt6"       # chemin final sur le RPi

SYSROOT="$CROSS_DIR/sysroot"
TOOLCHAIN_FILE="$CROSS_DIR/toolchain.cmake"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

QT_BASE_DOWNLOAD_URL="https://download.qt.io/official_releases/qt/${QT_VERSION_SHORT}/${QT_VERSION}/submodules"
SYM_LINKER_URL="https://raw.githubusercontent.com/abhiTronix/raspberry-pi-cross-compilers/master/utils/SSymlinker"
RELATIVE_LINKS_SCRIPT_URL="https://raw.githubusercontent.com/riscv/riscv-poky/master/scripts/sysroot-relativelinks.py"

# Variables remplies dynamiquement par detect_rpi_arch()
ARCH_BITS=""
CROSS_COMPILE_PREFIX=""
CMAKE_SYSTEM_PROCESSOR=""
PKG_CONFIG_ARCH_PATH=""
QT_DEVICE_MK=""
MYSQL_INCDIR=""
MYSQL_LIBDIR=""

# ==============================================================================
# Modules Qt 6 à compiler pour le TARGET (ARM)
# Séparateur | pour éviter conflit avec : dans https://
# Ordre IMPORTANT : qtshadertools avant qtdeclarative
# ==============================================================================
declare -A QT_MODULES=(
    ["qtshadertools"]="https://code.qt.io/qt/qtshadertools.git|${QT_VERSION}"
    ["qtdeclarative"]="https://code.qt.io/qt/qtdeclarative.git|${QT_VERSION}"
    ["qtvirtualkeyboard"]="https://code.qt.io/qt/qtvirtualkeyboard.git|${QT_VERSION}"
    ["qtwebsockets"]="https://code.qt.io/qt/qtwebsockets.git|${QT_VERSION}"
    ["qtcharts"]="https://code.qt.io/qt/qtcharts.git|${QT_VERSION}"
    ["qtconnectivity"]="https://code.qt.io/qt/qtconnectivity.git|${QT_VERSION}"
    ["qtmultimedia"]="https://code.qt.io/qt/qtmultimedia.git|${QT_VERSION}"
    ["qtserialport"]="https://code.qt.io/qt/qtserialport.git|${QT_VERSION}"
    ["qtimageformats"]="https://code.qt.io/qt/qtimageformats.git|${QT_VERSION}"
    ["qtmqtt"]="https://code.qt.io/qt/qtmqtt.git|${QT_VERSION_SHORT}"
)

# Ordre de compilation : qtshadertools DOIT précéder qtdeclarative
MODULES_TO_BUILD=(
    "qtshadertools"
    "qtdeclarative"
    "qtvirtualkeyboard"
    "qtwebsockets"
    "qtcharts"
    "qtconnectivity"
    "qtmultimedia"
    "qtserialport"
    "qtimageformats"
    "qtmqtt"
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
# PRIORITÉ à dpkg --print-architecture (userland réel)
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
        CMAKE_SYSTEM_PROCESSOR="aarch64"
        PKG_CONFIG_ARCH_PATH="aarch64-linux-gnu"
        QT_DEVICE_MK="linux-rasp-pi4-aarch64"
        CMAKE_MARCH="-march=armv8-a -mtune=cortex-a72"
        echo -e "${YELLOW}  >>> Userland 64 bits (arm64)${NC}"

    elif [[ "$RPI_DEB_ARCH" == "armhf" ]]; then
        ARCH_BITS=32
        CROSS_COMPILE_PREFIX="arm-linux-gnueabihf-"
        CMAKE_SYSTEM_PROCESSOR="arm"
        PKG_CONFIG_ARCH_PATH="arm-linux-gnueabihf"
        QT_DEVICE_MK="linux-rasp-pi4-v3d-g++"
        CMAKE_MARCH="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -mtune=cortex-a72"
        echo -e "${YELLOW}  >>> Userland 32 bits (armhf)${NC}"
        if [[ "$RPI_ARCH" == "aarch64" ]]; then
            echo -e "${YELLOW}      (noyau 64 bits + userland 32 bits — RPi OS Bookworm 32 bits)${NC}"
        fi

    else
        echo -e "${RED}Architecture non reconnue : '$RPI_DEB_ARCH'${NC}"
        exit 1
    fi

    MYSQL_INCDIR="$SYSROOT/usr/include/mariadb"
    MYSQL_LIBDIR="$SYSROOT/usr/lib/$PKG_CONFIG_ARCH_PATH"

    echo -e "${YELLOW}  Bits            : $ARCH_BITS${NC}"
    echo -e "${YELLOW}  Cross-compile   : $CROSS_COMPILE_PREFIX${NC}"
    echo -e "${YELLOW}  Qt device mkspec: $QT_DEVICE_MK${NC}"
    echo -e "${YELLOW}  MYSQL_INCDIR    : $MYSQL_INCDIR${NC}"
    echo -e "${YELLOW}  MYSQL_LIBDIR    : $MYSQL_LIBDIR${NC}"
}

# ==============================================================================
# Installation toolchain croisée via apt
# Qt 6 nécessite gcc >= 11 — Ubuntu 22.04 fournit gcc-12 : parfait
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
# Génération du fichier toolchain.cmake
# Utilisé par CMake pour cross-compiler Qt target
# ==============================================================================
generate_toolchain_cmake() {
    echo -e "${GREEN}=== Génération toolchain.cmake ===${NC}"

    if [ "$ARCH_BITS" -eq 64 ]; then
        CC_CROSS="/usr/bin/aarch64-linux-gnu-gcc"
        CXX_CROSS="/usr/bin/aarch64-linux-gnu-g++"
    else
        CC_CROSS="/usr/bin/arm-linux-gnueabihf-gcc"
        CXX_CROSS="/usr/bin/arm-linux-gnueabihf-g++"
    fi

    cat > "$TOOLCHAIN_FILE" << EOF
cmake_minimum_required(VERSION 3.18)
include_guard(GLOBAL)

# ==============================================================
# Toolchain Qt 6 cross-compilation → Raspberry Pi 4
# Architecture : ${ARCH_BITS} bits (${PKG_CONFIG_ARCH_PATH})
# Généré automatiquement par cross_compile_qt6_rpi4_mysql.sh
# ==============================================================

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${CMAKE_SYSTEM_PROCESSOR})

set(TARGET_SYSROOT ${SYSROOT})
set(CMAKE_SYSROOT \${TARGET_SYSROOT})

set(CMAKE_C_COMPILER   ${CC_CROSS})
set(CMAKE_CXX_COMPILER ${CXX_CROSS})

# Flags de compilation pour Cortex-A72 (RPi4)
set(CMAKE_C_FLAGS_INIT   "${CMAKE_MARCH}")
set(CMAKE_CXX_FLAGS_INIT "${CMAKE_MARCH}")

set(QT_COMPILER_FLAGS         "${CMAKE_MARCH}")
set(QT_COMPILER_FLAGS_RELEASE "-O2 -pipe")
set(QT_LINKER_FLAGS           "-Wl,-O1 -Wl,--hash-style=gnu -Wl,--as-needed")

# pkg-config : pointer vers le sysroot ARM
set(ENV{PKG_CONFIG_PATH}
    "${SYSROOT}/usr/lib/${PKG_CONFIG_ARCH_PATH}/pkgconfig:\${ENV{PKG_CONFIG_PATH}}")
set(ENV{PKG_CONFIG_LIBDIR}
    "/usr/lib/pkgconfig:/usr/share/pkgconfig:${SYSROOT}/usr/lib/${PKG_CONFIG_ARCH_PATH}/pkgconfig:${SYSROOT}/usr/lib/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "\${CMAKE_SYSROOT}")

# Recherche : programmes sur le HOST, libs/includes dans le sysroot TARGET
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH "\${CMAKE_SYSROOT}")
EOF

    echo -e "${GREEN}  toolchain.cmake généré : $TOOLCHAIN_FILE${NC}"
    echo -e "${GREEN}  Sysroot    : $SYSROOT${NC}"
    echo -e "${GREEN}  Compilateur: $CXX_CROSS${NC}"
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
        MYSQL_LIB_FOUND=$(find "$SYSROOT" \
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
# Téléchargement sources Qt 6
# ==============================================================================
download_qt_sources() {
    echo -e "${GREEN}=== Téléchargement sources Qt ${QT_VERSION} ===${NC}"
    executer_locale "mkdir -p $QT_SRC_DIR"

    # qtbase
    local ARCHIVE="qtbase-everywhere-src-${QT_VERSION}.tar.xz"
    if [ ! -d "$QT_SRC_DIR/qtbase-everywhere-src-${QT_VERSION}" ]; then
        echo -e "${GREEN}  Téléchargement qtbase...${NC}"
        executer_locale "wget '$QT_BASE_DOWNLOAD_URL/$ARCHIVE' \
            -O $QT_SRC_DIR/$ARCHIVE"
        executer_locale "cd $QT_SRC_DIR && tar xfv $ARCHIVE && rm $ARCHIVE"
    else
        echo -e "${GREEN}  qtbase déjà présent.${NC}"
    fi

    # Modules superrepo
    for module in "${MODULES_TO_BUILD[@]}"; do
        # qtmqtt a un tag différent (version_short uniquement)
        if [ "$module" == "qtmqtt" ]; then
            continue
        fi
        local ARCHIVE="${module}-everywhere-src-${QT_VERSION}.tar.xz"
        if [ ! -d "$QT_SRC_DIR/${module}-everywhere-src-${QT_VERSION}" ]; then
            echo -e "${GREEN}  Téléchargement $module...${NC}"
            executer_locale "wget '$QT_BASE_DOWNLOAD_URL/$ARCHIVE' \
                -O $QT_SRC_DIR/$ARCHIVE"
            executer_locale "cd $QT_SRC_DIR && tar xfv $ARCHIVE && rm $ARCHIVE"
        else
            echo -e "${GREEN}  $module déjà présent.${NC}"
        fi
    done

    # qtmqtt : repo git externe, pas de tarball officiel Qt 6
    if [ ! -d "$QT_SRC_DIR/qtmqtt" ]; then
        echo -e "${GREEN}  Clonage qtmqtt (repo externe)...${NC}"
        executer_locale "cd $QT_SRC_DIR && \
            git clone https://code.qt.io/qt/qtmqtt.git \
            -b ${QT_VERSION_SHORT} --depth 1 qtmqtt"
    else
        echo -e "${GREEN}  qtmqtt déjà présent.${NC}"
    fi
}

# ==============================================================================
# BUILD HOST — qtbase + qtshadertools pour x86_64
# Obligatoire en Qt 6 : fournit moc, rcc, qmake, qt-configure-module, etc.
# ==============================================================================
build_qt_host() {
    echo -e "${GREEN}=== BUILD HOST (x86_64) ===${NC}"
    echo -e "${GREEN}    Fournit les outils de build pour la cross-compilation${NC}"

    # --- qtbase host ---
    if [ ! -f "$QT_HOST_INSTALL/bin/qmake" ]; then
        executer_locale "mkdir -p $QT_HOST_BUILD/qtbase"
        executer_locale "rm -rf $QT_HOST_BUILD/qtbase/*"

        executer_locale "
            cd $QT_HOST_BUILD/qtbase && \
            cmake $QT_SRC_DIR/qtbase-everywhere-src-${QT_VERSION} \
                -GNinja \
                -DCMAKE_BUILD_TYPE=Release \
                -DQT_BUILD_EXAMPLES=OFF \
                -DQT_BUILD_TESTS=OFF \
                -DCMAKE_INSTALL_PREFIX=$QT_HOST_INSTALL
        "
        executer_locale "cmake --build $QT_HOST_BUILD/qtbase --parallel $(nproc)"
        executer_locale "cmake --install $QT_HOST_BUILD/qtbase"
        echo -e "${GREEN}  qtbase host installé : $QT_HOST_INSTALL${NC}"
    else
        echo -e "${GREEN}  qtbase host déjà compilé.${NC}"
    fi

    # --- qtshadertools host ---
    # Requis pour compiler qtdeclarative (QML shaders)
    if [ ! -f "$QT_HOST_INSTALL/lib/cmake/Qt6ShaderTools/Qt6ShaderToolsConfig.cmake" ]; then
        local SHADERTOOLS_SRC="$QT_SRC_DIR/qtshadertools-everywhere-src-${QT_VERSION}"
        executer_locale "mkdir -p $QT_HOST_BUILD/qtshadertools"
        executer_locale "rm -rf $QT_HOST_BUILD/qtshadertools/*"
        executer_locale "
            cd $QT_HOST_BUILD/qtshadertools && \
            $QT_HOST_INSTALL/bin/qt-configure-module $SHADERTOOLS_SRC && \
            cmake --build . --parallel $(nproc) && \
            cmake --install .
        "
        echo -e "${GREEN}  qtshadertools host installé.${NC}"
    else
        echo -e "${GREEN}  qtshadertools host déjà compilé.${NC}"
    fi
}

# ==============================================================================
# BUILD TARGET qtbase — QMYSQL + SQLite activés ici
# ==============================================================================
build_qt_target_base() {
    echo -e "${GREEN}=== BUILD TARGET qtbase (${ARCH_BITS} bits) ===${NC}"
    echo -e "${GREEN}    SQL : -DQT_FEATURE_sql_sqlite=ON -DQT_FEATURE_sql_mysql=ON${NC}"

    # Résoudre le chemin exact de libmariadb.so pour CMake
    local MYSQL_LIB_PATH="$MYSQL_LIBDIR/libmariadb.so"
    if [ ! -f "$MYSQL_LIB_PATH" ]; then
        MYSQL_LIB_PATH=$(find "$SYSROOT" \
            -name "libmariadb*.so*" 2>/dev/null | head -1)
    fi
    echo -e "${GREEN}  MySQL lib CMake : $MYSQL_LIB_PATH${NC}"

    executer_locale "mkdir -p $QT_TARGET_BUILD/qtbase"
    executer_locale "rm -rf $QT_TARGET_BUILD/qtbase/*"

    executer_locale "
        cd $QT_TARGET_BUILD/qtbase && \
        cmake $QT_SRC_DIR/qtbase-everywhere-src-${QT_VERSION} \
            -GNinja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN_FILE \
            -DQT_HOST_PATH=$QT_HOST_INSTALL \
            -DQT_HOST_PATH_CMAKE_DIR=$QT_HOST_INSTALL/lib/cmake \
            -DCMAKE_STAGING_PREFIX=$QT_TARGET_STAGING \
            -DCMAKE_INSTALL_PREFIX=$QT_TARGET_PREFIX \
            -DINPUT_opengl=es2 \
            -DQT_BUILD_EXAMPLES=OFF \
            -DQT_BUILD_TESTS=OFF \
            -DQT_FEATURE_eglfs=ON \
            -DQT_FEATURE_eglfs_egldevice=ON \
            -DQT_FEATURE_kms=ON \
            -DQT_FEATURE_linuxfb=ON \
            -DQT_FEATURE_xcb=ON \
            -DFEATURE_xcb_xlib=ON \
            -DQT_FEATURE_xlib=ON \
            -DQT_FEATURE_sql_sqlite=ON \
            -DQT_FEATURE_sql_mysql=ON \
            -DMySQL_INCLUDE_DIR=$MYSQL_INCDIR \
            -DMySQL_LIBRARY=$MYSQL_LIB_PATH \
            -DQT_QMAKE_TARGET_MKSPEC=devices/$QT_DEVICE_MK
    "

    executer_locale "cmake --build $QT_TARGET_BUILD/qtbase --parallel $(nproc)"
    executer_locale "cmake --install $QT_TARGET_BUILD/qtbase"

    # Vérification plugins SQL produits
    echo -e "${GREEN}=== Vérification plugins SQL ===${NC}"
    find "$QT_TARGET_STAGING" -name "libqsqlmysql*" 2>/dev/null | head -3 \
        && echo -e "${GREEN}  [OK] libqsqlmysql trouvé${NC}" \
        || echo -e "${RED}  [KO] libqsqlmysql ABSENT — vérifiez les logs CMake${NC}"
    find "$QT_TARGET_STAGING" -name "libqsqlite*" 2>/dev/null | head -3 \
        && echo -e "${GREEN}  [OK] libqsqlite trouvé${NC}" \
        || echo -e "${RED}  [KO] libqsqlite ABSENT${NC}"

    # Vérification qmake généré
    echo -e "${GREEN}=== Vérification qmake ===${NC}"
    find "$QT_TARGET_STAGING" -name "qmake*" 2>/dev/null | head -3 \
        && echo -e "${GREEN}  [OK] qmake présent${NC}" \
        || echo -e "${YELLOW}  [INFO] qmake non trouvé dans staging${NC}"
}

# ==============================================================================
# BUILD TARGET — module Qt supplémentaire
# ==============================================================================
build_qt_target_module() {
    local MODULE="$1"
    local SRC_PATH="$2"

    echo -e "${YELLOW}--- BUILD TARGET : $MODULE ---${NC}"

    executer_locale "mkdir -p $QT_TARGET_BUILD/$MODULE"
    executer_locale "rm -rf $QT_TARGET_BUILD/$MODULE/*"

    executer_locale "
        cd $QT_TARGET_BUILD/$MODULE && \
        $QT_TARGET_STAGING/bin/qt-configure-module $SRC_PATH && \
        cmake --build . --parallel $(nproc) && \
        cmake --install .
    "
    echo -e "${GREEN}  $MODULE : OK${NC}"
}

# ==============================================================================
# ==============================================================================
# DÉBUT DU SCRIPT PRINCIPAL
# ==============================================================================
# ==============================================================================

echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}  Cross-compilation Qt ${QT_VERSION} + QMYSQL + SQLite      ${NC}"
echo -e "${YELLOW}  Hôte   : Ubuntu 22.04 x86_64                              ${NC}"
echo -e "${YELLOW}  Cible  : Raspberry Pi 4 Bookworm 32 ou 64 bits            ${NC}"
echo -e "${YELLOW}  Build  : CMake + Ninja (qmake généré automatiquement)     ${NC}"
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
    echo -e "${GREEN}Clé publique déjà présente.${NC}"
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
    | grep "browser_download_url.*${DEB_ARCH_PKG}.deb" | cut -d '"' -f 4)
if [ -n "$WIRINGPI_URL" ]; then
    echo -e "${BLUE}  URL : $WIRINGPI_URL${NC}"
    executer_distante "wget -O /tmp/wiringpi.deb '$WIRINGPI_URL'"
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" \
        "sudo dpkg -i /tmp/wiringpi.deb ; \
         sudo apt-get install -f -y && \
         rm -f /tmp/wiringpi.deb && echo '  WiringPi OK'"
    [ $? -ne 0 ] && { echo -e "${RED}Echec WiringPi.${NC}"; exit 1; }
else
    echo -e "${YELLOW}  Aucun paquet WiringPi ${DEB_ARCH_PKG} — ignoré.${NC}"
fi

# --- deb-src ---
executer_distante \
    "sudo grep -q '^#deb-src' /etc/apt/sources.list && \
     sudo sed -i '/^#deb-src/s/^#//' /etc/apt/sources.list || true"

executer_distante "sudo apt update && sudo apt upgrade -y"

# --- Dépendances Qt 6 sur le RPi ---
echo -e "${BLUE}--- Dépendances Qt 6 ---${NC}"
executer_distante "
    sudo apt install -y \
        libfontconfig1-dev libharfbuzz-dev libdbus-1-dev \
        libfreetype6-dev libicu-dev libinput-dev \
        libxkbcommon-dev libxkbcommon-x11-dev \
        libxcb1-dev libxcb-cursor-dev libxcb-glx0-dev \
        libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev \
        libxcb-randr0-dev libxcb-render-util0-dev libxcb-shape0-dev \
        libxcb-shm0-dev libxcb-sync-dev libxcb-util-dev \
        libxcb-xfixes0-dev libxcb-xinerama0-dev libxcb-xkb-dev \
        libxcb-xinput-dev \
        libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev \
        libxi-dev libxrender-dev libxrandr-dev \
        libegl1-mesa-dev libgles2-mesa-dev libgbm-dev \
        libglu1-mesa-dev mesa-common-dev libdrm-dev \
        libpng-dev libjpeg-dev libzstd-dev zlib1g-dev \
        libssl-dev libsqlite3-dev \
        libts-dev libmtdev-dev libudev-dev gdbserver \
        libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev \
        gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
        libopenal-dev libasound2-dev libpulse-dev \
        bluez-tools libbluetooth-dev libffi-dev
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
    sudo mkdir -p $QT_TARGET_PREFIX
    sudo chown $RPI_USER:$RPI_USER $QT_TARGET_PREFIX
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
        [ -d '$SYM_SRC' ] \
            && /tmp/SSymlinker -s '$SYM_SRC' -d /usr/include \
                && echo '  [OK]   $SYM_SRC' \
                || echo '  [WARN] Lien existant : $SYM_SRC' \
            || echo '  [SKIP] Absent : $SYM_SRC'
    "
done
for SYM_SRC in \
    "/usr/lib/$PKG_CONFIG_ARCH_PATH/crtn.o" \
    "/usr/lib/$PKG_CONFIG_ARCH_PATH/crt1.o" \
    "/usr/lib/$PKG_CONFIG_ARCH_PATH/crti.o"; do
    SYM_DST="/usr/lib/$(basename $SYM_SRC)"
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "
        [ -f '$SYM_SRC' ] \
            && /tmp/SSymlinker -s '$SYM_SRC' -d '$SYM_DST' \
                && echo '  [OK]   $SYM_SRC' \
                || echo '  [WARN] Lien existant : $SYM_SRC' \
            || echo '  [SKIP] Absent : $SYM_SRC'
    "
done

# ==============================================================================
# Partie 2 : Configuration PC Ubuntu hôte
# ==============================================================================
echo -e "${GREEN}=== Partie 2 : Configuration PC Ubuntu ===${NC}"

executer_locale "sudo apt update && sudo apt dist-upgrade -y"
executer_locale "sudo apt install -y \
    build-essential git wget curl \
    cmake ninja-build pkg-config \
    python3 python-is-python3 \
    gperf bison flex \
    gdb-multiarch \
    libssl-dev \
    libxkbcommon-dev libxkbcommon-x11-dev \
    libx11-xcb-dev libglu1-mesa-dev \
    libxrender-dev libxi-dev"
executer_locale "sudo apt-get install -y '^libxcb.*-dev'"

# Vérification cmake >= 3.19
CMAKE_VER=$(cmake --version | head -1 | grep -oP '\d+\.\d+\.\d+')
CMAKE_MAJOR=$(echo "$CMAKE_VER" | cut -d. -f1)
CMAKE_MINOR=$(echo "$CMAKE_VER" | cut -d. -f2)
if [ "$CMAKE_MAJOR" -lt 3 ] || \
   ([ "$CMAKE_MAJOR" -eq 3 ] && [ "$CMAKE_MINOR" -lt 19 ]); then
    echo -e "${RED}cmake $CMAKE_VER insuffisant (< 3.19) !${NC}"
    echo -e "${RED}Installez cmake >= 3.19 manuellement puis relancez.${NC}"
    exit 1
fi
echo -e "${GREEN}  cmake $CMAKE_VER : OK${NC}"

executer_locale "mkdir -p \
    $QT_SRC_DIR \
    $QT_HOST_BUILD \
    $QT_HOST_INSTALL \
    $QT_TARGET_BUILD \
    $QT_TARGET_STAGING \
    $SYSROOT/usr \
    $SYSROOT/opt"
executer_locale "sudo chown -R $LOCAL_USER:$LOCAL_GROUP $CROSS_DIR"

install_cross_toolchain

# ==============================================================================
# Partie 3 : Synchronisation sysroot depuis le RPi
# APRÈS installation MariaDB (Partie 1)
# ==============================================================================
echo -e "${GREEN}=== Partie 3 : Synchronisation sysroot ===${NC}"
echo -e "${GREEN}    (headers MariaDB inclus dans ce rsync)${NC}"

executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
    $RPI_USER@$RPI_HOST:/lib $SYSROOT"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
    $RPI_USER@$RPI_HOST:/usr/include $SYSROOT/usr"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
    $RPI_USER@$RPI_HOST:/usr/lib $SYSROOT/usr"

if ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "[ -d /opt/vc ]"; then
    executer_locale "rsync -avz --rsync-path='sudo rsync' --delete \
        $RPI_USER@$RPI_HOST:/opt/vc $SYSROOT/opt/" || \
        executer_locale "scp -r $RPI_USER@$RPI_HOST:/opt/vc $SYSROOT/opt/"
else
    echo -e "${GREEN}/opt/vc absent (normal sur Bookworm).${NC}"
    executer_locale "mkdir -p $SYSROOT/opt/vc"
fi

executer_locale "wget '$RELATIVE_LINKS_SCRIPT_URL' -O $CROSS_DIR/relative_links.py"
executer_locale "chmod +x $CROSS_DIR/relative_links.py"
executer_locale "$CROSS_DIR/relative_links.py $SYSROOT"

verify_mysql_sysroot
generate_toolchain_cmake

# ==============================================================================
# Partie 4 : Téléchargement sources Qt 6
# ==============================================================================
download_qt_sources

# ==============================================================================
# Partie 5 : Build HOST (x86_64)
# Fournit moc, rcc, qmake, qt-configure-module pour la cross-compilation
# ==============================================================================
build_qt_host

# ==============================================================================
# Partie 6 : Build TARGET qtbase — avec QMYSQL + SQLite
# ==============================================================================
build_qt_target_base

# ==============================================================================
# Partie 7 : Build TARGET modules supplémentaires
# ==============================================================================
echo -e "${YELLOW}=== Partie 7 : BUILD TARGET modules ===${NC}"

for module in "${MODULES_TO_BUILD[@]}"; do
    # qtshadertools et qtbase déjà compilés
    [ "$module" == "qtshadertools" ] && continue

    MODULE_ENTRY="${QT_MODULES[$module]}"
    url="${MODULE_ENTRY%%|*}"
    version="${MODULE_ENTRY##*|}"

    # Chemin source : tarball extrait ou clone git
    if [ "$module" == "qtmqtt" ]; then
        SRC_PATH="$QT_SRC_DIR/qtmqtt"
    else
        SRC_PATH="$QT_SRC_DIR/${module}-everywhere-src-${QT_VERSION}"
    fi

    if [ ! -d "$SRC_PATH" ]; then
        echo -e "${RED}Sources manquantes : $SRC_PATH${NC}"
        exit 1
    fi

    build_qt_target_module "$module" "$SRC_PATH"
done

# ==============================================================================
# Partie 8 : Déploiement sur le RPi
# ==============================================================================
echo -e "${GREEN}=== Partie 8 : Déploiement sur le RPi ===${NC}"

executer_locale "rsync -avz --rsync-path='sudo rsync' \
    $QT_TARGET_STAGING/ $RPI_USER@$RPI_HOST:$QT_TARGET_PREFIX"

executer_distante "
    echo '$QT_TARGET_PREFIX/lib' | sudo tee /etc/ld.so.conf.d/qt6pi.conf
    sudo ldconfig
    if ! grep -q '$QT_TARGET_PREFIX/bin' ~/.bashrc 2>/dev/null; then
        echo 'export PATH=\$PATH:$QT_TARGET_PREFIX/bin' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$QT_TARGET_PREFIX/lib' >> ~/.bashrc
    fi
    echo ''
    echo '--- Plugins SQL déployés ---'
    find $QT_TARGET_PREFIX/plugins/sqldrivers -name 'libqsql*' 2>/dev/null \
        || echo 'Plugins sqldrivers non trouvés'
    echo ''
    echo '--- Runtime libmariadb ---'
    ldconfig -p | grep mariadb || echo 'libmariadb non trouvée dans ldconfig'
    echo ''
    echo '--- qmake ---'
    $QT_TARGET_PREFIX/bin/qmake --version 2>/dev/null \
        || echo 'qmake non trouvé dans PATH'
"

# ==============================================================================
# Résumé final
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Qt ${QT_VERSION} + QMYSQL + SQLite installés !            ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Architecture   : ${ARCH_BITS} bits (${PKG_CONFIG_ARCH_PATH})${NC}"
echo -e "${GREEN}  Qt host        : $QT_HOST_INSTALL                          ${NC}"
echo -e "${GREEN}  Qt staging PC  : $QT_TARGET_STAGING                        ${NC}"
echo -e "${GREEN}  Qt sur RPi     : $QT_TARGET_PREFIX                         ${NC}"
echo -e "${GREEN}  toolchain.cmake: $TOOLCHAIN_FILE                           ${NC}"
echo ""
echo -e "${YELLOW}  Qt Creator — cross-compilation :                          ${NC}"
echo -e "${YELLOW}    Toolchain cmake :                                        ${NC}"
echo -e "${YELLOW}      $TOOLCHAIN_FILE                                        ${NC}"
echo -e "${YELLOW}    Qt version (target) :                                    ${NC}"
echo -e "${YELLOW}      $QT_TARGET_STAGING/lib/cmake/Qt6/qt.toolchain.cmake   ${NC}"
echo -e "${YELLOW}    qmake (target) :                                         ${NC}"
echo -e "${YELLOW}      $QT_TARGET_STAGING/bin/qmake                          ${NC}"
echo ""
echo -e "${YELLOW}  Dans votre CMakeLists.txt :                                ${NC}"
echo -e "${YELLOW}    find_package(Qt6 REQUIRED COMPONENTS Core Sql)          ${NC}"
echo -e "${YELLOW}    target_link_libraries(monapp PRIVATE Qt6::Core Qt6::Sql)${NC}"
echo ""
echo -e "${YELLOW}  Dans votre .pro (qmake) :                                  ${NC}"
echo -e "${YELLOW}    QT += sql                                                ${NC}"
echo ""
echo -e "${YELLOW}  Vérifier les drivers au runtime :                         ${NC}"
echo -e "${YELLOW}    qDebug() << QSqlDatabase::drivers();                    ${NC}"
echo -e "${YELLOW}    // Attendu : (\"QSQLITE\", \"QMYSQL\")                 ${NC}"
echo ""
echo -e "${YELLOW}  Connexion MySQL distante :                                 ${NC}"
echo -e "${YELLOW}    QSqlDatabase db = QSqlDatabase::addDatabase(\"QMYSQL\");${NC}"
echo -e "${YELLOW}    db.setHostName(\"ip_serveur\"); db.setPort(3306);        ${NC}"
echo -e "${YELLOW}    db.setUserName(\"user\"); db.setPassword(\"mdp\");       ${NC}"
echo -e "${YELLOW}    db.setDatabaseName(\"ma_base\"); db.open();             ${NC}"
echo ""
echo -e "${YELLOW}  Connexion SQLite :                                         ${NC}"
echo -e "${YELLOW}    QSqlDatabase db = QSqlDatabase::addDatabase(\"QSQLITE\");${NC}"
echo -e "${YELLOW}    db.setDatabaseName(\"/chemin/ma_base.db\"); db.open();  ${NC}"
echo -e "${GREEN}============================================================${NC}"

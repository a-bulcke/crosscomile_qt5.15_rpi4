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
#                     fournit moc, rcc, qmake, qt-configure-module
#   2. BUILD TARGET : tous les modules cross-compilés pour ARM
#                     ce qui sera déployé sur le RPi
#
# Corrections v3 :
#   - toolchain.cmake : syntaxe PKG_CONFIG_* corrigée (plus de ENV{})
#   - ninja-build ajouté aux dépendances PC Ubuntu
#   - Détection architecture via dpkg (priorité sur uname)
#   - sudoers /usr/bin/rsync en dur, anti-doublon
#   - WiringPi dpkg non bloquant + apt-get -f
#   - SSymlinker : vérification existence avant lien
#   - MariaDB dev AVANT rsync sysroot
#   - URLs https:// + séparateur | pour les modules
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

QT_VERSION="6.10.0"
QT_VERSION_SHORT="6.10"

CROSS_DIR="$HOME/cross_rpi4_qt6"
QT_SRC_DIR="$CROSS_DIR/src"

QT_HOST_BUILD="$CROSS_DIR/host-build"
QT_HOST_INSTALL="$CROSS_DIR/host"

QT_TARGET_BUILD="$CROSS_DIR/target-build"
QT_TARGET_STAGING="$CROSS_DIR/target"
QT_TARGET_PREFIX="/usr/local/qt6"

SYSROOT="$CROSS_DIR/sysroot"
TOOLCHAIN_FILE="$CROSS_DIR/toolchain.cmake"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

QT_BASE_DOWNLOAD_URL="https://download.qt.io/official_releases/qt/${QT_VERSION_SHORT}/${QT_VERSION}/submodules"
SYM_LINKER_URL="https://raw.githubusercontent.com/abhiTronix/raspberry-pi-cross-compilers/master/utils/SSymlinker"

# Variables remplies dynamiquement par detect_rpi_arch()
ARCH_BITS=""
CROSS_COMPILE_PREFIX=""
CMAKE_SYSTEM_PROCESSOR=""
PKG_CONFIG_ARCH_PATH=""
QT_DEVICE_MK=""
CMAKE_MARCH=""
MYSQL_INCDIR=""
MYSQL_LIBDIR=""

# ==============================================================================
# Modules Qt 6 — séparateur | pour éviter conflit avec : dans https://
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
    ["qtmqtt"]="https://code.qt.io/qt/qtmqtt.git|${QT_VERSION}"
)

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
# RPi OS Bookworm 32 bits : uname=aarch64 mais dpkg=armhf
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
    echo -e "${YELLOW}  Qt device       : $QT_DEVICE_MK${NC}"
    echo -e "${YELLOW}  CMAKE_MARCH     : $CMAKE_MARCH${NC}"
    echo -e "${YELLOW}  MYSQL_INCDIR    : $MYSQL_INCDIR${NC}"
    echo -e "${YELLOW}  MYSQL_LIBDIR    : $MYSQL_LIBDIR${NC}"
}

# ==============================================================================
# Installation toolchain croisée via apt
# ==============================================================================
# ==============================================================================
# Installation toolchain croisée via apt
#
# gcc-11 apt (arm-linux-gnueabihf) : utilisé pour compiler Qt 6
# Le triplet arm-linux-gnueabihf est compatible avec le sysroot Debian/Bookworm.
# ARM GNU toolchain (arm-none-linux-gnueabihf) est INCOMPATIBLE avec un sysroot
# Debian car les chemins de libs sont organisés sous arm-none-linux-gnueabihf/
# alors que Debian utilise arm-linux-gnueabihf/.
#
# Mkspec : linux-rasp-pi4-ubuntu-cross (créé par create_fixed_mkspec)
# Ce mkspec remplace linux-rasp-pi4-v3d-g++ dont les flags
# crypto-neon-fp-armv8 et mfloat-abi=hard via DISTRO_OPTS ne sont pas
# supportés par le toolchain cross apt.
# Flags remplacés par neon-vfpv4 + mfloat-abi=hard inline : équivalents
# fonctionnels pour Qt sur RPi4 Cortex-A72.
#
# Cohabitation Qt 5 / Qt 6 dans Qt Creator :
#   Kit Qt 5 → /usr/bin/arm-linux-gnueabihf-g++   (même toolchain apt)
#   Kit Qt 6 → /usr/bin/arm-linux-gnueabihf-g++   (même toolchain apt)
#   Les kits diffèrent par la Qt version et le mkspec, pas le compilateur.
# ==============================================================================

install_cross_toolchain() {
    echo -e "${GREEN}=== Installation toolchain croisée (apt) ===${NC}"
    echo -e "${GREEN}    arm-linux-gnueabihf : compatible sysroot Debian/Bookworm${NC}"

    if [ "$ARCH_BITS" -eq 64 ]; then
        executer_locale "sudo apt install -y \
            gcc-aarch64-linux-gnu \
            g++-aarch64-linux-gnu \
            binutils-aarch64-linux-gnu"
        echo -e "${GREEN}  $(aarch64-linux-gnu-gcc --version | head -1)${NC}"
        export CROSS_CC="/usr/bin/aarch64-linux-gnu-gcc"
        export CROSS_CXX="/usr/bin/aarch64-linux-gnu-g++"
    else
        executer_locale "sudo apt install -y \
            gcc-arm-linux-gnueabihf \
            g++-arm-linux-gnueabihf \
            binutils-arm-linux-gnueabihf"
        echo -e "${GREEN}  $(arm-linux-gnueabihf-gcc --version | head -1)${NC}"
        export CROSS_CC="/usr/bin/arm-linux-gnueabihf-gcc"
        export CROSS_CXX="/usr/bin/arm-linux-gnueabihf-g++"
    fi

    echo ""
    echo -e "${YELLOW}  Qt Creator — kit Qt 5 et Qt 6 utilisent le même compilateur :${NC}"
    echo -e "${YELLOW}    C++ : $CROSS_CXX${NC}"
    echo -e "${YELLOW}  Les kits se distinguent par :${NC}"
    echo -e "${YELLOW}    - La Qt version (qmake Qt5 vs Qt6)${NC}"
    echo -e "${YELLOW}    - Le mkspec (linux-rasp-pi4-v3d-g++ vs linux-rasp-pi4-ubuntu-cross)${NC}"
    echo -e "${YELLOW}    - Le sysroot (cross_rpi4 vs cross_rpi4_qt6)${NC}"
}

# ==============================================================================
# Génération toolchain.cmake — pointe sur le compilateur apt
# ==============================================================================
generate_toolchain_cmake() {
    echo -e "${GREEN}=== Génération toolchain.cmake (wiki Qt officiel) ===${NC}"

    if [ "$ARCH_BITS" -eq 64 ]; then
        CC_CROSS="/usr/bin/aarch64-linux-gnu-gcc"
        CXX_CROSS="/usr/bin/aarch64-linux-gnu-g++"
        QT_COMPILER_FLAGS="-march=armv8-a -mtune=cortex-a72"
        GL_ARCH_PATH="${SYSROOT}/usr/lib/aarch64-linux-gnu"
    else
        CC_CROSS="/usr/bin/arm-linux-gnueabihf-gcc"
        CXX_CROSS="/usr/bin/arm-linux-gnueabihf-g++"
        QT_COMPILER_FLAGS="-march=armv8-a -mtune=cortex-a72 -mfpu=neon-vfpv4 -mfloat-abi=hard"
        GL_ARCH_PATH="${SYSROOT}/usr/lib/arm-linux-gnueabihf"
    fi

    echo -e "${GREEN}  Compilateur C   : $CC_CROSS${NC}"
    echo -e "${GREEN}  Compilateur C++ : $CXX_CROSS${NC}"
    echo -e "${GREEN}  Version         : $($CC_CROSS --version | head -1)${NC}"
    echo -e "${GREEN}  Flags ARM       : $QT_COMPILER_FLAGS${NC}"

    cat > "$TOOLCHAIN_FILE" << EOF
cmake_minimum_required(VERSION 3.18)
include_guard(GLOBAL)

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(TARGET_SYSROOT ${SYSROOT})
set(CMAKE_SYSROOT \${TARGET_SYSROOT})

# Compilateurs croisés apt (triplet Debian — compatible sysroot Bookworm)
set(CMAKE_C_COMPILER   ${CC_CROSS})
set(CMAKE_CXX_COMPILER ${CXX_CROSS})

# Flags compilateur ARM RPi4 — injectés via cmake_initialize_per_config_variable
# (mécanisme officiel Qt, cf. wiki.qt.io/Cross-Compile_Qt_6_for_Raspberry_Pi)
set(QT_COMPILER_FLAGS         "${QT_COMPILER_FLAGS}")
set(QT_COMPILER_FLAGS_RELEASE "-O2 -pipe -DNDEBUG")
# --allow-shlib-undefined : symbs glibc/systemd résolus au runtime sur RPi
# -ldbus-1 : fix libdbus.a sd_listen_fds (wiki Qt Known Issues > Issue with libdbus)
set(QT_LINKER_FLAGS           "-Wl,-O1 -Wl,--hash-style=gnu -Wl,--as-needed -Wl,--allow-shlib-undefined -ldbus-1")

set(CMAKE_EXE_LINKER_FLAGS_INIT    "-Wl,--allow-shlib-undefined")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-Wl,--allow-shlib-undefined")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-Wl,--allow-shlib-undefined")

# pkg-config — pointe vers le sysroot, pas les libs hôte
# set(ENV{...}) : syntaxe correcte pour variables d'environnement CMake
set(ENV{PKG_CONFIG_PATH}        \$ENV{PKG_CONFIG_PATH}:${SYSROOT}/usr/lib/${PKG_CONFIG_ARCH_PATH}/pkgconfig)
set(ENV{PKG_CONFIG_LIBDIR}      /usr/lib/pkgconfig:/usr/share/pkgconfig/:${SYSROOT}/usr/lib/${PKG_CONFIG_ARCH_PATH}/pkgconfig:${SYSROOT}/usr/lib/pkgconfig)
set(ENV{PKG_CONFIG_SYSROOT_DIR} \${CMAKE_SYSROOT})

# Chemins de recherche — bibliothèques et headers dans le sysroot uniquement
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
set(CMAKE_BUILD_RPATH \${TARGET_SYSROOT})

# Injection des flags ARM via cmake_initialize_per_config_variable
# Cette fonction est appelée par CMake pour chaque variable de flags.
# Elle garantit que QT_COMPILER_FLAGS est appliqué à tous les fichiers
# compilés, y compris ceux des modules Qt tiers.
include(CMakeInitializeConfigs)

function(cmake_initialize_per_config_variable _PREFIX _DOCSTRING)
  if (_PREFIX MATCHES "CMAKE_(C|CXX|ASM)_FLAGS")
    set(CMAKE_\${CMAKE_MATCH_1}_FLAGS_INIT "\${QT_COMPILER_FLAGS}")
    foreach (config DEBUG RELEASE MINSIZEREL RELWITHDEBINFO)
      if (DEFINED QT_COMPILER_FLAGS_\${config})
        set(CMAKE_\${CMAKE_MATCH_1}_FLAGS_\${config}_INIT "\${QT_COMPILER_FLAGS_\${config}}")
      endif()
    endforeach()
  endif()
  if (_PREFIX MATCHES "CMAKE_(SHARED|MODULE|EXE)_LINKER_FLAGS")
    foreach (config SHARED MODULE EXE)
      set(CMAKE_\${config}_LINKER_FLAGS_INIT "\${QT_LINKER_FLAGS}")
    endforeach()
  endif()
  _cmake_initialize_per_config_variable(\${ARGV})
endfunction()

# Déclaration explicite des bibliothèques OpenGL/EGL/DRM/XCB
# (évite que CMake cherche les versions hôte x86 au lieu du sysroot ARM)
set(GL_INC_DIR  \${TARGET_SYSROOT}/usr/include)
set(GL_LIB_DIR  \${TARGET_SYSROOT}:\${TARGET_SYSROOT}/usr/lib/${PKG_CONFIG_ARCH_PATH}/:\${TARGET_SYSROOT}/usr:\${TARGET_SYSROOT}/usr/lib)

set(EGL_INCLUDE_DIR     \${GL_INC_DIR})
set(EGL_LIBRARY         ${GL_ARCH_PATH}/libEGL.so)

set(OPENGL_INCLUDE_DIR  \${GL_INC_DIR})
set(OPENGL_opengl_LIBRARY ${GL_ARCH_PATH}/libOpenGL.so)

set(GLESv2_INCLUDE_DIR  \${GL_INC_DIR})
set(GLESv2_LIBRARY      ${GL_ARCH_PATH}/libGLESv2.so)

set(gbm_INCLUDE_DIR     \${GL_INC_DIR})
set(gbm_LIBRARY         ${GL_ARCH_PATH}/libgbm.so)

set(Libdrm_INCLUDE_DIR  \${GL_INC_DIR})
set(Libdrm_LIBRARY      ${GL_ARCH_PATH}/libdrm.so)

set(XCB_XCB_INCLUDE_DIR \${GL_INC_DIR})
set(XCB_XCB_LIBRARY     ${GL_ARCH_PATH}/libxcb.so)
EOF

    # Vérification syntaxe ENV{ — doit être dans set(ENV{...})
    # On accepte set(ENV{...}) qui est la syntaxe correcte
    if grep -n 'ENV{' "$TOOLCHAIN_FILE" | grep -qv 'set(ENV{'; then
        echo -e "${RED}ERREUR : syntaxe ENV{ invalide dans toolchain.cmake !${NC}"
        grep -n 'ENV{' "$TOOLCHAIN_FILE" | grep -v 'set(ENV{'
        exit 1
    fi

    echo -e "${GREEN}  toolchain.cmake généré : $TOOLCHAIN_FILE${NC}"
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
# Vérification et correction libdbus-1.so dans le sysroot
# Wiki Qt Known Issues : libdbus.a statique requiert sd_listen_fds (libsystemd)
# Solution : s'assurer que libdbus-1.so (lien symbolique) est valide
# Si le .so est absent ou cassé, CMake utilise le .a statique → erreur link
# ==============================================================================
verify_fix_libdbus_sysroot() {
    echo -e "${GREEN}=== Vérification libdbus-1.so dans le sysroot ===${NC}"

    local DBUS_SO="$SYSROOT/usr/lib/$PKG_CONFIG_ARCH_PATH/libdbus-1.so"
    local DBUS_SO3=$(find "$SYSROOT/usr/lib/$PKG_CONFIG_ARCH_PATH"         -name "libdbus-1.so.3*" 2>/dev/null | head -1)

    if [ -e "$DBUS_SO" ]; then
        echo -e "${GREEN}  [OK] libdbus-1.so présent : $(ls -la $DBUS_SO)${NC}"
    else
        echo -e "${YELLOW}  libdbus-1.so absent ou lien cassé — correction...${NC}"
        if [ -n "$DBUS_SO3" ]; then
            local TARGET=$(basename "$DBUS_SO3")
            executer_locale "ln -sfv $TARGET $DBUS_SO"
            echo -e "${GREEN}  [OK] lien créé : libdbus-1.so → $TARGET${NC}"
        else
            echo -e "${RED}  [KO] libdbus-1.so.3 introuvable dans le sysroot !${NC}"
            echo -e "${RED}  Installez libdbus-1-dev sur le RPi puis relancez le rsync.${NC}"
            exit 1
        fi
    fi
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

    # Modules superrepo (tarballs officiels)
    for module in "${MODULES_TO_BUILD[@]}"; do
        [ "$module" == "qtmqtt" ] && continue
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

    # qtmqtt : repo git externe (pas de tarball officiel Qt 6)
    # IMPORTANT : utiliser le tag exact v${QT_VERSION} (pas la branche ${QT_VERSION_SHORT})
    # La branche pointe sur la dernière version de maintenance (ex: 6.10.3)
    # ce qui est incompatible avec Qt 6.10.0 compilé.
    if [ ! -d "$QT_SRC_DIR/qtmqtt" ]; then
        echo -e "${GREEN}  Clonage qtmqtt (repo externe, tag v${QT_VERSION})...${NC}"
        executer_locale "cd $QT_SRC_DIR && \
            git clone https://code.qt.io/qt/qtmqtt.git \
            -b v${QT_VERSION} --depth 1 qtmqtt"
    else
        echo -e "${GREEN}  qtmqtt déjà présent.${NC}"
    fi
}

# ==============================================================================
# BUILD HOST — qtbase + qtshadertools pour x86_64
# Obligatoire : fournit moc, rcc, qmake, qt-configure-module
# ==============================================================================
build_qt_host() {
    echo -e "${GREEN}=== BUILD HOST (x86_64) ===${NC}"
    echo -e "${GREEN}    Fournit les outils de build pour la cross-compilation${NC}"

    # qtbase host
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
        echo -e "${GREEN}  qtbase host : OK${NC}"
    else
        echo -e "${GREEN}  qtbase host déjà compilé.${NC}"
    fi

    # qtshadertools host — requis avant qtdeclarative
    local SHADERTOOLS_CMAKE="$QT_HOST_INSTALL/lib/cmake/Qt6ShaderTools/Qt6ShaderToolsConfig.cmake"
    if [ ! -f "$SHADERTOOLS_CMAKE" ]; then
        local SHADERTOOLS_SRC="$QT_SRC_DIR/qtshadertools-everywhere-src-${QT_VERSION}"
        executer_locale "mkdir -p $QT_HOST_BUILD/qtshadertools"
        executer_locale "rm -rf $QT_HOST_BUILD/qtshadertools/*"
        executer_locale "
            cd $QT_HOST_BUILD/qtshadertools && \
            $QT_HOST_INSTALL/bin/qt-configure-module $SHADERTOOLS_SRC && \
            cmake --build . --parallel $(nproc) && \
            cmake --install .
        "
        echo -e "${GREEN}  qtshadertools host : OK${NC}"
    else
        echo -e "${GREEN}  qtshadertools host déjà compilé.${NC}"
    fi

    # qtdeclarative host — requis pour fournir Qt6QmlTools au build target
    # Sans cela : "Failed to find host tool Qt6::qmlaotstats"
    local QDECL_HOST_CMAKE="$QT_HOST_INSTALL/lib/cmake/Qt6Qml/Qt6QmlConfig.cmake"
    if [ ! -f "$QDECL_HOST_CMAKE" ]; then
        local QDECL_SRC="$QT_SRC_DIR/qtdeclarative-everywhere-src-${QT_VERSION}"
        executer_locale "mkdir -p $QT_HOST_BUILD/qtdeclarative"
        executer_locale "rm -rf $QT_HOST_BUILD/qtdeclarative/*"
        executer_locale "
            cd $QT_HOST_BUILD/qtdeclarative && \
            $QT_HOST_INSTALL/bin/qt-configure-module $QDECL_SRC && \
            cmake --build . --parallel $(nproc) && \
            cmake --install .
        "
        echo -e "${GREEN}  qtdeclarative host : OK${NC}"
    else
        echo -e "${GREEN}  qtdeclarative host déjà compilé.${NC}"
    fi
}

# ==============================================================================
# BUILD TARGET qtbase — QMYSQL + SQLite
# ==============================================================================
build_qt_target_base() {
    echo -e "${GREEN}=== BUILD TARGET qtbase (${ARCH_BITS} bits) ===${NC}"
    echo -e "${GREEN}    SQL : -DQT_FEATURE_sql_sqlite=ON -DQT_FEATURE_sql_mysql=ON${NC}"

    # Résoudre le chemin exact de libmariadb.so
    local MYSQL_LIB_PATH="$MYSQL_LIBDIR/libmariadb.so"
    if [ ! -f "$MYSQL_LIB_PATH" ]; then
        MYSQL_LIB_PATH=$(find "$SYSROOT" \
            -name "libmariadb*.so*" 2>/dev/null | head -1)
    fi
    echo -e "${GREEN}  MySQL lib CMake : $MYSQL_LIB_PATH${NC}"

    # ------------------------------------------------------------------
    # Correction md4c : Qt 6 cherche la lib système md4c via son cmake
    # config. Sur Bookworm, libmd4c-html0 n'est pas un paquet séparé —
    # libmd4c-html.so.x est inclus dans libmd4c0. Le cmake config est
    # présent dans le sysroot mais référence un .so qui n'y est pas,
    # car le lien symbolique .so (sans version) n'est créé que par
    # libmd4c-dev, et le .so.x.x.x versioned est dans libmd4c0.
    #
    # Solution robuste : supprimer le cmake config md4c du sysroot.
    # Qt utilisera alors sa version bundled de md4c (toujours à jour).
    # ------------------------------------------------------------------
    echo -e "${GREEN}=== Correction md4c sysroot ===${NC}"
    local MD4C_CMAKE="$SYSROOT/usr/lib/$PKG_CONFIG_ARCH_PATH/cmake/md4c"
    if [ -d "$MD4C_CMAKE" ]; then
        echo -e "${YELLOW}  Suppression $MD4C_CMAKE${NC}"
        echo -e "${YELLOW}  → Qt utilisera sa version bundled de md4c${NC}"
        rm -rf "$MD4C_CMAKE"
        echo -e "${GREEN}  [OK] cmake config md4c supprimé du sysroot${NC}"
    else
        echo -e "${GREEN}  cmake config md4c absent — rien à faire${NC}"
    fi

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
            -DQT_QMAKE_TARGET_MKSPEC=devices/$QT_DEVICE_MK \
            "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined" \
            "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--allow-shlib-undefined"
    "

    executer_locale "cmake --build $QT_TARGET_BUILD/qtbase --parallel $(nproc)"
    executer_locale "cmake --install $QT_TARGET_BUILD/qtbase"

    # Vérification plugins SQL
    echo -e "${GREEN}=== Vérification plugins SQL ===${NC}"
    find "$QT_TARGET_STAGING" -name "libqsqlmysql*" 2>/dev/null | grep -q . \
        && echo -e "${GREEN}  [OK] libqsqlmysql trouvé${NC}" \
        || echo -e "${RED}  [KO] libqsqlmysql ABSENT${NC}"
    find "$QT_TARGET_STAGING" -name "libqsqlite*" 2>/dev/null | grep -q . \
        && echo -e "${GREEN}  [OK] libqsqlite trouvé${NC}" \
        || echo -e "${RED}  [KO] libqsqlite ABSENT${NC}"

    # Vérification qmake
    find "$QT_TARGET_STAGING" -name "qmake*" -type f 2>/dev/null | grep -q . \
        && echo -e "${GREEN}  [OK] qmake présent${NC}" \
        || echo -e "${YELLOW}  [INFO] qmake non trouvé dans staging${NC}"

}


# ==============================================================================
# Création mkspec compatible toolchain cross apt (gcc-11/gcc-12)
#
# linux-rasp-pi4-v3d-g++ utilise -mfpu=crypto-neon-fp-armv8 et -mfloat-abi=hard
# via DISTRO_OPTS → non supportés par le toolchain cross apt Ubuntu.
# Ce mkspec custom utilise neon-vfpv4 + mfloat-abi=hard inline.
# ==============================================================================
create_fixed_mkspec() {
    echo -e "${GREEN}=== Création mkspec compatible toolchain apt ===${NC}"

    local MKSPEC_BASE="$QT_TARGET_STAGING/mkspecs"
    local MKSPEC_DST="$MKSPEC_BASE/devices/linux-rasp-pi4-ubuntu-cross"
    local COMMON="$MKSPEC_BASE/devices/common"

    executer_locale "mkdir -p $MKSPEC_DST"

    cat > "$MKSPEC_DST/qmake.conf" << 'MKSPEC_EOF'
# mkspec Qt 6 RPi4 — toolchain cross apt Ubuntu (gcc-11/gcc-12)
# neon-vfpv4 remplace crypto-neon-fp-armv8 (non supporté apt cross)
# mfloat-abi=hard inline (pas via DISTRO_OPTS hard-float)

include(../common/linux_device_pre.conf)

QMAKE_LIBS_EGL         += -lEGL
QMAKE_LIBS_OPENGL_ES2  += -lGLESv2 -lEGL

QMAKE_CFLAGS            = -march=armv8-a -mtune=cortex-a72 -mfpu=neon-vfpv4 -mfloat-abi=hard
QMAKE_CXXFLAGS          = $$QMAKE_CFLAGS

# PAS de DISTRO_OPTS hard-float ni crypto-neon
# Wiki Qt Known Issues : supprimer crypto-neon-fp-armv8
#   et remplacer linux_arm_device_post.conf par linux_device_post.conf
DISTRO_OPTS            += deb-multi-arch

EGLFS_DEVICE_INTEGRATION = eglfs_kms

# linux_device_post.conf (sans _arm_) : n'injecte PAS mfloat-abi ni crypto-neon
# Conforme à la recommandation du wiki Qt officiel pour RPi
include(../common/linux_device_post.conf)
load(qt_config)
MKSPEC_EOF

    cat > "$MKSPEC_DST/qplatformdefs.h" << 'PLATDEF_EOF'
#include "../../linux-g++/qplatformdefs.h"
PLATDEF_EOF

    echo -e "${GREEN}  Mkspec créé : $MKSPEC_DST${NC}"
    grep "QMAKE_CFLAGS\|DISTRO_OPTS" "$MKSPEC_DST/qmake.conf" | sed 's/^/    /'

    # Note : on utilise linux_device_post.conf (sans _arm_) — wiki Qt Known Issues
    # → pas d'injection mfloat-abi=hard ni crypto-neon-fp-armv8
    # Pas besoin de patcher linux_arm_device_post.conf partagé

    echo ""
    echo -e "${YELLOW}  Mkspec Qt Creator (kit Qt 6) : devices/linux-rasp-pi4-ubuntu-cross${NC}"
}


# ==============================================================================
# BUILD TARGET — un module Qt supplémentaire
# ==============================================================================
build_qt_target_module() {
    local MODULE="$1"
    local SRC_PATH="$2"

    echo -e "${YELLOW}--- BUILD TARGET : $MODULE ---${NC}"

    executer_locale "mkdir -p $QT_TARGET_BUILD/$MODULE"
    executer_locale "rm -rf $QT_TARGET_BUILD/$MODULE/*"

    # qt-configure-module génère le CMakeLists racine puis appelle cmake.
    # Les flags -D doivent être passés à cmake APRÈS qt-configure-module
    # via --cmake-arg ou en surchargeant la cache cmake.
    # On utilise --cmake-arg pour passer QT_BUILD_TOOLS_WHEN_CROSSCOMPILING=OFF
    # qui évite de compiler les exécutables ARM (qml, qmlscene...) sur le PC hôte.
    # Le linker croisé ne peut pas les linker à cause de arc4random_buf@GLIBC_2.36
    # dans libexpat du sysroot Bookworm.
    executer_locale "
        cd $QT_TARGET_BUILD/$MODULE && \
        $QT_TARGET_STAGING/bin/qt-configure-module $SRC_PATH \
            -- -DQT_BUILD_TOOLS_WHEN_CROSSCOMPILING=OFF && \
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
        libavcodec-dev libavformat-dev libswscale-dev \
        libvpx-dev libsrtp2-dev libsnappy-dev \
        libnss3-dev libxss-dev libxtst-dev libpci-dev \
        libopenal-dev libasound2-dev libpulse-dev \
        bluez-tools libbluetooth-dev libffi-dev \
        libsystemd-dev
    sudo apt install -y '^libxcb.*-dev' || true
    # libmd4c : rendu Markdown dans Qt — DOIT être installé avant rsync
    # Sans cela cmake Qt6 target échoue : "md4c::md4c-html references .so but file does not exist"
    sudo apt install -y libmd4c-dev libmd4c-html0
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
    echo -e "${RED}cmake $CMAKE_VER insuffisant — Qt 6 nécessite >= 3.19${NC}"
    exit 1
fi
echo -e "${GREEN}  cmake $CMAKE_VER : OK${NC}"

# Vérification ninja
if ! command -v ninja &>/dev/null; then
    echo -e "${RED}ninja introuvable — installation...${NC}"
    executer_locale "sudo apt install -y ninja-build"
fi
echo -e "${GREEN}  ninja $(ninja --version) : OK${NC}"

executer_locale "mkdir -p \
    $QT_SRC_DIR \
    $QT_HOST_BUILD/qtbase \
    $QT_HOST_BUILD/qtshadertools \
    $QT_HOST_BUILD/qtdeclarative \
    $QT_HOST_INSTALL \
    $QT_TARGET_BUILD \
    $QT_TARGET_STAGING \
    $SYSROOT/usr \
    $SYSROOT/opt"
executer_locale "sudo chown -R $LOCAL_USER:$LOCAL_GROUP $CROSS_DIR"

install_cross_toolchain

# ==============================================================================
# Partie 3 : Synchronisation sysroot depuis le RPi
# APRÈS installation MariaDB (Partie 1) → headers inclus
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

# Corriger les symlinks absolus → relatifs avec l'outil `symlinks` (apt)
# Recommandé par le wiki Qt officiel — plus fiable que relative_links.py
executer_locale "sudo apt install -y symlinks"
executer_locale "symlinks -rc $SYSROOT"

verify_mysql_sysroot
verify_fix_libdbus_sysroot
generate_toolchain_cmake

# ==============================================================================
# Partie 4 : Téléchargement sources Qt 6
# ==============================================================================
download_qt_sources

# ==============================================================================
# Partie 5 : BUILD HOST (x86_64)
# ==============================================================================
build_qt_host

# ==============================================================================
# Partie 6 : BUILD TARGET qtbase + QMYSQL + SQLite
# ==============================================================================
build_qt_target_base

# ==============================================================================
# Partie 7 : BUILD TARGET modules supplémentaires
# ==============================================================================
echo -e "${YELLOW}=== Partie 7 : BUILD TARGET modules ===${NC}"

for module in "${MODULES_TO_BUILD[@]}"; do
    # qtshadertools doit être compilé pour le TARGET aussi
    # (build_qt_host le compile uniquement pour x86 host)

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

# Créer aussi le mkspec corrigé dans le staging final
# (au cas où des modules auraient écrasé le staging)

# Appel final create_fixed_mkspec (idempotent)
create_fixed_mkspec

# ==============================================================================
# Partie 8 : Déploiement sur le RPi
# ==============================================================================
echo -e "${GREEN}=== Partie 8 : Déploiement sur le RPi ===${NC}"

executer_locale "rsync -avz --rsync-path='sudo rsync' \
    $QT_TARGET_STAGING/ $RPI_USER@$RPI_HOST:$QT_TARGET_PREFIX"

executer_distante "
    echo '$QT_TARGET_PREFIX/lib' | sudo tee /etc/ld.so.conf.d/qt6pi.conf
    sudo ldconfig
    grep -q '$QT_TARGET_PREFIX/bin' ~/.bashrc 2>/dev/null || {
        echo 'export PATH=\$PATH:$QT_TARGET_PREFIX/bin' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$QT_TARGET_PREFIX/lib' >> ~/.bashrc
    }
    echo ''
    echo '--- Plugins SQL déployés ---'
    find $QT_TARGET_PREFIX/plugins/sqldrivers -name 'libqsql*' 2>/dev/null \
        || echo 'Dossier sqldrivers non trouvé'
    echo ''
    echo '--- Runtime libmariadb ---'
    ldconfig -p | grep mariadb || echo 'libmariadb non trouvée'
    echo ''
    echo '--- qmake ---'
    $QT_TARGET_PREFIX/bin/qmake --version 2>/dev/null || echo 'qmake non trouvé'
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
echo -e "${YELLOW}  Qt Creator — paramètres cross-compilation :               ${NC}"
echo -e "${YELLOW}    Toolchain cmake :                                        ${NC}"
echo -e "${YELLOW}      $TOOLCHAIN_FILE                                        ${NC}"
echo -e "${YELLOW}    Qt version (CMake) :                                     ${NC}"
echo -e "${YELLOW}      $QT_TARGET_STAGING/lib/cmake/Qt6/qt.toolchain.cmake   ${NC}"
echo -e "${YELLOW}    qmake (projets .pro) :                                   ${NC}"
echo -e "${YELLOW}      $QT_TARGET_STAGING/bin/qmake                          ${NC}"
echo ""
echo -e "${YELLOW}  CMakeLists.txt :                                           ${NC}"
echo -e "${YELLOW}    find_package(Qt6 REQUIRED COMPONENTS Core Sql)          ${NC}"
echo -e "${YELLOW}    target_link_libraries(app PRIVATE Qt6::Core Qt6::Sql)   ${NC}"
echo ""
echo -e "${YELLOW}  Fichier .pro (qmake) :                                     ${NC}"
echo -e "${YELLOW}    QT += sql                                                ${NC}"
echo ""
echo -e "${YELLOW}  Vérifier les drivers au runtime :                         ${NC}"
echo -e "${YELLOW}    qDebug() << QSqlDatabase::drivers();                    ${NC}"
echo -e "${YELLOW}    // Attendu : (\"QSQLITE\", \"QMYSQL\")                 ${NC}"
echo ""
echo -e "${YELLOW}  qmake — compiler un projet .pro :${NC}"
echo -e "${YELLOW}    $QT_TARGET_STAGING/bin/qmake \\${NC}"
echo -e "${YELLOW}      -spec devices/linux-rasp-pi4-ubuntu-cross \\${NC}"
echo -e "${YELLOW}      votre_projet.pro${NC}"
echo -e "${YELLOW}    make -j\$(nproc)${NC}"
echo ""
echo -e "${YELLOW}  Qt Creator — kits recommandés :${NC}"
echo -e "${YELLOW}    Kit Qt 5.15.2 RPi4 :${NC}"
echo -e "${YELLOW}      Compilateur C++ : /usr/bin/arm-linux-gnueabihf-g++${NC}"
echo -e "${YELLOW}      Qt version      : ~/cross_rpi4/qt5pi/bin/qmake${NC}"
echo -e "${YELLOW}      Mkspec          : devices/linux-rasp-pi4-v3d-g++${NC}"
echo -e "${YELLOW}    Kit Qt 6.10 RPi4 :${NC}"
echo -e "${YELLOW}      Compilateur C++ : /usr/bin/arm-linux-gnueabihf-g++${NC}"
echo -e "${YELLOW}      Qt version      : $QT_TARGET_STAGING/bin/qmake${NC}"
echo -e "${YELLOW}      Mkspec          : devices/linux-rasp-pi4-ubuntu-cross${NC}"
echo -e "${YELLOW}      CMake toolchain : $TOOLCHAIN_FILE${NC}"
echo ""
echo -e "${YELLOW}  Connexion MySQL distante :${NC}"
echo -e "${YELLOW}    QSqlDatabase db = QSqlDatabase::addDatabase(\"QMYSQL\");${NC}"
echo -e "${YELLOW}    db.setHostName(\"ip_serveur\"); db.setPort(3306);        ${NC}"
echo -e "${YELLOW}    db.setUserName(\"user\"); db.setPassword(\"mdp\");       ${NC}"
echo -e "${YELLOW}    db.setDatabaseName(\"ma_base\"); db.open();             ${NC}"
echo ""
echo -e "${YELLOW}  Connexion SQLite :                                         ${NC}"
echo -e "${YELLOW}    QSqlDatabase db = QSqlDatabase::addDatabase(\"QSQLITE\");${NC}"
echo -e "${YELLOW}    db.setDatabaseName(\"/chemin/ma_base.db\"); db.open();  ${NC}"
echo -e "${GREEN}============================================================${NC}"

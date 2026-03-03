#!/bin/bash

# Codes de couleur
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================
# Configuration
# =============================================
RPI_USER="pi"
RPI_HOST="10.0.2.3"  # Remplacez par l'IP de votre RPi4
RPI_PORT="22"
LOCAL_USER=$(whoami)
LOCAL_GROUP=$(id -gn)
CROSS_DIR="$HOME/cross_rpi4"  # Variable pour le nom du dossier sur le PC hôte
TOOLCHAIN_URL_32="https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/arm-linux-gnueabihf/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf.tar.xz"
QT_SRC_URL="http://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz"
SYM_LINKER_URL="https://raw.githubusercontent.com/abhiTronix/raspberry-pi-cross-compilers/master/utils/SSymlinker"
RELATIVE_LINKS_SCRIPT_URL="https://raw.githubusercontent.com/riscv/riscv-poky/master/scripts/sysroot-relativelinks.py"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

# Ces variables seront définies dynamiquement par detect_rpi_arch()
ARCH_BITS=""
CROSS_COMPILE_PREFIX=""
QT_DEVICE=""
TOOLCHAIN_BIN=""
MKSPEC_SRC=""
MKSPEC_DST=""
LINARO_DIR=""

# =============================================
# Liste des modules Qt avec leurs versions
# Format : "nom_du_module" -> "url:version"
# =============================================
declare -A QT_MODULES=(
    ["qtbase"]="git://code.qt.io/qt/qtbase.git:5.15.2"
    ["qtxmlpatterns"]="git://code.qt.io/qt/qtxmlpatterns.git:5.15.2"
    ["qtsvg"]="git://code.qt.io/qt/qtsvg.git:5.15.2"
    ["qtdeclarative"]="git://code.qt.io/qt/qtdeclarative.git:5.15.2"
    ["qtimageformats"]="git://code.qt.io/qt/qtimageformats.git:5.15.2"
    ["qtgraphicaleffects"]="git://code.qt.io/qt/qtgraphicaleffects.git:5.15.2"
    ["qtquickcontrols"]="git://code.qt.io/qt/qtquickcontrols.git:5.15.2"
    ["qtquickcontrols2"]="git://code.qt.io/qt/qtquickcontrols2.git:5.15.2"
    ["qtvirtualkeyboard"]="git://code.qt.io/qt/qtvirtualkeyboard.git:5.15.2"
    ["qtwebsockets"]="git://code.qt.io/qt/qtwebsockets.git:5.15.2"
    ["qtwebglplugin"]="git://code.qt.io/qt/qtwebglplugin.git:5.15.2"
    ["qtcharts"]="git://code.qt.io/qt/qtcharts.git:5.15.2"
    ["qtconnectivity"]="git://code.qt.io/qt/qtconnectivity.git:5.15.2"
    ["qtmultimedia"]="git://code.qt.io/qt/qtmultimedia.git:5.15.2"
    ["qtlocation"]="git://code.qt.io/qt/qtlocation.git:5.15.2"
    ["qtmqtt"]="git://code.qt.io/qt/qtmqtt.git:5.15.2"
    ["qtserialport"]="git://code.qt.io/qt/qtserialport.git:5.15.2"
)

# Modules à compiler (décommentez ceux que vous voulez)
MODULES_TO_BUILD=(
#    "qtxmlpatterns"
#    "qtsvg"
    "qtdeclarative"
#    "qtimageformats"
#    "qtgraphicaleffects"
    "qtquickcontrols"
    "qtquickcontrols2"
    "qtvirtualkeyboard"
    "qtwebsockets"
#    "qtwebglplugin"
    "qtcharts"
    "qtconnectivity"
#    "qtmultimedia"
#    "qtlocation"
    "qtmqtt"
    "qtserialport"
)

# =============================================
# Fonctions utilitaires
# =============================================
executer_locale() {
    echo -e "${GREEN}[LOCAL] $1${NC}"
    eval "$1"
    if [ $? -ne 0 ]; then
        echo -e "${GREEN}Erreur lors de l'exécution locale : $1${NC}"
        exit 1
    fi
}

executer_distante() {
    echo -e "${BLUE}[SSH] Exécution sur $RPI_USER@$RPI_HOST:$RPI_PORT : $1${NC}"
    ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "$1"
    if [ $? -ne 0 ]; then
        echo -e "${BLUE}Erreur lors de l'exécution distante : $1${NC}"
        exit 1
    fi
}

# =============================================
# Détection de l'architecture du RPi
# =============================================
detect_rpi_arch() {
    echo -e "${YELLOW}=== Détection de l'architecture du RPi ===${NC}"

    RPI_ARCH=$(ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "uname -m" 2>/dev/null)

    if [ -z "$RPI_ARCH" ]; then
        echo -e "${YELLOW}ERREUR : Impossible de détecter l'architecture du RPi (connexion SSH échouée ?).${NC}"
        exit 1
    fi

    # Double vérification via dpkg pour distinguer armhf/arm64
    RPI_DEB_ARCH=$(ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "dpkg --print-architecture" 2>/dev/null)

    echo -e "${YELLOW}Architecture noyau  : $RPI_ARCH${NC}"
    echo -e "${YELLOW}Architecture Debian : $RPI_DEB_ARCH${NC}"

    if [[ "$RPI_ARCH" == "aarch64" ]] || [[ "$RPI_DEB_ARCH" == "arm64" ]]; then
        # ---- 64 bits ----
        ARCH_BITS=64
        CROSS_COMPILE_PREFIX="aarch64-linux-gnu-"
        # Qt 5.15.2 ne fournit pas de device pour aarch64 RPi4 en natif.
        # On utilise le device générique linux-aarch64-gnu-g++ et on crée le mkspec si besoin.
        QT_DEVICE="linux-aarch64-gnu-g++"
        TOOLCHAIN_BIN="/usr/bin"          # gcc-aarch64-linux-gnu installé via apt
        MKSPEC_SRC="linux-arm-gnueabi-g++" # Base pour créer le mkspec aarch64
        MKSPEC_DST="linux-aarch64-gnu-g++"
        LINARO_DIR=""                      # Pas de toolchain Linaro pour 64 bits
        echo -e "${YELLOW}>>> Mode 64 bits (aarch64) sélectionné.${NC}"

    elif [[ "$RPI_ARCH" == "armv7l" ]] || [[ "$RPI_ARCH" == "armv6l" ]] || [[ "$RPI_DEB_ARCH" == "armhf" ]]; then
        # ---- 32 bits ----
        ARCH_BITS=32
        CROSS_COMPILE_PREFIX="arm-linux-gnueabihf-"
        QT_DEVICE="linux-rasp-pi4-v3d-g++"
        LINARO_DIR="$CROSS_DIR/tools/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf"
        TOOLCHAIN_BIN="$LINARO_DIR/bin"
        MKSPEC_SRC="linux-arm-gnueabi-g++"
        MKSPEC_DST="linux-arm-gnueabihf-g++"
        echo -e "${YELLOW}>>> Mode 32 bits (armhf) sélectionné.${NC}"

    else
        echo -e "${YELLOW}ERREUR : Architecture non reconnue : $RPI_ARCH / $RPI_DEB_ARCH${NC}"
        exit 1
    fi

    echo -e "${YELLOW}=== Résumé architecture ===${NC}"
    echo -e "${YELLOW}  Bits              : ${ARCH_BITS}${NC}"
    echo -e "${YELLOW}  Cross-compile     : ${CROSS_COMPILE_PREFIX}${NC}"
    echo -e "${YELLOW}  Qt device         : ${QT_DEVICE}${NC}"
    echo -e "${YELLOW}  Toolchain bin     : ${TOOLCHAIN_BIN}${NC}"
}

# =============================================
# Vérification et gestion des versions de gcc/g++
# (uniquement nécessaire en 32 bits avec Linaro 7.4)
# =============================================
check_and_set_gcc_version() {
    if [ "$ARCH_BITS" -eq 64 ]; then
        echo -e "${YELLOW}=== 64 bits : vérification gcc/g++ système ignorée (Linaro non utilisé) ===${NC}"
        return 0
    fi

    echo -e "${YELLOW}=== Vérification des versions de gcc et g++ ===${NC}"

    # Sauvegarder les versions originales
    ORIGINAL_GCC=$(ls -l /usr/bin/gcc 2>/dev/null | awk '{print $NF}' | grep -oP '\d+(\.\d+)*$' | head -1)
    ORIGINAL_GPP=$(ls -l /usr/bin/g++ 2>/dev/null | awk '{print $NF}' | grep -oP '\d+(\.\d+)*$' | head -1)

    echo -e "${YELLOW}Version originale de gcc : $ORIGINAL_GCC${NC}"
    echo -e "${YELLOW}Version originale de g++ : $ORIGINAL_GPP${NC}"

    GCC_VERSION=$(gcc --version | head -n1 | grep -oP '\d+' | head -1)
    GPP_VERSION=$(g++ --version | head -n1 | grep -oP '\d+' | head -1)

    echo -e "${YELLOW}Version majeure gcc : $GCC_VERSION${NC}"
    echo -e "${YELLOW}Version majeure g++ : $GPP_VERSION${NC}"

    if [ "$GCC_VERSION" -ge 11 ] || [ "$GPP_VERSION" -ge 11 ]; then
        echo -e "${YELLOW}Version 11+ détectée, installation de gcc-9 et g++-9 pour compatibilité Qt 5.15...${NC}"
        executer_locale "sudo apt update"
        executer_locale "sudo apt install -y gcc-9 g++-9"
        executer_locale "sudo ln -s -f /usr/bin/gcc-9 /usr/bin/gcc"
        executer_locale "sudo ln -s -f /usr/bin/g++-9 /usr/bin/g++"

        NEW_GCC_VERSION=$(gcc --version | head -n1)
        NEW_GPP_VERSION=$(g++ --version | head -n1)
        echo -e "${YELLOW}Nouvelles versions actives :${NC}"
        echo -e "${YELLOW}  $NEW_GCC_VERSION${NC}"
        echo -e "${YELLOW}  $NEW_GPP_VERSION${NC}"
    else
        echo -e "${YELLOW}Les versions de gcc/g++ sont compatibles (< 11).${NC}"
    fi
}

# =============================================
# Rétablir les versions originales de gcc/g++
# =============================================
restore_gcc_version() {
    if [ "$ARCH_BITS" -eq 64 ]; then
        return 0
    fi

    echo -e "${YELLOW}=== Rétablissement des versions originales de gcc/g++ ===${NC}"

    if [ -n "$ORIGINAL_GCC" ]; then
        executer_locale "sudo ln -s -f /usr/bin/gcc-$ORIGINAL_GCC /usr/bin/gcc"
        executer_locale "sudo ln -s -f /usr/bin/g++-$ORIGINAL_GPP /usr/bin/g++"
        echo -e "${YELLOW}Versions rétablies : gcc-$ORIGINAL_GCC / g++-$ORIGINAL_GPP${NC}"
    else
        echo -e "${YELLOW}Aucune version originale à rétablir.${NC}"
    fi
}

# =============================================
# Téléchargement/installation de la toolchain
# =============================================
check_and_download_toolchain() {
    echo -e "${GREEN}=== Préparation de la toolchain ===${NC}"

    if [ "$ARCH_BITS" -eq 64 ]; then
        # 64 bits : utiliser le paquet apt Ubuntu
        echo -e "${GREEN}Installation de la toolchain aarch64 via apt...${NC}"
        executer_locale "sudo apt update"
        executer_locale "sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu"

        # Vérification
        if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
            echo -e "${GREEN}ERREUR : aarch64-linux-gnu-gcc introuvable après installation.${NC}"
            exit 1
        fi
        echo -e "${GREEN}Toolchain aarch64 installée : $(aarch64-linux-gnu-gcc --version | head -1)${NC}"

    else
        # 32 bits : toolchain Linaro
        LINARO_ARCHIVE="$CROSS_DIR/tools/toolchain.tar.xz"

        if [ -d "$LINARO_DIR" ]; then
            echo -e "${GREEN}La toolchain Linaro est déjà présente : $LINARO_DIR${NC}"
        else
            echo -e "${GREEN}Téléchargement de la toolchain Linaro 7.4.1 (armhf)...${NC}"
            executer_locale "mkdir -p $CROSS_DIR/tools"
            executer_locale "wget $TOOLCHAIN_URL_32 -O $LINARO_ARCHIVE"

            if [ -f "$LINARO_ARCHIVE" ]; then
                echo -e "${GREEN}Décompression de la toolchain Linaro...${NC}"
                executer_locale "cd $CROSS_DIR/tools && tar xfv $LINARO_ARCHIVE"

                if [ -d "$LINARO_DIR" ]; then
                    echo -e "${GREEN}Toolchain Linaro décompressée avec succès.${NC}"
                    executer_locale "rm $LINARO_ARCHIVE"
                else
                    echo -e "${GREEN}ERREUR : La décompression a échoué (dossier attendu : $LINARO_DIR).${NC}"
                    exit 1
                fi
            else
                echo -e "${GREEN}ERREUR : Le téléchargement de la toolchain Linaro a échoué.${NC}"
                exit 1
            fi
        fi
    fi
}

# =============================================
# Création du mkspec Qt pour aarch64 (64 bits uniquement)
# Qt 5.15.2 ne fournit pas de device linux-aarch64-gnu-g++ natif.
# On crée un mkspec générique basé sur linux-arm-gnueabi-g++.
# =============================================
create_aarch64_mkspec() {
    if [ "$ARCH_BITS" -ne 64 ]; then
        return 0
    fi

    local MKSPECS_DIR="$CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs"
    local DST_DIR="$MKSPECS_DIR/$MKSPEC_DST"

    if [ -d "$DST_DIR" ]; then
        echo -e "${GREEN}Le mkspec $MKSPEC_DST existe déjà.${NC}"
        return 0
    fi

    echo -e "${GREEN}Création du mkspec Qt pour aarch64 : $MKSPEC_DST${NC}"
    executer_locale "cp -R $MKSPECS_DIR/linux-arm-gnueabi-g++ $DST_DIR"

    # Adapter qmake.conf pour aarch64
    cat > /tmp/qmake_aarch64.conf << 'EOF'
#
# qmake configuration for building with aarch64-linux-gnu-g++
#

MAKEFILE_GENERATOR      = UNIX
CONFIG                 += incremental
QMAKE_INCREMENTAL_STYLE = sublib

include(../common/linux.conf)
include(../common/gcc-base-unix.conf)
include(../common/g++-unix.conf)

# modifications to g++.conf
QMAKE_CC                = aarch64-linux-gnu-gcc
QMAKE_CXX               = aarch64-linux-gnu-g++
QMAKE_LINK              = aarch64-linux-gnu-g++
QMAKE_LINK_SHLIB        = aarch64-linux-gnu-g++

# modifications to linux.conf
QMAKE_AR                = aarch64-linux-gnu-ar cqs
QMAKE_OBJCOPY           = aarch64-linux-gnu-objcopy
QMAKE_NM                = aarch64-linux-gnu-nm -P
QMAKE_STRIP             = aarch64-linux-gnu-strip

load(qt_config)
EOF

    executer_locale "cp /tmp/qmake_aarch64.conf $DST_DIR/qmake.conf"
    echo -e "${GREEN}mkspec aarch64 créé avec succès dans $DST_DIR${NC}"
}

# =============================================
# Début du script principal
# =============================================

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  Cross-compilation Qt 5.15.2 pour RPi4 ${NC}"
echo -e "${YELLOW}========================================${NC}"

# =============================================
# Génération et copie de la clé SSH
# =============================================
echo -e "${GREEN}=== Vérification et configuration de la clé SSH ===${NC}"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${GREEN}Génération d'une nouvelle clé SSH...${NC}"
    executer_locale "ssh-keygen -t rsa -f $SSH_KEY_PATH -N ''"
else
    echo -e "${GREEN}La clé SSH existe déjà : $SSH_KEY_PATH${NC}"
fi

if ! ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "grep -q \"\$(cat $SSH_KEY_PATH.pub)\" ~/.ssh/authorized_keys" 2>/dev/null; then
    echo -e "${GREEN}Copie de la clé publique sur le RPi4...${NC}"
    executer_locale "ssh-copy-id -i $SSH_KEY_PATH.pub -p $RPI_PORT $RPI_USER@$RPI_HOST"
else
    echo -e "${GREEN}La clé publique est déjà présente sur le RPi4.${NC}"
fi

# =============================================
# Détection de l'architecture — DOIT être fait
# avant toute autre étape
# =============================================
detect_rpi_arch

# =============================================
# Partie 1 : Configuration du RPi4
# =============================================
echo -e "${BLUE}=== Configuration de la RPi4 ===${NC}"

# Installation de WiringPi (armhf uniquement — pas de paquet armhf sur 64 bits)
if [ "$ARCH_BITS" -eq 32 ]; then
    echo -e "${BLUE}=== Installation de WiringPi (32 bits) ===${NC}"

    WIRINGPI_DEB_URL=$(curl -s https://api.github.com/repos/WiringPi/WiringPi/releases/latest \
        | grep "browser_download_url.*armhf.deb" | cut -d '"' -f 4)

    if [ -z "$WIRINGPI_DEB_URL" ]; then
        echo "Impossible de récupérer l'URL du fichier .deb armhf de WiringPi."
        exit 1
    fi

    echo "URL WiringPi armhf : $WIRINGPI_DEB_URL"
    executer_distante "
        wget -O /tmp/wiringpi-latest.deb '$WIRINGPI_DEB_URL'
        sudo dpkg -i /tmp/wiringpi-latest.deb
        sudo apt-get install -f -y
        rm /tmp/wiringpi-latest.deb
        echo 'WiringPi installé avec succès !'
    "
else
    echo -e "${BLUE}=== Installation de WiringPi (64 bits / arm64) ===${NC}"

    WIRINGPI_DEB_URL=$(curl -s https://api.github.com/repos/WiringPi/WiringPi/releases/latest \
        | grep "browser_download_url.*arm64.deb" | cut -d '"' -f 4)

    if [ -z "$WIRINGPI_DEB_URL" ]; then
        echo -e "${BLUE}Pas de paquet arm64 WiringPi disponible, installation ignorée.${NC}"
    else
        echo "URL WiringPi arm64 : $WIRINGPI_DEB_URL"
        executer_distante "
            wget -O /tmp/wiringpi-latest.deb '$WIRINGPI_DEB_URL'
            sudo dpkg -i /tmp/wiringpi-latest.deb
            sudo apt-get install -f -y
            rm /tmp/wiringpi-latest.deb
            echo 'WiringPi arm64 installé avec succès !'
        "
    fi
fi

# Décommenter les sources deb-src
executer_distante "
    if sudo grep -q '^#deb-src' /etc/apt/sources.list; then
        sudo sed -i '/^#deb-src/s/^#//' /etc/apt/sources.list
        echo 'Ligne deb-src décommentée.'
    else
        echo 'Aucune ligne deb-src commentée trouvée.'
    fi
"

# Mise à jour et dépendances communes sur le RPi
executer_distante "
    sudo apt update && sudo apt upgrade -y
    sudo apt-get build-dep -y qt5-qmake libqt5gui5 libqt5webengine-data libqt5webkit5
    sudo apt install -y libudev-dev libinput-dev libts-dev libxcb-xinerama0-dev libxcb-xinerama0 gdbserver
    sudo apt install -y qtbase5-dev qtchooser qtbase5-dev-tools
    sudo apt install -y libegl1-mesa libegl1-mesa-dev libgles2-mesa libgles2-mesa-dev libgbm-dev mesa-common-dev
    sudo apt install -y '^libxcb.*-dev' libx11-xcb-dev libglu1-mesa-dev libxrender-dev libxi-dev libxkbcommon-dev libxkbcommon-x11-dev
    sudo apt install -y fonts-texgyre libts-dev
    sudo apt install -y gstreamer1.0-plugins* libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libopenal-data libsndio7.0 libopenal1 libopenal-dev pulseaudio
    sudo apt install -y bluez-tools libbluetooth-dev
    sudo gpasswd -a $RPI_USER render
    sudo mkdir -p /usr/local/qt5.15
    sudo chown $RPI_USER:$RPI_USER /usr/local/qt5.15
    echo '$LOCAL_USER ALL=NOPASSWD:$(which rsync)' | sudo tee --append /etc/sudoers
"

# Télécharger et exécuter SSymlinker
executer_distante "
    wget $SYM_LINKER_URL -O /tmp/SSymlinker
    sudo chmod +x /tmp/SSymlinker
    /tmp/SSymlinker -s /usr/include/arm-linux-gnueabihf/asm -d /usr/include
    /tmp/SSymlinker -s /usr/include/arm-linux-gnueabihf/gnu -d /usr/include
    /tmp/SSymlinker -s /usr/include/arm-linux-gnueabihf/bits -d /usr/include
    /tmp/SSymlinker -s /usr/include/arm-linux-gnueabihf/sys -d /usr/include
    /tmp/SSymlinker -s /usr/include/arm-linux-gnueabihf/openssl -d /usr/include
    /tmp/SSymlinker -s /usr/lib/arm-linux-gnueabihf/crtn.o -d /usr/lib/crtn.o
    /tmp/SSymlinker -s /usr/lib/arm-linux-gnueabihf/crt1.o -d /usr/lib/crt1.o
    /tmp/SSymlinker -s /usr/lib/arm-linux-gnueabihf/crti.o -d /usr/lib/crti.o
"

# =============================================
# Partie 2 : Configuration du PC Ubuntu (hôte)
# =============================================
echo -e "${GREEN}=== Configuration du PC Ubuntu ===${NC}"

executer_locale "sudo apt update"
executer_locale "sudo apt dist-upgrade -y"
executer_locale "sudo apt install -y build-essential cmake unzip gfortran gcc git bison python3 python-is-python3 gperf pkg-config gdb-multiarch wget curl"
executer_locale "sudo apt-get install -y gcc g++ gperf flex texinfo gawk bison openssl pigz libncurses-dev autoconf automake tar figlet"
executer_locale "sudo apt-get install -y '^libxcb.*-dev' libx11-xcb-dev libglu1-mesa-dev libxrender-dev libxi-dev libxkbcommon-dev libxkbcommon-x11-dev"

# Création des répertoires
executer_locale "mkdir -p $CROSS_DIR/build $CROSS_DIR/tools $CROSS_DIR/sysroot/usr $CROSS_DIR/sysroot/opt"
executer_locale "sudo chown -R $LOCAL_USER:$LOCAL_GROUP $CROSS_DIR"

# Installation/téléchargement de la toolchain selon l'architecture
check_and_download_toolchain

# Gestion de la version gcc hôte (uniquement 32 bits)
check_and_set_gcc_version

# =============================================
# Synchronisation du sysroot depuis le RPi4
# =============================================
echo -e "${GREEN}=== Synchronisation du sysroot depuis le RPi4 ===${NC}"

executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/lib $CROSS_DIR/sysroot"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/usr/include $CROSS_DIR/sysroot/usr"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/usr/lib $CROSS_DIR/sysroot/usr"

if ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "[ -d /opt/vc ]"; then
    echo -e "${GREEN}Le dossier /opt/vc existe sur le RPi4, copie en cours...${NC}"
    executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/opt/vc $CROSS_DIR/sysroot/opt/" || {
        echo -e "${GREEN}rsync a échoué pour /opt/vc, tentative via scp...${NC}"
        executer_locale "scp -r $RPI_USER@$RPI_HOST:/opt/vc $CROSS_DIR/sysroot/opt/"
    }
else
    echo -e "${GREEN}Le dossier /opt/vc n'existe pas sur le RPi4, création d'un dossier vide.${NC}"
    executer_locale "mkdir -p $CROSS_DIR/sysroot/opt/vc"
fi

# Correction des liens symboliques relatifs
executer_locale "cd $CROSS_DIR && wget $RELATIVE_LINKS_SCRIPT_URL -O relative_links.py"
executer_locale "cd $CROSS_DIR && chmod +x relative_links.py"
executer_locale "cd $CROSS_DIR && ./relative_links.py sysroot"

# =============================================
# Partie 3 : Compilation croisée de Qt 5.15.2
# =============================================
echo -e "${GREEN}=== Compilation croisée de Qt 5.15.2 (${ARCH_BITS} bits) ===${NC}"

# Télécharger les sources Qt si pas déjà présentes
if [ ! -d "$CROSS_DIR/qt-everywhere-src-5.15.2" ]; then
    executer_locale "cd $CROSS_DIR && wget $QT_SRC_URL -O qt-src.tar.xz"
    executer_locale "cd $CROSS_DIR && tar xfv qt-src.tar.xz"
    executer_locale "rm $CROSS_DIR/qt-src.tar.xz"
else
    echo -e "${GREEN}Les sources Qt 5.15.2 sont déjà présentes.${NC}"
fi

# Création du mkspec adapté selon l'architecture
if [ "$ARCH_BITS" -eq 32 ]; then
    # 32 bits : copier linux-arm-gnueabi-g++ → linux-arm-gnueabihf-g++
    if [ ! -d "$CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs/$MKSPEC_DST" ]; then
        executer_locale "cp -R $CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs/$MKSPEC_SRC \
            $CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs/$MKSPEC_DST"
        executer_locale "sed -i -e 's/arm-linux-gnueabi-/arm-linux-gnueabihf-/g' \
            $CROSS_DIR/qt-everywhere-src-5.15.2/qtbase/mkspecs/$MKSPEC_DST/qmake.conf"
    else
        echo -e "${GREEN}Le mkspec $MKSPEC_DST existe déjà.${NC}"
    fi
else
    # 64 bits : créer un mkspec aarch64 personnalisé
    create_aarch64_mkspec
fi

# Nettoyage du répertoire de build
executer_locale "rm -rf $CROSS_DIR/build && mkdir -p $CROSS_DIR/build"

# Configuration Qt — options communes
QT_CONFIGURE_COMMON="
    -release -opengl es2 -eglfs -no-feature-eglfs_brcm \
    -bundled-xcb-xinput \
    -device $QT_DEVICE \
    -device-option CROSS_COMPILE=$TOOLCHAIN_BIN/$CROSS_COMPILE_PREFIX \
    -sysroot $CROSS_DIR/sysroot \
    -prefix /usr/local/qt5.15 \
    -extprefix $CROSS_DIR/qt5.15 \
    -opensource -confirm-license \
    -skip qtscript -skip qtwayland -skip qtwebengine \
    -nomake tests -make libs \
    -pkg-config -no-use-gold-linker -v -recheck
"

echo -e "${GREEN}Configuration Qt pour ${ARCH_BITS} bits (device: $QT_DEVICE)...${NC}"
executer_locale "cd $CROSS_DIR/build && ../qt-everywhere-src-5.15.2/configure $QT_CONFIGURE_COMMON"

echo -e "${GREEN}Compilation Qt (make -j$(nproc))...${NC}"
executer_locale "cd $CROSS_DIR/build && make -j$(nproc)"

echo -e "${GREEN}Installation Qt dans $CROSS_DIR/qt5.15...${NC}"
executer_locale "cd $CROSS_DIR/build && make install"

# =============================================
# Partie 4 : Compilation des modules Qt supplémentaires
# =============================================
echo -e "${YELLOW}=== Compilation des modules Qt supplémentaires ===${NC}"

for module in "${MODULES_TO_BUILD[@]}"; do
    MODULE_ENTRY="${QT_MODULES[$module]}"
    if [ -z "$MODULE_ENTRY" ]; then
        echo -e "${YELLOW}AVERTISSEMENT : Module '$module' non trouvé dans QT_MODULES, ignoré.${NC}"
        continue
    fi

    # Extraire URL et version
    url="${MODULE_ENTRY%%:*}"          # tout avant le premier ':'
    # La version est la partie après le dernier ':'  (git: compte aussi)
    version="${MODULE_ENTRY##*:}"

    echo -e "${YELLOW}--- Module : $module (v$version) ---${NC}"

    if [ ! -d "$CROSS_DIR/$module" ]; then
        executer_locale "cd $CROSS_DIR && git clone $url -b v$version --depth 1 $module"
    else
        echo -e "${YELLOW}Le module $module est déjà cloné.${NC}"
    fi

    executer_locale "
        cd $CROSS_DIR/$module && \
        $CROSS_DIR/qt5.15/bin/qmake && \
        make -j$(nproc) && \
        make install
    "
done

# =============================================
# Partie 5 : Déploiement sur le RPi4
# =============================================
echo -e "${GREEN}=== Déploiement de Qt 5.15 sur le RPi4 ===${NC}"
executer_locale "rsync -avz --rsync-path='sudo rsync' $CROSS_DIR/qt5.15 $RPI_USER@$RPI_HOST:/usr/local"

executer_distante "
    echo '/usr/local/qt5.15/lib' | sudo tee /etc/ld.so.conf.d/qt5pi.conf
    sudo ldconfig
"

# Rétablir gcc hôte si modifié (32 bits uniquement)
restore_gcc_version

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Qt 5.15.2 terminée !     ${NC}"
echo -e "${GREEN}  Architecture cible : ${ARCH_BITS} bits  ${NC}"
echo -e "${GREEN}  Cross-compile prefix : ${CROSS_COMPILE_PREFIX}  ${NC}"
echo -e "${GREEN}========================================${NC}"

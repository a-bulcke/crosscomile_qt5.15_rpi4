#!/bin/bash

# Codes de couleur
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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
TOOLCHAIN_URL="https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/arm-linux-gnueabihf/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf.tar.xz"
QT_SRC_URL="http://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz"
SYM_LINKER_URL="https://raw.githubusercontent.com/abhiTronix/raspberry-pi-cross-compilers/master/utils/SSymlinker"
RELATIVE_LINKS_SCRIPT_URL="https://raw.githubusercontent.com/riscv/riscv-poky/master/scripts/sysroot-relativelinks.py"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

# Liste des modules Qt disponibles
# =============================================
# Liste des modules Qt avec leurs versions souhaitées
# Format : "nom_du_module:version"
# Exemple : "qtbase:5.15.2" ou "qtbase:5.15"
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
# Fonctions utilitaires (avec couleurs)
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
# Vérification et gestion des versions de gcc/g++
# =============================================
check_and_set_gcc_version() {
    echo -e "${YELLOW}=== Vérification des versions de gcc et g++ ===${NC}"

    # Sauvegarder les versions originales
    ORIGINAL_GCC=$(ls -l /usr/bin/gcc | awk '{print $NF}' | cut -d'-' -f2-)
    ORIGINAL_GPP=$(ls -l /usr/bin/g++ | awk '{print $NF}' | cut -d'-' -f2-)

    echo -e "${YELLOW}Version originale de gcc : $ORIGINAL_GCC${NC}"
    echo -e "${YELLOW}Version originale de g++ : $ORIGINAL_GPP${NC}"

    # Vérifier les versions actuelles
    GCC_VERSION=$(gcc --version | head -n1 | cut -d' ' -f3 | cut -d'.' -f1)
    GPP_VERSION=$(g++ --version | head -n1 | cut -d' ' -f3 | cut -d'.' -f1)

    echo -e "${YELLOW}Version actuelle de gcc : $GCC_VERSION${NC}"
    echo -e "${YELLOW}Version actuelle de g++ : $GPP_VERSION${NC}"

    # Si gcc ou g++ est en version 11 ou supérieure, installer la version 9
    if [ "$GCC_VERSION" -ge 11 ] || [ "$GPP_VERSION" -ge 11 ]; then
        echo -e "${YELLOW}Version 11 ou supérieure détectée, installation de gcc-9 et g++-9...${NC}"
        executer_locale "sudo apt update"
        executer_locale "sudo apt install -y gcc-9 g++-9"

        # Créer les liens symboliques
        executer_locale "sudo ln -s -f /usr/bin/gcc-9 /usr/bin/gcc"
        executer_locale "sudo ln -s -f /usr/bin/g++-9 /usr/bin/g++"

        # Vérifier les nouvelles versions
        NEW_GCC_VERSION=$(gcc --version | head -n1 | cut -d' ' -f3)
        NEW_GPP_VERSION=$(g++ --version | head -n1 | cut -d' ' -f3)
        echo -e "${YELLOW}Nouvelles versions : gcc $NEW_GCC_VERSION, g++ $NEW_GPP_VERSION${NC}"
    else
        echo -e "${YELLOW}Les versions de gcc/g++ sont compatibles (inférieures à 11).${NC}"
    fi
}

# =============================================
# Rétablir les versions originales de gcc/g++
# =============================================
restore_gcc_version() {
    echo -e "${YELLOW}=== Rétablissement des versions originales de gcc/g++ ===${NC}"

    if [ -n "$ORIGINAL_GCC" ]; then
        executer_locale "sudo ln -s -f /usr/bin/gcc-$ORIGINAL_GCC /usr/bin/gcc"
        executer_locale "sudo ln -s -f /usr/bin/g++-$ORIGINAL_GPP /usr/bin/g++"

        # Vérifier les versions rétablies
        RESTORED_GCC_VERSION=$(gcc --version | head -n1)
        RESTORED_GPP_VERSION=$(g++ --version | head -n1)
        echo -e "${YELLOW}Versions rétablies :$NC"
        echo -e "${YELLOW}$RESTORED_GCC_VERSION$NC"
        echo -e "${YELLOW}$RESTORED_GPP_VERSION$NC"
    else
        echo -e "${YELLOW}Aucune version à rétablir.${NC}"
    fi
}

# =============================================
# Vérification et téléchargement de la toolchain Linaro
# =============================================
check_and_download_linaro() {
    LINARO_DIR="$CROSS_DIR/tools/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf"
    LINARO_TAR="$CROSS_DIR/tools/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf.tar.xz"

    echo -e "${GREEN}=== Vérification de la toolchain Linaro ===${NC}"

    # Vérifier si le dossier Linaro existe déjà
    if [ -d "$LINARO_DIR" ]; then
        echo -e "${GREEN}La toolchain Linaro est déjà décompressée : $LINARO_DIR${NC}"
    else
        echo -e "${GREEN}Téléchargement de la toolchain Linaro...${NC}"
        executer_locale "mkdir -p $CROSS_DIR/tools"
        executer_locale "cd $CROSS_DIR/tools && wget $TOOLCHAIN_URL -O toolchain.tar.xz"

        # Vérifier si le fichier .tar.xz a été téléchargé
        if [ -f "$CROSS_DIR/tools/toolchain.tar.xz" ]; then
            echo -e "${GREEN}Décompression de la toolchain Linaro...${NC}"
            executer_locale "cd $CROSS_DIR/tools && tar xfv toolchain.tar.xz"

            # Vérifier si la décompression a réussi
            if [ -d "$LINARO_DIR" ]; then
                echo -e "${GREEN}Toolchain Linaro décompressée avec succès.${NC}"
                executer_locale "rm $CROSS_DIR/tools/toolchain.tar.xz"  # Nettoyer le fichier téléchargé
            else
                echo -e "${GREEN}Erreur : La décompression de la toolchain Linaro a échoué.${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}Erreur : Le téléchargement de la toolchain Linaro a échoué.${NC}"
            exit 1
        fi
    fi
}


# =============================================
# Début du script
# =============================================


# =============================================
# Génération et copie de la clé SSH (si nécessaire)
# =============================================
echo -e "${GREEN}=== Vérification et configuration de la clé SSH ===${NC}"

# Vérifier si la clé SSH existe déjà localement
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${GREEN}Génération d'une nouvelle clé SSH...${NC}"
    executer_locale "ssh-keygen -t rsa -f $SSH_KEY_PATH -N ''"
else
    echo -e "${GREEN}La clé SSH existe déjà : $SSH_KEY_PATH${NC}"
fi

# Vérifier si la clé publique est déjà sur le RPi4
if ! ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "grep -q \"\$(cat $SSH_KEY_PATH.pub)\" ~/.ssh/authorized_keys" 2>/dev/null; then
    echo -e "${GREEN}Copie de la clé publique sur le RPi4...${NC}"
    executer_locale "ssh-copy-id -i $SSH_KEY_PATH.pub -p $RPI_PORT $RPI_USER@$RPI_HOST"
else
    echo -e "${GREEN}La clé publique est déjà présente sur le RPi4.${NC}"
fi

# =============================================
# Partie 1 : Configuration du RPi4
# =============================================
echo "=== Configuration de la RPi4 ==="

# =============================================
# Installation de WiringPi (32 bits)
# =============================================
echo -e "${BLUE}=== Installation de WiringPi ===${NC}"

# Récupérer l'URL du dernier fichier .deb armhf de WiringPi
WIRINGPI_DEB_URL=$(curl -s https://api.github.com/repos/WiringPi/WiringPi/releases/latest | grep "browser_download_url.*armhf.deb" | cut -d '"' -f 4)

if [ -z "$WIRINGPI_DEB_URL" ]; then
    echo "Impossible de récupérer l'URL du fichier .deb armhf de WiringPi."
    exit 1
fi

echo "URL du fichier .deb armhf de WiringPi : $WIRINGPI_DEB_URL"

executer_distante "
    echo 'Téléchargement du fichier .deb armhf de WiringPi...'
    wget -O /tmp/wiringpi-latest.deb '$WIRINGPI_DEB_URL'
    if [ $? -ne 0 ]; then
        echo 'Erreur lors du téléchargement du fichier .deb.'
        exit 1
    fi

    echo 'Installation via dpkg...'
    sudo dpkg -i /tmp/wiringpi-latest.deb
    sudo apt-get install -f -y
    rm /tmp/wiringpi-latest.deb
    echo 'WiringPi installé avec succès !'
"


# Décommenter la ligne deb-src
executer_distante "
    if sudo grep -q '^#deb-src' /etc/apt/sources.list; then
        sudo sed -i '/^#deb-src/s/^#//' /etc/apt/sources.list
        echo 'Ligne deb-src décommentée.'
    else
        echo 'Aucune ligne deb-src commentée trouvée.'
    fi
"

# Mise à jour et installation des dépendances
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
echo "=== Configuration du PC Ubuntu ==="

# Mise à jour et installation des dépendances locales
executer_locale "sudo apt update"
executer_locale "sudo apt dist-upgrade -y"
executer_locale "sudo apt install -y build-essential cmake unzip gfortran gcc git bison python3 python-is-python3 gperf pkg-config gdb-multiarch wget"
executer_locale "sudo apt-get install -y gcc g++ gperf flex texinfo gawk bison openssl pigz libncurses-dev autoconf automake tar figlet"
executer_locale "sudo apt-get install -y '^libxcb.*-dev' libx11-xcb-dev libglu1-mesa-dev libxrender-dev libxi-dev libxkbcommon-dev libxkbcommon-x11-dev"

# Création des répertoires
executer_locale "mkdir -p $CROSS_DIR/build $CROSS_DIR/tools $CROSS_DIR/sysroot/usr $CROSS_DIR/sysroot/opt"
executer_locale "sudo chown -R $LOCAL_USER:$LOCAL_GROUP $CROSS_DIR"

# Télécharger la toolchain si besoin
check_and_download_linaro

check_and_set_gcc_version

# =============================================
# Synchronisation des dossiers depuis la RPi4
# =============================================
echo -e "${GREEN}=== Synchronisation des dossiers depuis le ReTerminal ===${NC}"

# Copie des dossiers /lib, /usr/include, /usr/lib
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/lib $CROSS_DIR/sysroot"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/usr/include $CROSS_DIR/sysroot/usr"
executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/usr/lib $CROSS_DIR/sysroot/usr"

# Vérifier si /opt/vc existe sur RPi4
if ssh -p "$RPI_PORT" "$RPI_USER@$RPI_HOST" "[ -d /opt/vc ]"; then
    echo -e "${GREEN}Le dossier /opt/vc existe sur le ReTerminal, copie en cours...${NC}"
    executer_locale "rsync -avz --rsync-path='sudo rsync' --delete $RPI_USER@$RPI_HOST:/opt/vc $CROSS_DIR/sysroot/opt/" || {
        echo -e "${GREEN}rsync a échoué pour /opt/vc, utilisation de scp...${NC}"
        executer_locale "scp -r $RPI_USER@$RPI_HOST:/opt/vc $CROSS_DIR/sysroot/opt/"
    }
else
    echo -e "${GREEN}Le dossier /opt/vc n'existe pas sur le RPi4, création d'un dossier vide localement.${NC}"
    executer_locale "mkdir -p $CROSS_DIR/sysroot/opt/vc"
fi


# Télécharger et exécuter le script de liens relatifs
executer_locale "cd $CROSS_DIR && wget $RELATIVE_LINKS_SCRIPT_URL -O relative_links.py"
executer_locale "cd $CROSS_DIR && chmod +x relative_links.py"
executer_locale "cd $CROSS_DIR && ./relative_links.py sysroot"

# =============================================
# Partie 3 : Compilation croisée de Qt
# =============================================
echo "=== Compilation croisée de Qt 5.15.2 ==="

# Télécharger les sources de Qt
executer_locale "cd $CROSS_DIR && wget $QT_SRC_URL -O qt-src.tar.xz"
executer_locale "cd $CROSS_DIR && tar xfv qt-src.tar.xz"
executer_locale "cd $CROSS_DIR && cp -R qt-everywhere-src-5.15.2/qtbase/mkspecs/linux-arm-gnueabi-g++ qt-everywhere-src-5.15.2/qtbase/mkspecs/linux-arm-gnueabihf-g++"
executer_locale "cd $CROSS_DIR && sed -i -e 's/arm-linux-gnueabi-/arm-linux-gnueabihf-/g' qt-everywhere-src-5.15.2/qtbase/mkspecs/linux-arm-gnueabihf-g++/qmake.conf"

# Configuration et compilation de Qt base
executer_locale "
    cd $CROSS_DIR/build && \
    ../qt-everywhere-src-5.15.2/configure \
        -release -opengl es2 -eglfs -no-feature-eglfs_brcm \
        -bundled-xcb-xinput -device linux-rasp-pi4-v3d-g++ \
        -device-option CROSS_COMPILE=$CROSS_DIR/tools/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/bin/arm-linux-gnueabihf- \
        -sysroot $CROSS_DIR/sysroot \
        -prefix /usr/local/qt5.15 \
        -extprefix $CROSS_DIR/qt5.15 \
        -opensource -confirm-license \
        -skip qtscript -skip qtwayland -skip qtwebengine \
        -nomake tests -make libs \
        -pkg-config -no-use-gold-linker -v -recheck
"
executer_locale "cd $CROSS_DIR/build && make -j$(nproc)"
executer_locale "cd $CROSS_DIR/build && make install"

# =============================================
# Partie 4 : Compilation des modules Qt supplémentaires
# =============================================

echo -e "${YELLOW}=== Compilation des modules Qt supplémentaires ===${NC}"

for module in "${MODULES_TO_BUILD[@]}"; do
    # Extraire l'URL et la version du module
    IFS=':' read -r url version <<< "${QT_MODULES[$module]}"

    echo -e "${YELLOW}Compilation du module $module (version $version)...${NC}"

    # Vérifier si le module est déjà cloné
    if [ ! -d "$CROSS_DIR/$module" ]; then
        executer_locale "cd $CROSS_DIR && git clone $url -b v$version --depth 1"
    else
        echo -e "${YELLOW}Le module $module est déjà cloné.${NC}"
    fi

    # Compiler le module
    executer_locale "
        cd $CROSS_DIR/$module && \
        $CROSS_DIR/qt5.15/bin/qmake && \
        make -j$(nproc) && \
        make install
        "
    done

# =============================================
# Partie 5 : Déploiement sur le ReTerminal
# =============================================
echo "=== Déploiement sur le ReTerminal ==="
executer_locale "rsync -avz --rsync-path='sudo rsync' $CROSS_DIR/qt5.15 $RPI_USER@$RPI_HOST:/usr/local"

# Prise en compte des librairies Qt
executer_distante "
    echo '/usr/local/qt5.15/lib' | sudo tee /etc/ld.so.conf.d/qt5pi.conf
    sudo ldconfig
"
restore_gcc_version

echo "=== Installation terminée avec succès ! ==="

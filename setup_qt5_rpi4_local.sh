#!/bin/bash
# ==============================================================================
# setup_qt5_rpi4_local.sh
#
# Prépare l'environnement de cross-compilation Qt5.15 pour RPi4
# à partir d'une archive cross_rpi4_qt5.zip déjà téléchargée.
#
# Ce script :
#   1. Installe les paquets apt nécessaires
#   2. Extrait l'archive cross_rpi4_qt5.zip
#   3. Corrige les symlinks absolus du sysroot
#   4. Affiche les chemins à renseigner dans Qt Creator
#
# Usage :
#   Placer cross_rpi4_qt5.zip dans le même dossier que ce script, puis :
#   chmod +x setup_qt5_rpi4_local.sh
#   ./setup_qt5_rpi4_local.sh
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Répertoire d'installation (par défaut : $HOME)
INSTALL_DIR="$HOME"

# Nom du dossier après extraction
DIR_QT5="cross_rpi4_qt5"

# Chercher le zip dans le dossier du script, puis dans le dossier courant
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIP_PATH=""
for candidate in "$SCRIPT_DIR/cross_rpi4_qt5.zip" "$PWD/cross_rpi4_qt5.zip"; do
    [ -f "$candidate" ] && ZIP_PATH="$candidate" && break
done

# ==============================================================================
# COULEURS
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "${GREEN}  [OK] $*${NC}"; }
warn()  { echo -e "${YELLOW}  [WARN] $*${NC}"; }
err()   { echo -e "${RED}  [ERREUR] $*${NC}"; exit 1; }
titre() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ==============================================================================
# BANNIÈRE
# ==============================================================================
echo -e "${CYAN}"
echo "============================================================"
echo "  Setup cross-compilation Qt5.15.2 RPi4 — Ubuntu 22.04     "
echo "============================================================"
echo -e "${NC}"

# ==============================================================================
# PARTIE 1 : VÉRIFICATIONS
# ==============================================================================
titre "Vérifications préalables"

[ "$(uname -m)" = "x86_64" ] && ok "Architecture x86_64" \
    || err "Architecture $(uname -m) non supportée"

grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null \
    && ok "Ubuntu 22.04" \
    || warn "OS non Ubuntu 22.04 — résultats non garantis"

DISPO_GO=$(df -BG "$INSTALL_DIR" | awk 'NR==2{gsub("G",""); print $4}')
[ "$DISPO_GO" -ge 5 ] \
    && ok "Espace disque : ${DISPO_GO}Go disponibles" \
    || err "Espace insuffisant : ${DISPO_GO}Go (5Go minimum requis)"

[ -n "$ZIP_PATH" ] \
    && ok "Archive trouvée : $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))" \
    || err "cross_rpi4_qt5.zip introuvable — placez-le dans le même dossier que ce script"

# ==============================================================================
# PARTIE 2 : PAQUETS APT
# ==============================================================================
titre "Installation des paquets apt"

sudo apt update -q

echo -e "${YELLOW}  Cross-compilateur ARM...${NC}"
sudo apt install -y \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    binutils-arm-linux-gnueabihf
ok "Cross-compilateur : $(arm-linux-gnueabihf-gcc --version | head -1)"

echo -e "${YELLOW}  Outils de build...${NC}"
sudo apt install -y \
    cmake ninja-build make \
    pkg-config symlinks

echo -e "${YELLOW}  Dépendances Qt Creator (affichage, XCB)...${NC}"
sudo apt install -y \
    libxcb1-dev libxcb-glx0-dev libxcb-keysyms1-dev \
    libxcb-image0-dev libxcb-shm0-dev libxcb-icccm4-dev \
    libxcb-sync-dev libxcb-xfixes0-dev libxcb-shape0-dev \
    libxcb-randr0-dev libxcb-render-util0-dev \
    libxcb-util-dev libxcb-xinerama0-dev libxcb-xkb-dev \
    libxkbcommon-dev libxkbcommon-x11-dev \
    libgl1-mesa-dev libfontconfig1-dev libfreetype6-dev

ok "Paquets installés"

# ==============================================================================
# PARTIE 3 : EXTRACTION DU ZIP
# ==============================================================================
titre "Extraction de l'archive"

DEST="$INSTALL_DIR/$DIR_QT5"

if [ -d "$DEST" ]; then
    warn "$DEST existe déjà — suppression et remplacement"
    rm -rf "$DEST"
fi

echo -e "${YELLOW}  Extraction dans $INSTALL_DIR ...${NC}"
unzip -q "$ZIP_PATH" -d "$INSTALL_DIR"

[ -d "$DEST" ] && ok "Extrait : $DEST" \
    || err "Extraction échouée — $DEST introuvable après unzip"

# ==============================================================================
# PARTIE 4 : DÉTECTION DES CHEMINS
# ==============================================================================
titre "Détection des chemins"

QT5_SYSROOT="$DEST/sysroot"
QT5_QMAKE=""

for candidate in \
    "$DEST/qt5.15/bin/qmake" \
    "$DEST/qt5pi/bin/qmake" \
    "$DEST/target/bin/qmake" \
    "$DEST/qt-raspi/bin/qmake"; do
    [ -f "$candidate" ] && QT5_QMAKE="$candidate" && break
done

[ -n "$QT5_QMAKE" ] && ok "qmake : $QT5_QMAKE" \
    || err "qmake introuvable dans $DEST — vérifiez le contenu du zip"

[ -d "$QT5_SYSROOT/usr/include" ] && ok "sysroot : $QT5_SYSROOT" \
    || err "sysroot absent ou incomplet : $QT5_SYSROOT"

[ -d "$DEST/tools" ] && ok "tools : $DEST/tools" \
    || warn "Dossier tools absent"

# ==============================================================================
# PARTIE 5 : CORRECTION DES SYMLINKS
# ==============================================================================
titre "Correction des symlinks absolus du sysroot"

echo -e "${YELLOW}  symlinks -rc $QT5_SYSROOT ...${NC}"
symlinks -rc "$QT5_SYSROOT" > /dev/null 2>&1
ok "Symlinks corrigés"

# ==============================================================================
# PARTIE 6 : RÉCAPITULATIF
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Installation terminée !                                  ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${GREEN}  Cross-compilateur : /usr/bin/arm-linux-gnueabihf-g++${NC}"
echo -e "${GREEN}  Qt5 qmake         : $QT5_QMAKE${NC}"
echo -e "${GREEN}  Qt5 sysroot       : $QT5_SYSROOT${NC}"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   Configuration Qt Creator (manuelle)                      ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${CYAN}  1. Outils > Options > Kits > Compilateurs > Ajouter > GCC${NC}"
echo -e "${CYAN}     Nom  : GCC ARM RPi4 (C)${NC}"
echo -e "${CYAN}     C    : /usr/bin/arm-linux-gnueabihf-gcc${NC}"
echo -e "${CYAN}     ABI  : arm-linux-generic-elf-32bit${NC}"
echo ""
echo -e "${CYAN}     Nom  : G++ ARM RPi4 (C++)${NC}"
echo -e "${CYAN}     C++  : /usr/bin/arm-linux-gnueabihf-g++${NC}"
echo -e "${CYAN}     ABI  : arm-linux-generic-elf-32bit${NC}"
echo ""
echo -e "${CYAN}  2. Versions Qt > Ajouter${NC}"
echo -e "${CYAN}     Nom   : Qt 5.15.2 RPi4${NC}"
echo -e "${CYAN}     qmake : $QT5_QMAKE${NC}"
echo ""
echo -e "${CYAN}  3. Kits > Ajouter${NC}"
echo -e "${CYAN}     Nom        : RPi4 Qt5.15.2${NC}"
echo -e "${CYAN}     Compilateur: arm-linux-gnueabihf-g++ (déclaré ci-dessus)${NC}"
echo -e "${CYAN}     Qt         : Qt 5.15.2 RPi4${NC}"
echo -e "${CYAN}     Mkspec     : devices/linux-rasp-pi4-v3d-g++${NC}"
echo -e "${CYAN}     Sysroot    : $QT5_SYSROOT${NC}"
echo ""
echo -e "${YELLOW}  4. Configurer l'appareil RPi4 :${NC}"
echo -e "${YELLOW}     Outils > Options > Appareils > Ajouter > Generic Linux Device${NC}"
echo -e "${YELLOW}     IP : <adresse_ip_rpi4>  |  Login : pi${NC}"
echo -e "${YELLOW}     Variable d'environnement d'exécution (Projets > Exécuter) :${NC}"
echo -e "${YELLOW}     LD_LIBRARY_PATH = :/usr/local/qt5pi/lib${NC}"
echo ""

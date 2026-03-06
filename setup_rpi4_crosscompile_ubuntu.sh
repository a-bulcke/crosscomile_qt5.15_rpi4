#!/bin/bash
# ==============================================================================
# setup_rpi4_crosscompile_ubuntu.sh
#
# Installation de l'environnement de cross-compilation Qt5 + Qt6 pour RPi4
# sur Ubuntu 22.04 x86_64
#
# Ce script :
#   1. Installe les paquets apt nécessaires à la cross-compilation
#   2. Télécharge et extrait les archives .zip cross_rpi4_qt5 et cross_rpi4_qt6
#   3. Vérifie l'intégrité de l'installation (sysroot, qmake, toolchain.cmake)
#   4. Configure automatiquement Qt Creator via sdktool (compilateurs + kits)
#   5. Affiche un récapitulatif de la configuration
#
# Prérequis : Ubuntu 22.04 x86_64, Qt Creator déjà installé
# Usage     : chmod +x setup_rpi4_crosscompile_ubuntu.sh
#             ./setup_rpi4_crosscompile_ubuntu.sh
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION — À ADAPTER AVANT DÉPLOIEMENT
# ==============================================================================

URL_QT5="https://e.pcloud.link/publink/show?code=XZNSi3ZEAtUKCYgHEkAknHeBlFfpf27XXOV"
URL_QT6="https://e.pcloud.link/publink/show?code=XZGSi3ZNuodtzyY2iHOmigXR1WrLRY6G9FX"

INSTALL_DIR="$HOME"
DIR_QT5="cross_rpi4_qt5"
DIR_QT6="cross_rpi4_qt6"

# ==============================================================================
# COULEURS
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "${GREEN}  [OK] $*${NC}"; }
info()  { echo -e "${YELLOW}  [INFO] $*${NC}"; }
warn()  { echo -e "${YELLOW}  [WARN] $*${NC}"; }
err()   { echo -e "${RED}  [ERREUR] $*${NC}"; exit 1; }
titre() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ==============================================================================
# BANNIÈRE
# ==============================================================================
echo -e "${CYAN}"
echo "============================================================"
echo "  Setup cross-compilation Qt5.15.2 + Qt6.10 pour RPi4      "
echo "  Ubuntu 22.04 x86_64                                       "
echo "============================================================"
echo -e "${NC}"
echo -e "${YELLOW}  Qt5 : $URL_QT5${NC}"
echo -e "${YELLOW}  Qt6 : $URL_QT6${NC}"
echo -e "${YELLOW}  Dossier cible : $INSTALL_DIR${NC}"

# ==============================================================================
# PARTIE 1 : VÉRIFICATIONS PRÉALABLES
# ==============================================================================
titre "Vérifications préalables"

[[ "$URL_QT5" == *"VOTRE_SERVEUR"* ]] || [[ "$URL_QT6" == *"VOTRE_SERVEUR"* ]] \
    && err "URLs non configurées — éditez URL_QT5 et URL_QT6 en haut de ce script"

grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null \
    && ok "Ubuntu 22.04" || warn "OS non Ubuntu 22.04 — résultats non garantis"

[ "$(uname -m)" = "x86_64" ] && ok "Architecture x86_64" \
    || err "Architecture $(uname -m) non supportée"

DISPO_GO=$(df -BG "$INSTALL_DIR" | awk 'NR==2{gsub("G",""); print $4}')
[ "$DISPO_GO" -ge 10 ] \
    && ok "Espace disque : ${DISPO_GO}Go disponibles" \
    || err "Espace insuffisant : ${DISPO_GO}Go (10Go minimum)"

# ==============================================================================
# PARTIE 2 : PAQUETS APT
# ==============================================================================
titre "Installation des paquets apt"

sudo apt update -q

echo -e "${YELLOW}  Outils de build et utilitaires...${NC}"
sudo apt install -y \
    build-essential cmake ninja-build \
    git wget curl unzip pkg-config \
    python3 gperf flex bison symlinks

echo -e "${YELLOW}  Cross-compilateur ARM (triplet Debian, compatible sysroot Bookworm)...${NC}"
sudo apt install -y \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    binutils-arm-linux-gnueabihf
ok "Cross-compilateur : $(arm-linux-gnueabihf-gcc --version | head -1)"

echo -e "${YELLOW}  Dépendances Qt hôte...${NC}"
sudo apt install -y \
    libclang-dev clang \
    libfontconfig1-dev libfreetype6-dev \
    libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev \
    libxi-dev libxrender-dev \
    libxcb1-dev libxcb-glx0-dev libxcb-keysyms1-dev \
    libxcb-image0-dev libxcb-shm0-dev libxcb-icccm4-dev \
    libxcb-sync-dev libxcb-xfixes0-dev libxcb-shape0-dev \
    libxcb-randr0-dev libxcb-render-util0-dev \
    libxcb-util-dev libxcb-xinerama0-dev libxcb-xkb-dev \
    libxkbcommon-dev libxkbcommon-x11-dev \
    libatspi2.0-dev libgl1-mesa-dev libglu1-mesa-dev \
    libssl-dev
ok "Dépendances Qt hôte installées"

# ==============================================================================
# PARTIE 3 : TÉLÉCHARGEMENT ET EXTRACTION DES ARCHIVES .ZIP
# ==============================================================================
titre "Téléchargement et extraction des archives"

download_and_extract() {
    local label="$1" url="$2" dest="$3"
    local archive="/tmp/${label}.zip"

    echo -e "${YELLOW}  [$label] Téléchargement...${NC}"
    wget -c --show-progress "$url" -O "$archive"
    ok "$label : $(du -sh $archive | cut -f1)"

    [ -d "$dest" ] && { warn "$dest existe — remplacement"; rm -rf "$dest"; }

    echo -e "${YELLOW}  [$label] Extraction dans $INSTALL_DIR ...${NC}"
    unzip -q "$archive" -d "$INSTALL_DIR"
    rm -f "$archive"

    [ -d "$dest" ] && ok "$label extrait : $dest" \
        || err "Extraction $label échouée — $dest introuvable"
}

download_and_extract "Qt5" "$URL_QT5" "$INSTALL_DIR/$DIR_QT5"
download_and_extract "Qt6" "$URL_QT6" "$INSTALL_DIR/$DIR_QT6"

# ==============================================================================
# PARTIE 4 : DÉTECTION DES CHEMINS ET VÉRIFICATIONS
# ==============================================================================
titre "Vérification de l'installation"

QT5_DIR="$INSTALL_DIR/$DIR_QT5"
QT6_DIR="$INSTALL_DIR/$DIR_QT6"
QT5_SYSROOT="$QT5_DIR/sysroot"
QT6_SYSROOT="$QT6_DIR/sysroot"
QT6_TOOLCHAIN="$QT6_DIR/toolchain.cmake"

# Détecter qmake Qt5
for c in "$QT5_DIR/qt5pi/bin/qmake" "$QT5_DIR/target/bin/qmake" \
          "$QT5_DIR/qt-raspi/bin/qmake"; do
    [ -f "$c" ] && QT5_QMAKE="$c" && break
done

# Détecter qmake Qt6 et staging
for c in "$QT6_DIR/target/bin/qmake" "$QT6_DIR/qt-raspi/bin/qmake"; do
    if [ -f "$c" ]; then
        QT6_QMAKE="$c"
        QT6_STAGING="$(dirname "$(dirname "$c")")"
        break
    fi
done

echo -e "${YELLOW}  Qt5 :${NC}"
[ -n "$QT5_QMAKE" ] && ok "qmake : $QT5_QMAKE" || err "qmake Qt5 introuvable dans $QT5_DIR"
[ -d "$QT5_SYSROOT/usr/include" ] && ok "sysroot OK" || err "sysroot Qt5 absent"

echo -e "${YELLOW}  Qt6 :${NC}"
[ -n "$QT6_QMAKE" ] && ok "qmake : $QT6_QMAKE" || err "qmake Qt6 introuvable dans $QT6_DIR"
[ -d "$QT6_SYSROOT/usr/include" ] && ok "sysroot OK" || err "sysroot Qt6 absent"
[ -f "$QT6_TOOLCHAIN" ] && ok "toolchain.cmake : $QT6_TOOLCHAIN" \
    || err "toolchain.cmake absent : $QT6_TOOLCHAIN"

# --- Mkspec Qt6 ---
QT6_MKSPEC="$QT6_STAGING/mkspecs/devices/linux-rasp-pi4-ubuntu-cross"
if [ -f "$QT6_MKSPEC/qmake.conf" ]; then
    ok "mkspec Qt6 : $QT6_MKSPEC"
    if ! grep -q "^CROSS_COMPILE" "$QT6_MKSPEC/qmake.conf"; then
        warn "CROSS_COMPILE absent — ajout automatique"
        sed -i '/^include(.*linux_device_pre.conf)/a CROSS_COMPILE           = arm-linux-gnueabihf-\nQMAKE_CC                = $${CROSS_COMPILE}gcc\nQMAKE_CXX               = $${CROSS_COMPILE}g++\nQMAKE_LINK              = $${QMAKE_CXX}\nQMAKE_LINK_SHLIB        = $${QMAKE_CXX}\nQMAKE_AR                = $${CROSS_COMPILE}ar cqs\nQMAKE_OBJCOPY           = $${CROSS_COMPILE}objcopy\nQMAKE_NM                = $${CROSS_COMPILE}nm -P\nQMAKE_STRIP             = $${CROSS_COMPILE}strip' \
            "$QT6_MKSPEC/qmake.conf"
        ok "CROSS_COMPILE ajouté"
    else
        ok "CROSS_COMPILE présent dans qmake.conf"
    fi
else
    warn "Mkspec Qt6 absent — création automatique"
    mkdir -p "$QT6_MKSPEC"
    cat > "$QT6_MKSPEC/qmake.conf" << 'MKSPEC_EOF'
include(../common/linux_device_pre.conf)

CROSS_COMPILE           = arm-linux-gnueabihf-
QMAKE_CC                = $${CROSS_COMPILE}gcc
QMAKE_CXX               = $${CROSS_COMPILE}g++
QMAKE_LINK              = $${QMAKE_CXX}
QMAKE_LINK_SHLIB        = $${QMAKE_CXX}
QMAKE_AR                = $${CROSS_COMPILE}ar cqs
QMAKE_OBJCOPY           = $${CROSS_COMPILE}objcopy
QMAKE_NM                = $${CROSS_COMPILE}nm -P
QMAKE_STRIP             = $${CROSS_COMPILE}strip

QMAKE_LIBS_EGL         += -lEGL
QMAKE_LIBS_OPENGL_ES2  += -lGLESv2 -lEGL

QMAKE_CFLAGS            = -march=armv8-a -mtune=cortex-a72 -mfpu=neon-vfpv4 -mfloat-abi=hard
QMAKE_CXXFLAGS          = $$QMAKE_CFLAGS

DISTRO_OPTS            += deb-multi-arch
EGLFS_DEVICE_INTEGRATION = eglfs_kms

include(../common/linux_device_post.conf)
load(qt_config)
MKSPEC_EOF
    echo '#include "../../linux-g++/qplatformdefs.h"' > "$QT6_MKSPEC/qplatformdefs.h"
    ok "Mkspec Qt6 créé"
fi

# --- Symlink libdbus-1.so ---
DBUS_SO="$QT6_SYSROOT/usr/lib/arm-linux-gnueabihf/libdbus-1.so"
DBUS_SO3=$(find "$QT6_SYSROOT/usr/lib/arm-linux-gnueabihf" \
    -name "libdbus-1.so.3*" 2>/dev/null | head -1)
if [ -e "$DBUS_SO" ]; then
    ok "libdbus-1.so présent dans sysroot Qt6"
elif [ -n "$DBUS_SO3" ]; then
    ln -sfv "$(basename "$DBUS_SO3")" "$DBUS_SO"
    ok "libdbus-1.so → $(basename "$DBUS_SO3")"
else
    warn "libdbus-1.so introuvable dans le sysroot Qt6"
fi

# --- Correction symlinks absolus ---
echo -e "${YELLOW}  Correction des symlinks absolus dans les sysroots...${NC}"
symlinks -rc "$QT5_SYSROOT" > /dev/null 2>&1 && ok "Symlinks Qt5 sysroot corrigés"
symlinks -rc "$QT6_SYSROOT" > /dev/null 2>&1 && ok "Symlinks Qt6 sysroot corrigés"

# ==============================================================================
# PARTIE 5 : CONFIGURATION AUTOMATIQUE Qt Creator via sdktool
# ==============================================================================
titre "Configuration automatique Qt Creator (sdktool)"

SDKTOOL=""
for c in \
    "/opt/Qt/Tools/QtCreator/libexec/qtcreator/sdktool" \
    "/usr/lib/x86_64-linux-gnu/qtcreator/sdktool" \
    "$(find /opt /usr/lib -name sdktool 2>/dev/null | head -1)"; do
    [ -x "$c" ] && SDKTOOL="$c" && break
done

CMAKE_BIN=$(which cmake)
GCC_C="/usr/bin/arm-linux-gnueabihf-gcc"
GCC_CXX="/usr/bin/arm-linux-gnueabihf-g++"
QT6_TOOLCHAIN_CMAKE="$QT6_STAGING/lib/cmake/Qt6/qt.toolchain.cmake"

# IDs stables — identiques sur tous les postes pour faciliter le déploiement
ID_GCC_C="ProjectExplorer.ToolChain.Gcc:rpi4_gcc_arm_c"
ID_GCC_CXX="ProjectExplorer.ToolChain.Gcc:rpi4_gcc_arm_cxx"
ID_QT5="Qt4ProjectManager.QtVersion.Desktop:rpi4_qt5"
ID_QT6="Qt4ProjectManager.QtVersion.Desktop:rpi4_qt6"
ID_KIT5="ProjectExplorer.Kit:rpi4_kit_qt5"
ID_KIT6="ProjectExplorer.Kit:rpi4_kit_qt6"

SDKTOOL_OK=0
if [ -n "$SDKTOOL" ]; then
    ok "sdktool : $SDKTOOL"
    SDKTOOL_OK=1

    echo -e "${YELLOW}  Suppression éventuelles configs précédentes...${NC}"
    $SDKTOOL rmKit 2>/dev/null --id "$ID_KIT5" || true
    $SDKTOOL rmKit 2>/dev/null --id "$ID_KIT6" || true
    $SDKTOOL rmQt  2>/dev/null --id "$ID_QT5"  || true
    $SDKTOOL rmQt  2>/dev/null --id "$ID_QT6"  || true
    $SDKTOOL rmTC  2>/dev/null --id "$ID_GCC_C"   || true
    $SDKTOOL rmTC  2>/dev/null --id "$ID_GCC_CXX" || true

    echo -e "${YELLOW}  Ajout compilateurs ARM...${NC}"
    $SDKTOOL addTC \
        --id "$ID_GCC_C" --name "GCC ARM RPi4 (C)" \
        --path "$GCC_C" --abi "arm-linux-generic-elf-32bit" --language "1"
    ok "Compilateur C ajouté"

    $SDKTOOL addTC \
        --id "$ID_GCC_CXX" --name "G++ ARM RPi4 (C++)" \
        --path "$GCC_CXX" --abi "arm-linux-generic-elf-32bit" --language "2"
    ok "Compilateur C++ ajouté"

    echo -e "${YELLOW}  Ajout versions Qt...${NC}"
    $SDKTOOL addQt \
        --id "$ID_QT5" --name "Qt 5.15.2 RPi4" \
        --type "Qt4ProjectManager.QtVersion.Desktop" \
        --qmake "$QT5_QMAKE"
    ok "Qt 5.15.2 RPi4 ajouté"

    $SDKTOOL addQt \
        --id "$ID_QT6" --name "Qt 6.10 RPi4" \
        --type "Qt4ProjectManager.QtVersion.Desktop" \
        --qmake "$QT6_QMAKE"
    ok "Qt 6.10 RPi4 ajouté"

    echo -e "${YELLOW}  Ajout kits...${NC}"
    $SDKTOOL addKit \
        --id "$ID_KIT5" --name "RPi4 Qt5.15.2" \
        --devicetype "GenericLinuxOsType" \
        --toolchain "ProjectExplorer.ProjectExplorer.ToolChain.Gcc/$ID_GCC_C" \
        --toolchain "ProjectExplorer.ProjectExplorer.ToolChain.Gcc/$ID_GCC_CXX" \
        --qt "$ID_QT5" \
        --cmake "$CMAKE_BIN" \
        --mkspec "devices/linux-rasp-pi4-v3d-g++" \
        --sysroot "$QT5_SYSROOT"
    ok "Kit RPi4 Qt5.15.2 ajouté"

    $SDKTOOL addKit \
        --id "$ID_KIT6" --name "RPi4 Qt6.10" \
        --devicetype "GenericLinuxOsType" \
        --toolchain "ProjectExplorer.ProjectExplorer.ToolChain.Gcc/$ID_GCC_C" \
        --toolchain "ProjectExplorer.ProjectExplorer.ToolChain.Gcc/$ID_GCC_CXX" \
        --qt "$ID_QT6" \
        --cmake "$CMAKE_BIN" \
        --mkspec "devices/linux-rasp-pi4-ubuntu-cross" \
        --sysroot "$QT6_SYSROOT" \
        --cmake-config "CMakeToolchain:UNINITIALIZED=$QT6_TOOLCHAIN_CMAKE"
    ok "Kit RPi4 Qt6.10 ajouté"

else
    warn "sdktool introuvable (cherché dans /opt/Qt et /usr/lib)"
    warn "Configuration Qt Creator manuelle nécessaire (voir récapitulatif ci-dessous)"
fi

# ==============================================================================
# PARTIE 6 : RÉCAPITULATIF
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Installation terminée !                                  ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${GREEN}  Cross-compilateur   : $GCC_CXX${NC}"
echo -e "${GREEN}  Qt5 qmake           : $QT5_QMAKE${NC}"
echo -e "${GREEN}  Qt5 sysroot         : $QT5_SYSROOT${NC}"
echo -e "${GREEN}  Qt6 qmake           : $QT6_QMAKE${NC}"
echo -e "${GREEN}  Qt6 sysroot         : $QT6_SYSROOT${NC}"
echo -e "${GREEN}  Qt6 toolchain.cmake : $QT6_TOOLCHAIN${NC}"
echo ""

if [ "$SDKTOOL_OK" -eq 1 ]; then
    echo -e "${CYAN}  Kits configurés automatiquement.${NC}"
    echo -e "${CYAN}  → Redémarrez Qt Creator pour qu'ils apparaissent.${NC}"
    echo -e "${CYAN}  → Vérifiez dans : Outils > Options > Kits${NC}"
else
    echo -e "${YELLOW}  sdktool non trouvé — configuration manuelle Qt Creator :${NC}"
    echo ""
    echo -e "${YELLOW}  1. Outils > Options > Kits > Compilateurs > Ajouter > GCC${NC}"
    echo -e "${YELLOW}     C   : $GCC_C${NC}"
    echo -e "${YELLOW}     C++ : $GCC_CXX${NC}"
    echo -e "${YELLOW}     ABI : arm-linux-generic-elf-32bit${NC}"
    echo ""
    echo -e "${YELLOW}  2. Versions Qt > Ajouter${NC}"
    echo -e "${YELLOW}     Qt5 : $QT5_QMAKE${NC}"
    echo -e "${YELLOW}     Qt6 : $QT6_QMAKE${NC}"
    echo ""
    echo -e "${YELLOW}  3. Kits > Ajouter${NC}"
fi

echo ""
echo -e "${CYAN}  ┌─ Kit Qt5 ──────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}  │  Nom      : RPi4 Qt5.15.2                                  │${NC}"
echo -e "${CYAN}  │  Compil.  : arm-linux-gnueabihf-g++                        │${NC}"
echo -e "${CYAN}  │  Qt       : Qt 5.15.2 RPi4                                 │${NC}"
echo -e "${CYAN}  │  Mkspec   : devices/linux-rasp-pi4-v3d-g++                 │${NC}"
echo -e "${CYAN}  │  Sysroot  : $QT5_SYSROOT  │${NC}"
echo -e "${CYAN}  └────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${CYAN}  ┌─ Kit Qt6 ──────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}  │  Nom      : RPi4 Qt6.10                                    │${NC}"
echo -e "${CYAN}  │  Compil.  : arm-linux-gnueabihf-g++                        │${NC}"
echo -e "${CYAN}  │  Qt       : Qt 6.10 RPi4                                   │${NC}"
echo -e "${CYAN}  │  Mkspec   : devices/linux-rasp-pi4-ubuntu-cross            │${NC}"
echo -e "${CYAN}  │  Sysroot  : $QT6_SYSROOT  │${NC}"
echo -e "${CYAN}  │  Toolchain: $QT6_TOOLCHAIN  │${NC}"
echo -e "${CYAN}  │  CMake    : $QT6_TOOLCHAIN_CMAKE  │${NC}"
echo -e "${CYAN}  └────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}  → Configurer l'appareil RPi4 dans Qt Creator :${NC}"
echo -e "${YELLOW}    Outils > Options > Appareils > Ajouter > Generic Linux Device${NC}"
echo -e "${YELLOW}    IP : <adresse_ip_rpi4>  |  Login : <utilisateur_rpi4>${NC}"
echo ""
echo -e "${YELLOW}  → Variable d'environnement d'exécution (Projets > Exécuter) :${NC}"
echo -e "${YELLOW}    Qt5 : LD_LIBRARY_PATH = :/usr/local/qt5pi/lib${NC}"
echo -e "${YELLOW}    Qt6 : LD_LIBRARY_PATH = :/usr/local/qt6/lib${NC}"
echo ""
echo -e "${GREEN}  Créer les archives depuis votre poste de référence :${NC}"
echo -e "${GREEN}    cd ~ && zip -r cross_rpi4_qt5.zip cross_rpi4_qt5/ \\${NC}"
echo -e "${GREEN}              --exclude 'cross_rpi4_qt5/src/*'${NC}"
echo -e "${GREEN}    cd ~ && zip -r cross_rpi4_qt6.zip cross_rpi4_qt6/ \\${NC}"
echo -e "${GREEN}              --exclude 'cross_rpi4_qt6/src/*' \\${NC}"
echo -e "${GREEN}              --exclude 'cross_rpi4_qt6/host-build/*' \\${NC}"
echo -e "${GREEN}              --exclude 'cross_rpi4_qt6/target-build/*'${NC}"
echo ""

#!/bin/bash
# ============================================================
#  jeehelp installer
#  Déploie jeehelp.sh comme commande globale "jeehelp" sur une box Jeedom.
#
#  Usage distant (one-liner) :
#    curl -fsSL https://raw.githubusercontent.com/limad/jeehelp/beta/install.sh | sudo bash
#
#  Usage local (depuis un clone du dépôt) :
#    sudo bash install.sh
# ============================================================
set -euo pipefail

readonly REPO_RAW_URL="https://raw.githubusercontent.com/limad/jeehelp/beta/jeehelp.sh"
readonly INSTALL_PATH="/usr/local/bin/jeehelp"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

if [[ ${EUID} -ne 0 ]]; then
    echo "Ce script doit être exécuté avec sudo ou en root." >&2
    echo "Exemple : sudo bash install.sh" >&2
    exit 1
fi

tmp_file=""
cleanup() {
    [[ -n "${tmp_file}" && -f "${tmp_file}" ]] && rm -f "${tmp_file}"
}
trap cleanup EXIT

if [[ -f "${SCRIPT_DIR}/jeehelp.sh" ]]; then
    source_file="${SCRIPT_DIR}/jeehelp.sh"
else
    echo "Téléchargement de jeehelp.sh depuis GitHub..."
    tmp_file="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
        download_ok=0
        curl -fsSL "${REPO_RAW_URL}" -o "${tmp_file}" && download_ok=1
    elif command -v wget >/dev/null 2>&1; then
        download_ok=0
        wget -qO "${tmp_file}" "${REPO_RAW_URL}" && download_ok=1
    else
        echo "Ni curl ni wget n'est disponible sur ce système." >&2
        exit 1
    fi
    if [[ "${download_ok}" -ne 1 ]]; then
        echo "Échec du téléchargement depuis ${REPO_RAW_URL}" >&2
        exit 1
    fi
    source_file="${tmp_file}"
fi

bash -n "${source_file}" || { echo "Le script téléchargé contient une erreur de syntaxe, abandon." >&2; exit 1; }

install -m 0755 -o root -g root "${source_file}" "${INSTALL_PATH}"

echo "jeehelp installé : ${INSTALL_PATH}"
echo "Utilisation : jeehelp (interactif) ou jeehelp --backup / --repair-db / --check / --upgrade-security"

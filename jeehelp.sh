#!/bin/bash
# ============================================================
#  jeedom-menu.sh v3 — Menu d'administration Jeedom
#  Navigation : ↑↓ sélection  ENTRÉE valider  ÉCHAP retour  CTRL+C quitter
#  Debian 11/12, Jeedom >= 4.4
#  Interactif : sudo bash jeedom-menu.sh
#  CLI        : sudo bash jeedom-menu.sh --backup
#               sudo bash jeedom-menu.sh --repair-db
#               sudo bash jeedom-menu.sh --check
#               sudo bash jeedom-menu.sh --upgrade-security
# ============================================================

# ── Constantes ───────────────────────────────────────────────
readonly JEEDOM_DIR="/var/www/html"
readonly BACKUP_DIR="${JEEDOM_DIR}/backup"
readonly LOG_DIR="${JEEDOM_DIR}/log"
readonly CONF_FILE="${JEEDOM_DIR}/core/config/common.config.php"
readonly PHP_CLI="php ${JEEDOM_DIR}/core/php/jeedom.php"
readonly AUDIT_LOG="/var/log/jeedom-menu.log"
readonly MAX_BACKUPS=7

# ── Couleurs ─────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' N='\033[0m'
DIM='\033[2m'

# ── Cache MySQL ──────────────────────────────────────────────
declare -g _DB_LOADED=0
declare -g DB_HOST DB_PORT DB_NAME DB_USER DB_PASS

# ── Navigation ───────────────────────────────────────────────
declare -g MENU_RESULT=0   # index sélectionné, -1 = ESC/retour
declare -g PICKED_FILE=""  # résultat pick_file_nav

# ============================================================
#  GESTION CURSEUR & SORTIE PROPRE
# ============================================================

_cursor_hide() { tput civis 2>/dev/null; }
_cursor_show() { tput cnorm 2>/dev/null; }

_exit_clean() {
    _cursor_show
    stty echo 2>/dev/null
    echo -e "\n${G}Au revoir !${N}\n"
    exit 0
}

trap '_exit_clean' INT TERM
trap '_cursor_show' EXIT

# ============================================================
#  HELPERS GÉNÉRIQUES
# ============================================================

log_action() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$(whoami)] $*" >> "${AUDIT_LOG}" 2>/dev/null; }
pause()      { _cursor_show; echo; read -rp "$(echo -e "${Y}Appuyez sur [Entrée]...${N}")"; }
section()    { echo -e "\n${C}── $1 ──────────────────────────────────────────${N}\n"; }

header() {
    clear
    echo -e "${B}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${B}║${W}        🏠  JEEDOM — Menu d'administration           ${B}║${N}"
    echo -e "${B}╚══════════════════════════════════════════════════════╝${N}"
    echo
}

# Confirmation par touche unique o/N
confirm() {
    local prompt="${1:-Confirmer ?}"
    echo -ne "${Y}${prompt} [o/N] : ${N}"
    local key
    read -rsn1 key
    echo "${key}"
    [[ "${key,,}" == "o" ]]
}

# ── Lecture d'une séquence clavier ──────────────────────────
#  Retourne dans $KEY_RESULT : "up" "down" "enter" "esc" "ctrlc" ou le char
read_key() {
    local key seq
    IFS= read -rsn1 key

    case "$key" in
        $'\x1b')  # début séquence ESC
            read -rsn2 -t 0.15 seq 2>/dev/null
            case "$seq" in
                '[A') KEY_RESULT="up"    ;;
                '[B') KEY_RESULT="down"  ;;
                '[5') KEY_RESULT="pgup"  ; read -rsn1 -t 0.05 _ 2>/dev/null ;;
                '[6') KEY_RESULT="pgdn"  ; read -rsn1 -t 0.05 _ 2>/dev/null ;;
                '')   KEY_RESULT="esc"   ;;
                *)    KEY_RESULT="esc"   ;;
            esac
            ;;
        $'\n'|$'\r'|'')  KEY_RESULT="enter"  ;;
        $'\x03')          KEY_RESULT="ctrlc"  ;;
        $'\x04')          KEY_RESULT="ctrld"  ;;
        *)                KEY_RESULT="$key"   ;;
    esac
}

# ============================================================
#  MOTEUR DE MENU À FLÈCHES
# ============================================================
#  nav_menu "Titre du menu" label1 label2 ... labelN
#  Le dernier label doit être l'item "retour/quitter".
#  Résultat dans $MENU_RESULT (0-based) ; -1 si ESC.

_draw_nav_menu() {
    local title="$1" sel="$2"
    shift 2
    local -a opts=("$@")
    local total=${#opts[@]}

    header
    section "$title"

    for i in "${!opts[@]}"; do
        if [[ $i -eq $sel ]]; then
            echo -e "  ${C}▶${N} ${W}${opts[$i]}${N}"
        else
            echo -e "  ${DIM}  ${opts[$i]}${N}"
        fi
    done

    echo
    echo -e "  ${DIM}↑↓ naviguer  ↵ sélectionner  Échap retour  Ctrl+C quitter${N}"
}

nav_menu() {
    local title="$1"
    shift
    local -a opts=("$@")
    local total=${#opts[@]}
    local sel=0

    _cursor_hide

    while true; do
        _draw_nav_menu "$title" "$sel" "${opts[@]}"
        read_key

        case "$KEY_RESULT" in
            up)
                [[ $sel -gt 0 ]] && ((sel--)) || sel=$((total - 1))
                ;;
            down)
                [[ $sel -lt $((total - 1)) ]] && ((sel++)) || sel=0
                ;;
            pgup) sel=0 ;;
            pgdn) sel=$((total - 1)) ;;
            enter)
                _cursor_show
                MENU_RESULT=$sel
                return
                ;;
            esc)
                _cursor_show
                MENU_RESULT=-1
                return
                ;;
            ctrlc|ctrld)
                _exit_clean
                ;;
        esac
    done
}

# ============================================================
#  SÉLECTEUR DE FICHIER AVEC FLÈCHES
# ============================================================
#  pick_file_nav "label" "glob"  →  résultat dans $PICKED_FILE
#  Retourne 0 si fichier choisi, 1 si annulé

pick_file_nav() {
    local label="$1" glob="$2"
    mapfile -t _PF_FILES < <(ls -t ${glob} 2>/dev/null)

    if [[ ${#_PF_FILES[@]} -eq 0 ]]; then
        _cursor_show
        echo -e "${R}Aucun fichier trouvé.${N}"
        return 1
    fi

    # Construire les labels avec taille
    local -a labels
    for f in "${_PF_FILES[@]}"; do
        local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1)
        labels+=("$(basename "$f")  ${DIM}(${sz})${N}")
    done
    labels+=("↩  Annuler")

    nav_menu "$label" "${labels[@]}"

    if [[ $MENU_RESULT -eq -1 || $MENU_RESULT -ge ${#_PF_FILES[@]} ]]; then
        return 1
    fi

    PICKED_FILE="${_PF_FILES[$MENU_RESULT]}"
    return 0
}

# ============================================================
#  MYSQL & VÉRIFICATIONS
# ============================================================

load_mysql_creds() {
    [[ $_DB_LOADED -eq 1 ]] && return
    DB_HOST=$(grep "db:host"     "${CONF_FILE}" | sed "s/.*=> *'\(.*\)'.*/\1/")
    DB_PORT=$(grep "db:port"     "${CONF_FILE}" | sed "s/.*=> *'\(.*\)'.*/\1/")
    DB_NAME=$(grep "db:dbname"   "${CONF_FILE}" | sed "s/.*=> *'\(.*\)'.*/\1/")
    DB_USER=$(grep "db:username" "${CONF_FILE}" | sed "s/.*=> *'\(.*\)'.*/\1/")
    DB_PASS=$(grep "db:password" "${CONF_FILE}" | sed "s/.*=> *'\(.*\)'.*/\1/")
    DB_PORT=${DB_PORT:-3306}
    _DB_LOADED=1
}

mysql_cmd() {
    load_mysql_creds
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" "$@" 2>/dev/null
}

svc_ctl() {
    local action="$1" svc="$2"
    systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}" \
        || { echo -e "${Y}Service ${svc} absent.${N}"; return 1; }
    systemctl "${action}" "${svc}" \
        && echo -e "${G}✔ ${svc} ${action} OK${N}" \
        || echo -e "${R}✘ Erreur ${svc} ${action}${N}"
}

check_root()   { [[ $EUID -ne 0 ]] && { echo -e "${R}Lancer en root (sudo).${N}"; exit 1; }; }
check_jeedom() { [[ ! -f "${CONF_FILE}" ]] && { echo -e "${R}Jeedom non détecté dans ${JEEDOM_DIR}${N}"; exit 1; }; }

# ============================================================
#  1 — INFORMATIONS SYSTÈME
# ============================================================

show_system_info() {
    header; section "Informations système"
    local ip_local ip_ext jee_ver
    ip_local=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    ip_ext=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")
    jee_ver=$(cat "${JEEDOM_DIR}/core/config/version" 2>/dev/null | tr -d '[:space:]' || echo "inconnue")

    printf "  ${W}%-16s${N} ${G}%s${N}\n" "IP locale"   "${ip_local:-inconnu}"
    printf "  ${W}%-16s${N} ${G}%s${N}\n" "IP externe"  "${ip_ext}"
    printf "  ${W}%-16s${N} %s\n"         "Hostname"    "$(hostname)"
    printf "  ${W}%-16s${N} %s\n"         "OS"          "$(. /etc/os-release && echo "$PRETTY_NAME")"
    printf "  ${W}%-16s${N} %s\n"         "Kernel"      "$(uname -r)"
    echo
    printf "  ${W}%-16s${N} %s\n" "Jeedom"   "${jee_ver}"
    printf "  ${W}%-16s${N} %s\n" "PHP"      "$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    printf "  ${W}%-16s${N} %s\n" "MySQL"    "$(mysql --version 2>/dev/null | awk '{print $5}' | tr -d ',')"
    echo
    printf "  ${W}%-16s${N} %s\n" "Uptime"    "$(uptime -p 2>/dev/null || uptime)"
    printf "  ${W}%-16s${N} %s\n" "CPU load"  "$(awk '{print $1,$2,$3}' /proc/loadavg)"
    printf "  ${W}%-16s${N} %s\n" "RAM"       "$(free -h | awk '/^Mem:/{print $3"/"$2}')"
    printf "  ${W}%-16s${N} %s\n" "Disque"    "$(df -h "${JEEDOM_DIR}" | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    section "Services"
    for svc in apache2 nginx mysql mariadb; do
        systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}" || continue
        local st; st=$(systemctl is-active "${svc}" 2>/dev/null)
        [[ "${st}" == "active" ]] \
            && echo -e "  ${G}●${N} ${svc}" \
            || echo -e "  ${R}● ${st}${N}  ${svc}"
    done
    section "Watchdog"
    _watchdog_check
    section "Certificat SSL local"
    _ssl_check "$(hostname -f 2>/dev/null || hostname)"
    pause
}

_watchdog_check() {
    pgrep -f "jeedom.php" > /dev/null 2>&1 \
        && echo -e "  ${G}✔${N} Daemon Jeedom actif" \
        || echo -e "  ${R}✘${N} Daemon Jeedom introuvable"
    local pct; pct=$(df "${JEEDOM_DIR}" | awk 'NR==2{gsub(/%/,""); print $5}')
    [[ $pct -ge 90 ]] \
        && echo -e "  ${R}⚠  Disque ${pct}% utilisé !${N}" \
        || echo -e "  ${G}✔${N} Disque ${pct}% utilisé"
}

_ssl_check() {
    local domain="${1:-$(hostname -f)}"
    command -v openssl &>/dev/null || { echo -e "  ${Y}openssl non disponible${N}"; return; }
    local expiry
    expiry=$(echo | openssl s_client -connect "${domain}:443" \
             -servername "${domain}" 2>/dev/null \
             | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry" ]]; then
        echo -e "  ${Y}Pas de HTTPS détecté sur ${domain}${N}"; return
    fi
    local diff_days; diff_days=$(( ($(date -d "$expiry" +%s 2>/dev/null) - $(date +%s)) / 86400 ))
    [[ $diff_days -le 14 ]] \
        && echo -e "  ${R}⚠  SSL expire dans ${diff_days}j (${expiry})${N}" \
        || echo -e "  ${G}✔${N} SSL valide encore ${diff_days} jours"
}

# ============================================================
#  9 — VÉRIFICATION GÉNÉRALE & DROITS (HEALTH)
# ============================================================

# ── Indicateur visuel générique ──────────────────────────────
declare -g _H_OK=0 _H_WARN=0 _H_ERR=0

_chk() {
    local label="$1" status="$2" msg="$3"
    case "$status" in
        ok)   printf "  ${G}✔${N}  %-28s %s\n" "${label}" "${msg}"; ((_H_OK++)) ;;
        warn) printf "  ${Y}⚠${N}  %-28s %s\n" "${label}" "${msg}"; ((_H_WARN++)) ;;
        err)  printf "  ${R}✘${N}  %-28s %s\n" "${label}" "${msg}"; ((_H_ERR++)) ;;
    esac
}

show_health() {
    header; section "Vérification générale"
    _H_OK=0; _H_WARN=0; _H_ERR=0

    # ── PHP ──
    local php_ver; php_ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
    if [[ -n "$php_ver" ]]; then
        local php_major; php_major=$(echo "$php_ver" | cut -d. -f1)
        [[ $php_major -ge 8 ]] \
            && _chk "PHP" ok "$php_ver" \
            || _chk "PHP" warn "$php_ver (< 8.x recommandé)"
    else
        _chk "PHP" err "non détecté"
    fi

    # ── MySQL connexion ──
    load_mysql_creds
    if mysql_cmd -e "SELECT 1;" &>/dev/null; then
        _chk "MySQL" ok "connecté (${DB_NAME})"
    else
        _chk "MySQL" err "connexion impossible"
    fi

    # ── Services web ──
    for svc in apache2 nginx; do
        systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}" || continue
        local st; st=$(systemctl is-active "$svc" 2>/dev/null)
        [[ "$st" == "active" ]] && _chk "$svc" ok "actif" || _chk "$svc" err "$st"
    done

    # ── Services DB ──
    for svc in mysql mariadb; do
        systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}" || continue
        local st; st=$(systemctl is-active "$svc" 2>/dev/null)
        [[ "$st" == "active" ]] && _chk "$svc" ok "actif" || _chk "$svc" err "$st"
    done

    # ── Daemon Jeedom ──
    pgrep -f "jeedom.php" &>/dev/null \
        && _chk "Daemon Jeedom" ok "actif" \
        || _chk "Daemon Jeedom" err "introuvable"

    # ── Disque ──
    local disk_pct; disk_pct=$(df "${JEEDOM_DIR}" | awk 'NR==2{gsub(/%/,""); print $5}')
    local disk_info; disk_info=$(df -h "${JEEDOM_DIR}" | awk 'NR==2{print $3"/"$2" ("$5")"}')
    if   [[ $disk_pct -ge 90 ]]; then _chk "Disque"    err  "$disk_info"
    elif [[ $disk_pct -ge 75 ]]; then _chk "Disque"    warn "$disk_info"
    else                               _chk "Disque"    ok   "$disk_info"
    fi

    # ── RAM ──
    local ram_used ram_total ram_pct
    read -r ram_total ram_used < <(free -m | awk '/^Mem:/{print $2,$3}')
    ram_pct=$(( ram_used * 100 / (ram_total + 1) ))
    local ram_info="${ram_used}M / ${ram_total}M (${ram_pct}%)"
    [[ $ram_pct -ge 90 ]] \
        && _chk "RAM" warn "$ram_info" \
        || _chk "RAM" ok   "$ram_info"

    # ── Charge CPU ──
    local load1; load1=$(awk '{print $1}' /proc/loadavg)
    local cpus; cpus=$(nproc 2>/dev/null || echo 1)
    local load_int; load_int=$(echo "$load1 * 100 / $cpus" | bc 2>/dev/null || echo 0)
    if   [[ $load_int -ge 150 ]]; then _chk "CPU load"  err  "${load1} (${cpus} cœurs)"
    elif [[ $load_int -ge 80  ]]; then _chk "CPU load"  warn "${load1} (${cpus} cœurs)"
    else                               _chk "CPU load"  ok   "${load1} (${cpus} cœurs)"
    fi

    # ── Dernière sauvegarde ──
    local latest_bk; latest_bk=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$latest_bk" ]]; then
        _chk "Sauvegarde" warn "aucune trouvée"
    else
        local age; age=$(( ($(date +%s) - $(stat -c %Y "$latest_bk" 2>/dev/null || echo 0)) / 86400 ))
        local bk_name; bk_name=$(basename "$latest_bk")
        if   [[ $age -le 1 ]]; then _chk "Sauvegarde" ok   "${age}j — ${bk_name}"
        elif [[ $age -le 7 ]]; then _chk "Sauvegarde" warn "${age}j — ${bk_name}"
        else                        _chk "Sauvegarde" err  "${age}j — ${bk_name}"
        fi
    fi

    # ── Permissions (échantillon) ──
    local bad_perms; bad_perms=$(find "${JEEDOM_DIR}" -maxdepth 3 \
        ! -user www-data 2>/dev/null | grep -v "^${JEEDOM_DIR}$" | wc -l)
    if   [[ $bad_perms -eq 0 ]]; then _chk "Permissions" ok   "OK"
    elif [[ $bad_perms -le 10 ]]; then _chk "Permissions" warn "${bad_perms} fichier(s) non www-data"
    else                               _chk "Permissions" err  "${bad_perms} fichiers non www-data"
    fi

    # ── Log d'erreurs récentes ──
    local err_count=0
    [[ -f "${LOG_DIR}/http.error" ]] && \
        err_count=$(wc -l < "${LOG_DIR}/http.error" 2>/dev/null || echo 0)
    [[ $err_count -gt 100 ]] \
        && _chk "http.error" warn "${err_count} lignes" \
        || _chk "http.error" ok   "${err_count} lignes"

    # ── SSL ──
    local domain; domain=$(hostname -f 2>/dev/null || hostname)
    command -v openssl &>/dev/null && {
        local expiry
        expiry=$(echo | openssl s_client -connect "${domain}:443" \
                 -servername "${domain}" 2>/dev/null \
                 | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -z "$expiry" ]]; then
            _chk "SSL ${domain}" warn "HTTPS non détecté"
        else
            local diff_days; diff_days=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))
            [[ $diff_days -le 14 ]] \
                && _chk "SSL" warn "expire dans ${diff_days}j" \
                || _chk "SSL" ok   "valide ${diff_days}j"
        fi
    }

    # ── Noyau / mises à jour apt ──
    local apt_upgradable=0
    apt_upgradable=$(apt list --upgradable 2>/dev/null | grep -c "^" || echo 0)
    [[ $apt_upgradable -gt 0 ]] && ((apt_upgradable--))  # retirer la ligne "Listing..."
    [[ $apt_upgradable -gt 20 ]] \
        && _chk "Paquets système" warn "${apt_upgradable} mise(s) à jour disponible(s)" \
        || _chk "Paquets système" ok   "${apt_upgradable} mise(s) à jour disponible(s)"

    # ── Résumé ──
    echo
    echo -e "  ${B}────────────────────────────────────────────${N}"
    printf "  ${G}✔ %-3s OK${N}   ${Y}⚠ %-3s avertissement(s)${N}   ${R}✘ %-3s erreur(s)${N}\n" \
        "$_H_OK" "$_H_WARN" "$_H_ERR"

    if [[ $_H_ERR -gt 0 || $_H_WARN -gt 0 ]]; then
        echo
        echo -e "  ${Y}→  Pensez à utiliser « Rétablissement des droits »${N}"
        echo -e "     ${Y}si des erreurs de permissions sont signalées.${N}"
    fi
    pause
}

# ── Rétablissement des droits ────────────────────────────────

fix_permissions() {
    header; section "Rétablissement des droits"
    echo -e "  Cible : ${W}${JEEDOM_DIR}${N}"
    echo -e "  Cette opération applique les permissions Jeedom standard.\n"
    echo -e "  ${W}Droits appliqués :${N}"
    echo -e "  • Propriétaire  : ${C}www-data:www-data${N} (récursif)"
    echo -e "  • Dossiers      : ${C}755${N}"
    echo -e "  • Fichiers      : ${C}644${N}"
    echo -e "  • log/backup/tmp/cache : ${C}775${N}"
    echo -e "  • Scripts .sh   : ${C}755${N}"
    echo -e "  • jeedom.php CLI: ${C}755${N}"
    echo

    confirm "Appliquer les droits Jeedom standard" || { echo -e "${Y}Annulé.${N}"; pause; return; }
    echo

    local -a steps=(
        "Propriétaire www-data:www-data (récursif)"
        "Dossiers chmod 755"
        "Fichiers chmod 644"
        "log / backup / tmp / cache : chmod 775"
        "Scripts shell (.sh) : chmod 755"
        "jeedom.php CLI : chmod 755"
    )
    local -a cmds=(
        "chown -R www-data:www-data '${JEEDOM_DIR}'"
        "find '${JEEDOM_DIR}' -type d -exec chmod 755 {} +"
        "find '${JEEDOM_DIR}' -type f -exec chmod 644 {} +"
        "_fix_var_dirs"
        "find '${JEEDOM_DIR}' -name '*.sh' -exec chmod 755 {} +"
        "find '${JEEDOM_DIR}' -path '*/php/jeedom.php' -exec chmod 755 {} +"
    )

    local i
    for i in "${!steps[@]}"; do
        echo -ne "  ${DIM}${steps[$i]}...${N} "
        if [[ "${cmds[$i]}" == "_fix_var_dirs" ]]; then
            local ok=true
            for d in log backup tmp cache; do
                [[ -d "${JEEDOM_DIR}/${d}" ]] \
                    && chmod -R 775 "${JEEDOM_DIR}/${d}" 2>/dev/null \
                    || true
            done
        else
            eval "${cmds[$i]}" 2>/dev/null || true
        fi
        echo -e "${G}✔${N}"
    done

    echo -e "\n${G}✔ Droits rétablis avec succès.${N}"
    log_action "fix_permissions exécuté"
    pause
}

# Sous-menu santé
menu_health() {
    local opts=(
        "🔍  Vérification générale (health check)"
        "🔑  Rétablissement des droits fichiers/dossiers"
        "↩  Retour"
    )
    while true; do
        nav_menu "Santé & Droits" "${opts[@]}"
        case $MENU_RESULT in
            -1|2) return ;;
            0) show_health      ;;
            1) fix_permissions  ;;
        esac
    done
}

# ============================================================
#  2 — SAUVEGARDES
# ============================================================

menu_backups() {
    local opts=(
        "📋  Lister les sauvegardes"
        "➕  Créer une sauvegarde"
        "📤  Restaurer une sauvegarde"
        "🗑️   Supprimer une sauvegarde"
        "🔄  Rotation (garder ${MAX_BACKUPS} dernières)"
        "↩  Retour"
    )
    while true; do
        nav_menu "Sauvegardes" "${opts[@]}"
        case $MENU_RESULT in
            -1|5) return ;;
            0) _backup_list    ;;
            1) _backup_create  ;;
            2) _backup_restore ;;
            3) _backup_delete  ;;
            4) _backup_rotate  ;;
        esac
    done
}

_backup_list() {
    header; section "Sauvegardes disponibles"
    local files=("${BACKUP_DIR}"/*.tar.gz)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${Y}Aucune sauvegarde.${N}"
    else
        printf "  ${W}%-48s %s${N}\n" "Fichier" "Taille"
        echo -e "  ${B}──────────────────────────────────────────────────────${N}"
        for f in "${BACKUP_DIR}"/*.tar.gz; do
            printf "  %-48s %s\n" "$(basename "$f")" "$(du -sh "$f" | cut -f1)"
        done
    fi
    pause
}

_backup_create() {
    header; section "Création sauvegarde"
    echo -e "${Y}En cours...${N}"
    ${PHP_CLI} action=backup 2>&1
    if [[ $? -eq 0 ]]; then
        local latest; latest=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -1)
        echo -e "${G}✔ $(basename "${latest}")${N}"
        log_action "BACKUP: ${latest}"
    else
        echo -e "${R}✘ Erreur lors de la sauvegarde${N}"
    fi
    pause
}

_backup_restore() {
    header; section "Restauration"
    pick_file_nav "Choisir la sauvegarde à restaurer" "${BACKUP_DIR}/*.tar.gz" || { pause; return; }
    echo
    echo -e "${R}⚠  Cette opération écrasera la configuration actuelle !${N}"
    confirm "Restaurer $(basename "${PICKED_FILE}")" || { echo -e "${Y}Annulé.${N}"; pause; return; }
    echo
    ${PHP_CLI} action=restore backup="${PICKED_FILE}" 2>&1
    [[ $? -eq 0 ]] \
        && { echo -e "${G}✔ Restauration terminée.${N}"; log_action "RESTORE: ${PICKED_FILE}"; } \
        || echo -e "${R}✘ Erreur lors de la restauration${N}"
    pause
}

_backup_delete() {
    header; section "Suppression sauvegarde"
    pick_file_nav "Choisir la sauvegarde à supprimer" "${BACKUP_DIR}/*.tar.gz" || { pause; return; }
    confirm "Supprimer $(basename "${PICKED_FILE}")" || { echo -e "${Y}Annulé.${N}"; return; }
    rm -f "${PICKED_FILE}" \
        && { echo -e "${G}✔ Supprimé.${N}"; log_action "BACKUP del: ${PICKED_FILE}"; } \
        || echo -e "${R}✘ Erreur${N}"
    pause
}

_backup_rotate() {
    header; section "Rotation — ${MAX_BACKUPS} dernières conservées"
    mapfile -t _all < <(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null)
    if [[ ${#_all[@]} -le $MAX_BACKUPS ]]; then
        echo -e "${G}Rien à supprimer (${#_all[@]} sauvegarde(s) présente(s)).${N}"; pause; return
    fi
    local del=("${_all[@]:${MAX_BACKUPS}}")
    echo -e "  Fichiers à supprimer :"
    printf '  %s\n' "${del[@]}"
    echo
    confirm "Supprimer ${#del[@]} fichier(s)" || { echo -e "${Y}Annulé.${N}"; pause; return; }
    for f in "${del[@]}"; do
        rm -f "$f" && echo -e "  ${G}✔${N} $(basename "$f")"
        log_action "BACKUP rotate del: $f"
    done
    pause
}

# ============================================================
#  3 — BASE DE DONNÉES
# ============================================================

menu_database() {
    local opts=(
        "📊  Analyser   (ANALYZE TABLE)"
        "🔧  Réparer    (REPAIR TABLE)"
        "⚡  Optimiser  (OPTIMIZE TABLE)"
        "📏  Taille des tables"
        "🔍  mysqlcheck complet (--auto-repair)"
        "💾  Dump SQL complet"
        "📥  Importer un dump"
        "🧹  Vider le cache Jeedom"
        "↩  Retour"
    )
    while true; do
        nav_menu "Base de données" "${opts[@]}"
        case $MENU_RESULT in
            -1|8) return ;;
            0) _db_all_tables "ANALYZE"   ;;
            1) _db_all_tables "REPAIR"    ;;
            2) _db_all_tables "OPTIMIZE"  ;;
            3) _db_sizes                  ;;
            4) _db_mysqlcheck             ;;
            5) _db_dump                   ;;
            6) _db_import                 ;;
            7) _db_flush_cache            ;;
        esac
    done
}

_db_all_tables() {
    local cmd="$1"
    header; section "${cmd} TABLE"
    echo -e "${Y}${cmd} en cours...${N}\n"
    while IFS= read -r tbl; do
        local res; res=$(mysql_cmd -N -e "${cmd} TABLE \`${tbl}\`;" | awk '{print $NF}')
        printf "  %-35s %s\n" "${tbl}" "${res}"
    done < <(mysql_cmd -N -e "SHOW TABLES;")
    echo -e "\n${G}✔ ${cmd} terminé.${N}"
    log_action "DB ${cmd}"
    pause
}

_db_sizes() {
    header; section "Taille des tables"
    load_mysql_creds
    mysql_cmd -e "SELECT table_name 'Table',
                         ROUND((data_length+index_length)/1024/1024,2) 'Mo',
                         table_rows 'Lignes'
                  FROM information_schema.tables
                  WHERE table_schema='${DB_NAME}'
                  ORDER BY (data_length+index_length) DESC;"
    pause
}

_db_mysqlcheck() {
    header; section "mysqlcheck --auto-repair"
    load_mysql_creds
    mysqlcheck -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASS}" \
               --auto-repair --check "${DB_NAME}" 2>/dev/null
    echo -e "\n${G}✔ Terminé.${N}"
    log_action "DB mysqlcheck"
    pause
}

_db_dump() {
    header; section "Dump MySQL"
    load_mysql_creds
    local file="${BACKUP_DIR}/dump_${DB_NAME}_$(date +%Y%m%d-%H%M%S).sql.gz"
    echo -e "${Y}Dump vers : $(basename "${file}")${N}"
    mysqldump -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASS}" \
              "${DB_NAME}" 2>/dev/null | gzip > "${file}"
    [[ $? -eq 0 ]] \
        && { echo -e "${G}✔ Dump créé.${N}"; log_action "DB DUMP: ${file}"; } \
        || echo -e "${R}✘ Erreur${N}"
    pause
}

_db_import() {
    header; section "Import dump SQL"
    pick_file_nav "Choisir le dump à importer" "${BACKUP_DIR}/dump_*.sql.gz" || { pause; return; }
    echo
    echo -e "${R}⚠  Écrasera la base ${DB_NAME} !${N}"
    confirm "Importer $(basename "${PICKED_FILE}")" || { echo -e "${Y}Annulé.${N}"; pause; return; }
    load_mysql_creds
    zcat "${PICKED_FILE}" \
        | mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASS}" \
                "${DB_NAME}" 2>/dev/null
    [[ $? -eq 0 ]] \
        && { echo -e "${G}✔ Import terminé.${N}"; log_action "DB IMPORT: ${PICKED_FILE}"; } \
        || echo -e "${R}✘ Erreur${N}"
    pause
}

_db_flush_cache() {
    header; section "Cache Jeedom"
    ${PHP_CLI} action=clearCache 2>&1
    echo -e "${G}✔ Cache vidé.${N}"
    log_action "Cache Jeedom vidé"
    pause
}

# ============================================================
#  4 — SERVICES
# ============================================================

menu_services() {
    local opts=(
        "📡  État des services"
        "🌐  Redémarrer Apache / Nginx"
        "🗄️   Redémarrer MySQL / MariaDB"
        "⚙️   Redémarrer daemon Jeedom (cron)"
        "🔄  Relancer Jeedom complet"
        "💻  Reboot serveur"
        "↩  Retour"
    )
    while true; do
        nav_menu "Services & Jeedom" "${opts[@]}"
        case $MENU_RESULT in
            -1|6) return ;;
            0) _svc_status ;;
            1) header; section "Redémarrage Apache/Nginx"
               for s in apache2 nginx; do svc_ctl restart "$s"; done; pause ;;
            2) header; section "Redémarrage MySQL/MariaDB"
               for s in mysql mariadb; do svc_ctl restart "$s"; done; pause ;;
            3) header; section "Redémarrage daemon Jeedom"
               ${PHP_CLI} action=stopCron 2>&1; sleep 2
               ${PHP_CLI} action=startCron 2>&1
               echo -e "${G}✔ Daemon relancé.${N}"; log_action "Daemon Jeedom restart"; pause ;;
            4) header
               confirm "Relancer Jeedom complet" \
                   && { ${PHP_CLI} action=restart 2>&1; log_action "Jeedom restart"; echo -e "${G}✔${N}"; } \
                   || echo -e "${Y}Annulé.${N}"
               pause ;;
            5) _server_reboot ;;
        esac
    done
}

_svc_status() {
    header; section "État des services"
    for svc in apache2 nginx mysql mariadb php8.2-fpm php8.3-fpm; do
        systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}" || continue
        local st; st=$(systemctl is-active "${svc}" 2>/dev/null)
        [[ "${st}" == "active" ]] \
            && echo -e "  ${G}● ACTIF ${N} ${svc}" \
            || echo -e "  ${R}● ${st^^}${N}  ${svc}"
    done
    pause
}

_server_reboot() {
    header
    echo -e "\n${R}⚠  Le serveur va redémarrer !${N}\n"
    confirm "Confirmer le reboot" && { log_action "REBOOT"; reboot; } \
        || echo -e "${Y}Annulé.${N}"
    pause
}

# ============================================================
#  5 — LOGS & AUDIT
# ============================================================

menu_logs() {
    local opts=(
        "📋  Lister les logs"
        "👁️   Afficher un log (50 lignes)"
        "📡  Suivre un log en temps réel (tail -f)"
        "🗑️   Vider tous les logs"
        "🔧  Journalctl système"
        "📒  Journal des actions (audit)"
        "↩  Retour"
    )
    while true; do
        nav_menu "Logs & Audit" "${opts[@]}"
        case $MENU_RESULT in
            -1|6) return ;;
            0) header; section "Liste des logs"
               find "${LOG_DIR}" -maxdepth 1 -type f 2>/dev/null | sort \
                   | while read -r f; do
                       printf "  %-40s %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
                   done
               pause ;;
            1) header; section "Afficher un log"
               pick_file_nav "Choisir le log" "${LOG_DIR}/*" \
                   && { echo; tail -50 "${PICKED_FILE}"; pause; } \
                   || pause ;;
            2) header; section "Suivi en temps réel"
               pick_file_nav "Choisir le log" "${LOG_DIR}/*" \
                   && { echo -e "${DIM}(Ctrl+C pour arrêter)${N}"; tail -f "${PICKED_FILE}"; } \
                   || pause ;;
            3) header
               confirm "Vider TOUS les logs Jeedom" \
                   && { find "${LOG_DIR}" -maxdepth 1 -type f \
                             -exec truncate -s 0 {} \;
                        echo -e "${G}✔ Logs vidés.${N}"; log_action "Logs vidés"; } \
                   || echo -e "${Y}Annulé.${N}"
               pause ;;
            4) header; section "Journalctl système (50 dernières lignes)"
               journalctl -n 50 --no-pager 2>/dev/null; pause ;;
            5) header; section "Journal d'audit"
               [[ -f "${AUDIT_LOG}" ]] \
                   && tail -40 "${AUDIT_LOG}" \
                   || echo -e "${Y}Aucune action enregistrée.${N}"
               pause ;;
        esac
    done
}

# ============================================================
#  6 — RÉSEAU & SSL
# ============================================================

menu_network() {
    local opts=(
        "🌐  Interfaces réseau"
        "📡  Test connectivité internet"
        "🔌  Ports en écoute"
        "🔗  Connexions actives"
        "📶  Ping une adresse"
        "🔒  Vérifier SSL d'un domaine"
        "↩  Retour"
    )
    while true; do
        nav_menu "Réseau & SSL" "${opts[@]}"
        case $MENU_RESULT in
            -1|6) return ;;
            0) header; section "Interfaces réseau"
               ip -4 addr show; echo; ip route | grep default; pause ;;
            1) header; section "Test connectivité"
               for h in 8.8.8.8 1.1.1.1 google.com jeedom.com; do
                   ping -c1 -W2 "${h}" &>/dev/null \
                       && echo -e "  ${G}✔${N} ${h}" \
                       || echo -e "  ${R}✘${N} ${h}"
               done; pause ;;
            2) header; section "Ports en écoute"
               ss -tlnp 2>/dev/null; pause ;;
            3) header; section "Connexions actives"
               ss -tnp 2>/dev/null | grep ESTAB | head -20; pause ;;
            4) header; section "Ping"
               _cursor_show
               read -rp "$(echo -e "${Y}Adresse : ${N}")" addr
               ping -c4 "${addr}"; pause ;;
            5) header; section "Vérification SSL"
               _cursor_show
               read -rp "$(echo -e "${Y}Domaine : ${N}")" d
               echo; _ssl_check "$d"; pause ;;
        esac
    done
}

# ============================================================
#  7 — MISES À JOUR & SÉCURITÉ
# ============================================================

menu_updates() {
    local opts=(
        "🔍  Vérifier mises à jour Jeedom"
        "⬆️   Mettre à jour Jeedom (core)"
        "📦  apt update + upgrade"
        "🔒  Configurer unattended-upgrades"
        "🧪  Dry-run unattended-upgrades"
        "📊  Statut unattended-upgrades"
        "↩  Retour"
    )
    while true; do
        nav_menu "Mises à jour & Sécurité" "${opts[@]}"
        case $MENU_RESULT in
            -1|6) return ;;
            0) header; ${PHP_CLI} action=update 2>&1; pause ;;
            1) header
               confirm "Mettre à jour Jeedom" \
                   && { ${PHP_CLI} action=doUpdate 2>&1; log_action "Jeedom doUpdate"; } \
                   || echo -e "${Y}Annulé.${N}"
               pause ;;
            2) header; section "apt update + upgrade"
               apt-get update 2>&1 | tail -5
               apt-get upgrade -y 2>&1
               echo -e "\n${G}✔ Système à jour.${N}"; log_action "apt upgrade"; pause ;;
            3) _unattended_setup  ;;
            4) _unattended_dryrun ;;
            5) _unattended_status ;;
        esac
    done
}

_unatd_set() {
    local file="$1" old="$2" new="$3"
    if grep -qF "${old}" "$file" 2>/dev/null; then
        sed -i "s|${old}|${old}\n${new}|" "$file"
        echo -e "  ${G}✔${N} ${new}"
    else
        echo -e "  ${Y}–${N} Déjà actif ou non trouvé : ${new}"
    fi
}

_unattended_setup() {
    header; section "Installation & configuration unattended-upgrades"
    apt-get install -y unattended-upgrades apt-listchanges debconf-utils 2>&1
    export PATH=$PATH:/usr/sbin
    dpkg-reconfigure --priority=low unattended-upgrades
    local conf="/etc/apt/apt.conf.d/50unattended-upgrades"
    [[ ! -f "$conf" ]] && { echo -e "${R}Fichier conf introuvable.${N}"; pause; return; }
    echo -e "\n${Y}Application configuration recommandée (communauté Jeedom)...${N}"
    _unatd_set "$conf" '//Unattended-Upgrade::Automatic-Reboot "false";'               'Unattended-Upgrade::Automatic-Reboot "true";'
    _unatd_set "$conf" '//Unattended-Upgrade::Automatic-Reboot-WithUsers "true";'     'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";'
    _unatd_set "$conf" '//Unattended-Upgrade::Automatic-Reboot-Time "02:00";'         'Unattended-Upgrade::Automatic-Reboot-Time "05:00";'
    _unatd_set "$conf" '//Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'  'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'
    _unatd_set "$conf" '//Unattended-Upgrade::Remove-New-Unused-Dependencies "true";' 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";'
    _unatd_set "$conf" '//Unattended-Upgrade::Remove-Unused-Dependencies "false";'    'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
    echo -e "\n${G}✔ Configuré — reboot à 5h UTC si patch kernel nécessaire.${N}"
    log_action "unattended-upgrades configuré"
    pause
}

_unattended_dryrun() {
    header; section "Dry-run unattended-upgrades"
    command -v unattended-upgrade &>/dev/null \
        && unattended-upgrade --dry-run --debug 2>&1 | tail -30 \
        || echo -e "${R}unattended-upgrades non installé.${N}"
    pause
}

_unattended_status() {
    header; section "Statut unattended-upgrades"
    systemctl status unattended-upgrades --no-pager 2>/dev/null | head -10
    echo
    local latest; latest=$(ls -t /var/log/unattended-upgrades/unattended-upgrades.log* 2>/dev/null | head -1)
    [[ -n "$latest" ]] \
        && { echo -e "${W}Dernier log :${N}"; tail -15 "$latest"; } \
        || echo -e "${Y}Aucun log trouvé.${N}"
    pause
}

# ============================================================
#  8 — NETTOYAGE
# ============================================================

menu_cleanup() {
    local opts=(
        "🗑️   Vieilles sauvegardes (> ${MAX_BACKUPS} jours)"
        "🧹  Nettoyer /tmp"
        "💿  Analyse espace disque"
        "⚡  Vider OPcache PHP"
        "📦  apt autoremove"
        "↩  Retour"
    )
    while true; do
        nav_menu "Nettoyage" "${opts[@]}"
        case $MENU_RESULT in
            -1|5) return ;;
            0) header; section "Vieilles sauvegardes"
               local found; found=$(find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +${MAX_BACKUPS} 2>/dev/null)
               if [[ -z "$found" ]]; then
                   echo -e "${G}Rien à supprimer.${N}"
               else
                   echo "${found}"
                   echo
                   confirm "Supprimer ces fichiers" \
                       && { find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +${MAX_BACKUPS} -delete
                            echo -e "${G}✔ Supprimés.${N}"; log_action "Old backups purged"; } \
                       || echo -e "${Y}Annulé.${N}"
               fi; pause ;;
            1) header; section "Nettoyage /tmp"
               local b; b=$(du -sh /tmp 2>/dev/null | cut -f1)
               find /tmp -maxdepth 1 -mtime +1 -not -name "." -exec rm -rf {} + 2>/dev/null
               echo -e "  Avant : ${Y}${b}${N}  →  Après : ${G}$(du -sh /tmp 2>/dev/null | cut -f1)${N}"
               pause ;;
            2) header; section "Espace disque"
               du -sh "${JEEDOM_DIR}/"* 2>/dev/null | sort -rh | head -10
               echo; df -h /; pause ;;
            3) header; section "OPcache PHP"
               php -r "opcache_reset() ? print 'OPcache vidé.\n' : print 'OPcache N/A.\n';" 2>/dev/null
               pause ;;
            4) header; section "apt autoremove"
               apt-get autoremove -y 2>&1; pause ;;
        esac
    done
}

# ============================================================
#  MODE CLI NON-INTERACTIF
# ============================================================

cli_mode() {
    check_root; check_jeedom
    case "$1" in
        --backup)
            echo "[CLI] Sauvegarde..."
            ${PHP_CLI} action=backup 2>&1
            log_action "CLI --backup" ;;
        --repair-db)
            echo "[CLI] Réparation DB..."
            _db_all_tables "REPAIR" ;;
        --check)
            echo "[CLI] Vérification système..."
            _H_OK=0; _H_WARN=0; _H_ERR=0
            _watchdog_check
            _ssl_check "$(hostname -f 2>/dev/null || hostname)" ;;
        --health)
            echo "[CLI] Health check complet..."
            _H_OK=0; _H_WARN=0; _H_ERR=0
            show_health ;;
        --fix-perms)
            echo "[CLI] Rétablissement des droits..."
            fix_permissions ;;
        --upgrade-security)
            echo "[CLI] unattended-upgrade..."
            command -v unattended-upgrade &>/dev/null \
                && { unattended-upgrade --debug 2>&1; log_action "CLI --upgrade-security"; } \
                || echo "unattended-upgrades non installé." ;;
        *)
            echo "Usage: sudo bash $0 [option]"
            echo "  --backup            Lancer une sauvegarde"
            echo "  --repair-db         Réparer la base de données"
            echo "  --check             Vérification rapide"
            echo "  --health            Health check complet"
            echo "  --fix-perms         Rétablir les droits fichiers"
            echo "  --upgrade-security  unattended-upgrade"
            exit 1 ;;
    esac
    exit 0
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================

main_menu() {
    local opts=(
        "📊  Informations système & watchdog"
        "🏥  Santé générale & droits fichiers"
        "💾  Sauvegardes"
        "🗄️   Base de données"
        "⚙️   Services & Jeedom"
        "📋  Logs & audit"
        "🌐  Réseau & SSL"
        "🔄  Mises à jour & sécurité"
        "🧹  Nettoyage"
        "❌  Quitter"
    )

    while true; do
        nav_menu "Menu principal" "${opts[@]}"
        case $MENU_RESULT in
            -1|9) _exit_clean ;;
            0) show_system_info ;;
            1) menu_health      ;;
            2) menu_backups     ;;
            3) menu_database    ;;
            4) menu_services    ;;
            5) menu_logs        ;;
            6) menu_network     ;;
            7) menu_updates     ;;
            8) menu_cleanup     ;;
        esac
    done
}

# ── Point d'entrée ───────────────────────────────────────────
[[ -n "$1" ]] && cli_mode "$@"
check_root
check_jeedom
main_menu
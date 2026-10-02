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
readonly CORE_INC="${JEEDOM_DIR}/core/php/core.inc.php"
readonly JEECRON="${JEEDOM_DIR}/core/php/jeeCron.php"
readonly AUDIT_LOG="/var/log/jeedom-menu.log"
readonly MAX_BACKUPS=7

# ── Couleurs ─────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' N='\033[0m'
DIM='\033[2m'

# ── Cache MySQL ──────────────────────────────────────────────
declare -g _DB_LOADED=0
declare -g DB_HOST DB_PORT DB_NAME DB_USER DB_PASS DB_OPTFILE

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

_cleanup_optfile() {
    [[ -n "${DB_OPTFILE:-}" && -f "${DB_OPTFILE}" ]] && rm -f "${DB_OPTFILE}"
}

_on_exit() { _cursor_show; _cleanup_optfile; }

trap '_exit_clean' INT TERM
trap '_on_exit' EXIT

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
                # Affectation arithmétique (jamais un post-/pré-incrément ((…))) :
                # ((sel++)) renvoie la valeur AVANT incrément comme statut de sortie,
                # donc un sel=0 fait échouer le && et déclenche aussi le || qui suit.
                [[ $sel -gt 0 ]] && sel=$((sel - 1)) || sel=$((total - 1))
                ;;
            down)
                [[ $sel -lt $((total - 1)) ]] && sel=$((sel + 1)) || sel=0
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
    # Lu via PHP natif (require du fichier de config réel) plutôt que grep/sed :
    # le format ('db' => array('host' => ...)) est un tableau PHP imbriqué,
    # pas des clés plates 'db:host', et un parsing texte fragile se désynchronise
    # silencieusement à chaque évolution du format core.
    local raw
    raw=$(CONF_FILE_PATH="${CONF_FILE}" php -r '
        $CONFIG = [];
        $f = getenv("CONF_FILE_PATH");
        if ($f && is_file($f)) { require $f; }
        $db = $CONFIG["db"] ?? [];
        echo ($db["host"] ?? "") . "\x1f";
        echo ($db["port"] ?? "") . "\x1f";
        echo ($db["dbname"] ?? "") . "\x1f";
        echo ($db["username"] ?? "") . "\x1f";
        echo ($db["password"] ?? "");
    ' 2>/dev/null)
    IFS=$'\x1f' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASS <<< "${raw}"
    DB_PORT=${DB_PORT:-3306}
    # Fichier d'options temporaire (0600) : évite d'exposer le mot de passe
    # dans la liste des processus (ps) via -p<pass> en argument.
    DB_OPTFILE=$(mktemp)
    chmod 600 "${DB_OPTFILE}"
    {
        echo "[client]"
        echo "host=${DB_HOST}"
        echo "port=${DB_PORT}"
        echo "user=${DB_USER}"
        echo "password=${DB_PASS}"
    } > "${DB_OPTFILE}"
    _DB_LOADED=1
}

mysql_cmd() {
    load_mysql_creds
    mysql --defaults-extra-file="${DB_OPTFILE}" "${DB_NAME}" "$@" 2>/dev/null
}

svc_ctl() {
    local action="$1" svc="$2"
    systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}" \
        || { echo -e "${Y}Service ${svc} absent.${N}"; return 1; }
    systemctl "${action}" "${svc}" \
        && echo -e "${G}✔ ${svc} ${action} OK${N}" \
        || echo -e "${R}✘ Erreur ${svc} ${action}${N}"
}

# ── API PHP Jeedom (remplace l'ancien jeedom.php, absent depuis 4.6) ────
#  jeedom.php n'existe plus : seul core/php/jeecli.php subsiste, et il ne
#  couvre que plugin/user/message/backup-restore-list (voir son code), pas
#  backup-create, clearCache, cron start/stop ni update/doUpdate. Pour ces
#  actions on appelle donc directement les classes core via `php -r`,
#  exécuté en www-data (comme /etc/cron.d/jeedom) pour ne jamais créer de
#  fichiers appartenant à root sous ${JEEDOM_DIR}.
_jee_php() {
    sudo -u www-data php -r "require '${CORE_INC}'; $1" 2>&1
}

#  Variante permettant de passer une valeur dynamique (ex: chemin de backup)
#  via l'environnement plutôt que de l'interpoler dans le code PHP — évite
#  tout souci d'échappement si la valeur contient guillemets/espaces.
_jee_php_env() {
    local envassign="$1" code="$2"
    sudo -u www-data env "${envassign}" php -r "require '${CORE_INC}'; ${code}" 2>&1
}

#  État du master jeeCron — remplace pgrep -f "jeedom.php" (fichier
#  inexistant en 4.6, donc le pgrep ne matchait jamais). Réplique exactement
#  la détection native cron::jeeCronRun() (lit le PID dans
#  jeedom::getTmpFolder().'/jeeCron.pid' et vérifie que le process est
#  vivant via posix_getsid), telle qu'utilisée par core/php/jeeCron.php
#  lui-même avant de devenir master.
_daemon_running() {
    sudo -u www-data php -r "require '${CORE_INC}'; exit(cron::jeeCronRun() ? 0 : 1);" 2>/dev/null
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
    _daemon_running \
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
        ok)   printf "  ${G}✔${N}  %-28s %s\n" "${label}" "${msg}"; _H_OK=$((_H_OK + 1)) ;;
        warn) printf "  ${Y}⚠${N}  %-28s %s\n" "${label}" "${msg}"; _H_WARN=$((_H_WARN + 1)) ;;
        err)  printf "  ${R}✘${N}  %-28s %s\n" "${label}" "${msg}"; _H_ERR=$((_H_ERR + 1)) ;;
    esac
}

show_health() {
    local mode="${1:-interactive}"
    [[ "$mode" == "interactive" ]] && header
    section "Vérification générale"
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
    _daemon_running \
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
    [[ "$mode" == "interactive" ]] && pause
    [[ $_H_ERR -gt 0 ]] && return 2
    [[ $_H_WARN -gt 0 ]] && return 1
    return 0
}

# ── Rétablissement des droits ────────────────────────────────

#  Reproduit le comportement natif de jeedom::cleanFileSystemRight()
#  (bouton "Rétablissement des droits" du core) : chown www-data,
#  chmod 775 récursif (y compris fichiers cachés), 665 sur les logs.
#  Chaque étape est vérifiée ; le succès n'est annoncé que si tout a réussi.
fix_permissions() {
    local mode="${1:-interactive}"
    [[ "$mode" == "interactive" ]] && { header; section "Rétablissement des droits"
        echo -e "  Cible : ${W}${JEEDOM_DIR}${N}"
        echo -e "  Reproduit le comportement natif Jeedom (bouton core « Rétablir les droits »).\n"
        echo -e "  ${W}Droits appliqués :${N}"
        echo -e "  • Propriétaire : ${C}www-data:www-data${N} (récursif)"
        echo -e "  • Tout         : ${C}775${N} (récursif, y compris fichiers cachés)"
        echo -e "  • log/*        : ${C}665${N}"
        echo
        confirm "Appliquer les droits Jeedom standard" || { echo -e "${Y}Annulé.${N}"; pause; return 1; }
        echo
    }

    local -a steps=(
        "Propriétaire www-data:www-data (récursif)"
        "chmod 775 récursif"
        "Fichiers cachés : chmod 775 récursif"
        "log/*.* : chmod 665"
    )
    local -a cmds=(
        "chown -R www-data:www-data -- '${JEEDOM_DIR}'"
        "find '${JEEDOM_DIR}' -mindepth 1 ! -path '*/.*' -exec chmod 775 {} +"
        "find '${JEEDOM_DIR}' -mindepth 1 -path '*/.*' -exec chmod 775 {} +"
        "find '${JEEDOM_DIR}/log' -type f -exec chmod 665 {} +"
    )

    local i failed=0
    for i in "${!steps[@]}"; do
        [[ "$mode" == "interactive" ]] && echo -ne "  ${DIM}${steps[$i]}...${N} "
        if eval "${cmds[$i]}" 2>/dev/null; then
            [[ "$mode" == "interactive" ]] && echo -e "${G}✔${N}"
        else
            [[ "$mode" == "interactive" ]] && echo -e "${R}✘${N}"
            failed=1
            log_action "fix_permissions ÉCHEC: ${steps[$i]}"
        fi
    done

    if [[ $failed -eq 0 ]]; then
        [[ "$mode" == "interactive" ]] && echo -e "\n${G}✔ Droits rétablis avec succès.${N}"
        log_action "fix_permissions exécuté avec succès"
    else
        [[ "$mode" == "interactive" ]] && echo -e "\n${R}✘ Une ou plusieurs étapes ont échoué — voir ${AUDIT_LOG}${N}"
        log_action "fix_permissions terminé avec erreurs"
    fi

    [[ "$mode" == "interactive" ]] && pause
    return $failed
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
    # jeedom::backup(false) exécute install/backup.php de façon synchrone
    # (même appel que celui fait par l'ancien jeedom.php action=backup).
    _jee_php 'jeedom::backup(false);'
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
    # jeedom::restore(..., false) = synchrone, même appel que l'ancien
    # jeedom.php action=restore. Chemin passé via l'environnement (pas
    # d'interpolation dans le code PHP).
    _jee_php_env "JEE_BACKUP_PATH=${PICKED_FILE}" 'jeedom::restore(getenv("JEE_BACKUP_PATH"), false);'
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
    local cmd="$1" mode="${2:-interactive}"
    [[ "$mode" == "interactive" ]] && { header; section "${cmd} TABLE"; }
    echo -e "${Y}${cmd} en cours...${N}\n"
    local failed=0
    while IFS= read -r tbl; do
        local res; res=$(mysql_cmd -N -e "${cmd} TABLE \`${tbl}\`;" | awk '{print $NF}')
        printf "  %-35s %s\n" "${tbl}" "${res}"
        [[ "${res}" == "OK" || "${res}" == "status" ]] || failed=1
    done < <(mysql_cmd -N -e "SHOW TABLES;")
    if [[ $failed -eq 0 ]]; then
        echo -e "\n${G}✔ ${cmd} terminé.${N}"
        log_action "DB ${cmd}"
    else
        echo -e "\n${Y}⚠ ${cmd} terminé avec au moins une table en anomalie.${N}"
        log_action "DB ${cmd} (anomalies détectées)"
    fi
    [[ "$mode" == "interactive" ]] && pause
    return $failed
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
    mysqlcheck --defaults-extra-file="${DB_OPTFILE}" \
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
    # pipefail scopé au sous-shell : capture un échec de mysqldump même si gzip réussit.
    if (set -o pipefail; mysqldump --defaults-extra-file="${DB_OPTFILE}" "${DB_NAME}" 2>/dev/null | gzip > "${file}") \
        && gzip -t "${file}" 2>/dev/null; then
        echo -e "${G}✔ Dump créé et intégrité vérifiée.${N}"
        log_action "DB DUMP: ${file}"
    else
        rm -f "${file}"
        echo -e "${R}✘ Erreur lors du dump (fichier incomplet supprimé).${N}"
        log_action "DB DUMP ÉCHEC: ${file}"
    fi
    pause
}

_db_import() {
    header; section "Import dump SQL"
    pick_file_nav "Choisir le dump à importer" "${BACKUP_DIR}/dump_*.sql.gz" || { pause; return; }
    echo
    echo -e "${R}⚠  Écrasera la base ${DB_NAME} !${N}"
    confirm "Importer $(basename "${PICKED_FILE}")" || { echo -e "${Y}Annulé.${N}"; pause; return; }
    load_mysql_creds
    if (set -o pipefail; zcat "${PICKED_FILE}" \
            | mysql --defaults-extra-file="${DB_OPTFILE}" "${DB_NAME}" 2>/dev/null); then
        echo -e "${G}✔ Import terminé.${N}"; log_action "DB IMPORT: ${PICKED_FILE}"
    else
        echo -e "${R}✘ Erreur${N}"
    fi
    pause
}

_db_flush_cache() {
    header; section "Cache Jeedom"
    # cache::flush() = action exacte de l'ajax core cache.ajax.php?action=flush.
    _jee_php 'cache::flush();'
    if [[ $? -eq 0 ]]; then
        echo -e "${G}✔ Cache vidé.${N}"
        log_action "Cache Jeedom vidé"
    else
        echo -e "${R}✘ Erreur lors du vidage du cache.${N}"
    fi
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
            3) _svc_restart_daemon ;;
            4) header
               confirm "Relancer Jeedom complet" \
                   && { _jee_php 'jeedom::stop(); sleep(2); jeedom::start();'
                        log_action "Jeedom restart (stop+start)"; echo -e "${G}✔${N}"; } \
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

#  Redémarre uniquement le master jeeCron (sans toucher enableCron/
#  enableScenario, contrairement à jeedom::stop()+start() utilisé pour le
#  "Relancer Jeedom complet"). Reproduit ce que fait jeedom::stop() pour la
#  partie cron (kill du PID via system::kill, cf. jeedom.class.php) puis
#  relance une exécution ponctuelle de jeeCron.php : comme /etc/cron.d/jeedom
#  le fait chaque minute, ce process devient le nouveau master s'il n'y en a
#  pas déjà un (cron::jeeCronRun()), cf. core/php/jeeCron.php.
_svc_restart_daemon() {
    header; section "Redémarrage daemon Jeedom (cron master)"
    _jee_php '
        if (cron::jeeCronRun()) {
            echo "Arret du master en cours (pid " . cron::getPidFile() . ")...\n";
            system::kill(cron::getPidFile());
        } else {
            echo "Aucun master actif.\n";
        }
    '
    sleep 1
    echo -e "${Y}Relance...${N}"
    sudo -u www-data setsid php "${JEECRON}" > /dev/null 2>&1 < /dev/null &
    disown
    sleep 2
    if _daemon_running; then
        echo -e "${G}✔ Daemon relancé.${N}"
        log_action "Daemon Jeedom (cron master) restart OK"
    else
        echo -e "${R}✘ Le daemon ne semble pas être reparti.${N}"
        log_action "Daemon Jeedom (cron master) restart ÉCHEC"
    fi
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
            0) header; section "Vérification des mises à jour"
               # update::checkAllUpdate() + refreshUpdateMessage() = action
               # exacte de l'ajax core update.ajax.php?action=checkAllUpdate.
               _jee_php '
                   update::checkAllUpdate();
                   update::refreshUpdateMessage();
                   $u = update::byLogicalId("jeedom");
                   if (is_object($u)) {
                       echo "Jeedom core — version locale   : " . $u->getLocalVersion() . "\n";
                       echo "Jeedom core — version distante : " . $u->getRemoteVersion() . "\n";
                   }
                   echo "Elements necessitant une mise a jour (plugins+core) : " . update::nbNeedUpdate() . "\n";
               '
               pause ;;
            1) header
               confirm "Mettre à jour Jeedom" \
                   && { echo -e "${Y}Lancement en tâche de fond (voir Logs > update)...${N}"
                        # jeedom::update() = ce que fait $update->doUpdate()
                        # pour un update de type 'core' (cf. update.class.php).
                        _jee_php 'jeedom::update();'
                        log_action "Jeedom doUpdate (core, via jeedom::update)"; } \
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

# Nettoyage ciblé de /tmp : exclut les sockets/verrous système partagés
# (X11, ICE, systemd-private-*) et affiche la liste avant toute suppression —
# /tmp est partagé avec d'autres services, pas une zone propre à Jeedom.
_cleanup_tmp() {
    header; section "Nettoyage /tmp"
    local -a targets
    mapfile -t targets < <(find /tmp -mindepth 1 -maxdepth 1 -mtime +1 \
        -not -name ".X11-unix" -not -name ".ICE-unix" -not -name ".font-unix" \
        -not -name ".Test-unix" -not -name ".XIM-unix" \
        -not -name "systemd-private-*" -not -name "snap-private-tmp" \
        2>/dev/null)

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo -e "${G}Rien à nettoyer (hors sockets système protégés).${N}"
        pause; return
    fi

    echo -e "  ${W}Éléments ciblés (> 1 jour, hors sockets système) :${N}\n"
    local f
    for f in "${targets[@]}"; do
        printf "  %-50s %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
    done
    echo

    confirm "Supprimer ces ${#targets[@]} élément(s)" || { echo -e "${Y}Annulé.${N}"; pause; return; }

    local b; b=$(du -sh /tmp 2>/dev/null | cut -f1)
    rm -rf -- "${targets[@]}"
    echo -e "  Avant : ${Y}${b}${N}  →  Après : ${G}$(du -sh /tmp 2>/dev/null | cut -f1)${N}"
    log_action "Nettoyage /tmp (${#targets[@]} éléments)"
    pause
}

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
            1) _cleanup_tmp ;;
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
#  10 — MODE SECOURS (si l'UI web est injoignable)
# ============================================================
#  Reproduit les actions exposées par Jeedom lui-même en mode secours
#  (index.php?v=d&p=database&rescue=1 / p=cron&rescue=1), pour les cas où
#  cette page web n'est elle-même pas joignable (Apache/PHP bloqué, plugin
#  qui fait planter tout le rendu normal, etc.) :
#    - "Désactiver tous les plugins" = commande rapide exacte de database.php
#      (UPDATE `config` SET `value`=0 WHERE `key`='active')
#    - "Activer/Désactiver le système cron" = bouton exact de cron.php
#      (config::save('enableCron', 0|1))
#  Chaque action est journalisée à la fois dans l'audit jeehelp et dans
#  ${JEEDOM_DIR}/log, pour rester visible depuis l'interface Jeedom une
#  fois celle-ci de nouveau joignable.

_rescue_log() {
    local msg="$1"
    local line; line="$(date '+%Y-%m-%d %H:%M:%S') [$(whoami)] ${msg}"
    echo "${line}" >> "${LOG_DIR}/jeehelp_rescue.log" 2>/dev/null
    log_action "RESCUE: ${msg}"
}

_rescue_test_url() {
    header; section "Test de la page de secours web"
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local -a hosts=("127.0.0.1")
    [[ -n "$ip" && "$ip" != "127.0.0.1" ]] && hosts+=("${ip}")
    local path="/index.php?v=d&p=database&rescue=1"
    echo -e "  ${W}Page testée :${N} ${path}\n"

    local h code reachable_any=0
    for h in "${hosts[@]}"; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${h}${path}" 2>/dev/null)
        if [[ "${code}" == "200" ]]; then
            echo -e "  ${G}✔${N} http://${h}${path}  →  HTTP ${code}"
            reachable_any=1
        elif [[ -n "${code}" && "${code}" != "000" ]]; then
            echo -e "  ${Y}⚠${N} http://${h}${path}  →  HTTP ${code} (pas 200)"
        else
            echo -e "  ${R}✘${N} http://${h}${path}  →  injoignable"
        fi
    done

    echo
    if [[ ${reachable_any} -eq 1 ]]; then
        echo -e "  ${G}La page de secours web est accessible : privilégier le navigateur.${N}"
    else
        echo -e "  ${R}Page de secours web injoignable depuis cette machine.${N}"
        echo -e "  ${Y}→  Utiliser les actions CLI ci-dessous (Plugins / Cron).${N}"
    fi
    _rescue_log "Test page de secours web : $( [[ ${reachable_any} -eq 1 ]] && echo "OK" || echo "INJOIGNABLE" )"
    pause
}

_rescue_disable_plugins() {
    header; section "Désactiver tous les plugins (mode secours)"
    load_mysql_creds
    local before; before=$(mysql_cmd -N -e "SELECT COUNT(*) FROM config WHERE \`key\`='active' AND \`value\`='1';")
    echo -e "  Reproduit exactement la commande rapide Jeedom (page Database, mode secours) :"
    echo -e "  ${DIM}UPDATE \`config\` SET \`value\`=0 WHERE \`key\`='active';${N}"
    echo -e "  Plugins actuellement actifs : ${W}${before:-?}${N}\n"
    echo -e "  ${R}⚠  Utile si un plugin bloque le rendu de l'interface web.${N}"
    echo -e "  ${Y}   Réactivation ensuite au cas par cas depuis l'interface Jeedom${N}"
    echo -e "  ${Y}   normale (Plugins) une fois le problème identifié.${N}\n"

    confirm "Désactiver les ${before:-0} plugin(s) actif(s)" || { echo -e "${Y}Annulé.${N}"; pause; return; }

    if mysql_cmd -e "UPDATE \`config\` SET \`value\`=0 WHERE \`key\`='active';"; then
        echo -e "\n${G}✔ ${before:-0} plugin(s) désactivé(s).${N}"
        _rescue_log "Plugins désactivés (${before:-0} actifs avant action)"
    else
        echo -e "\n${R}✘ Erreur lors de la désactivation.${N}"
        _rescue_log "ÉCHEC désactivation plugins"
    fi
    pause
}

_rescue_cron_state() {
    local v; v=$(mysql_cmd -N -e "SELECT \`value\` FROM config WHERE plugin='core' AND \`key\`='enableCron';")
    [[ -z "${v}" || "${v}" == "1" ]] && echo "actif" || echo "désactivé"
}

_rescue_set_cron() {
    local state="$1" label="$2"
    header; section "${label} (mode secours)"
    load_mysql_creds
    echo -e "  Reproduit exactement le bouton Jeedom « ${label} » (page Cron, mode secours) :"
    echo -e "  ${DIM}config::save('enableCron', ${state})${N}"
    echo -e "  État actuel : ${W}$(_rescue_cron_state)${N}\n"

    confirm "${label}" || { echo -e "${Y}Annulé.${N}"; pause; return; }

    if mysql_cmd -e "REPLACE INTO config (plugin, \`key\`, \`value\`) VALUES ('core','enableCron','${state}');"; then
        if [[ "${state}" == "0" ]]; then
            echo -e "\n${G}✔ Système cron désactivé.${N}"
        else
            echo -e "\n${G}✔ Système cron activé.${N}"
        fi
        _rescue_log "${label} (enableCron=${state})"
    else
        echo -e "\n${R}✘ Erreur.${N}"
        _rescue_log "ÉCHEC ${label}"
    fi
    pause
}

menu_rescue() {
    local opts=(
        "🔗  Tester l'accès à la page de secours web"
        "🧩  Désactiver tous les plugins"
        "⏱️   Désactiver le système cron"
        "⏱️   Activer le système cron"
        "↩  Retour"
    )
    while true; do
        nav_menu "Mode secours (si l'interface web est injoignable)" "${opts[@]}"
        case $MENU_RESULT in
            -1|4) return ;;
            0) _rescue_test_url ;;
            1) _rescue_disable_plugins ;;
            2) _rescue_set_cron 0 "Désactiver le système cron" ;;
            3) _rescue_set_cron 1 "Activer le système cron" ;;
        esac
    done
}

# ============================================================
#  MODE CLI NON-INTERACTIF
# ============================================================

cli_mode() {
    check_root; check_jeedom
    local rc=0
    case "$1" in
        --backup)
            echo "[CLI] Sauvegarde..."
            _jee_php 'jeedom::backup(false);'
            rc=$?
            log_action "CLI --backup (rc=${rc})" ;;
        --repair-db)
            echo "[CLI] Réparation DB..."
            _db_all_tables "REPAIR" "cli"
            rc=$? ;;
        --check)
            echo "[CLI] Vérification système..."
            _H_OK=0; _H_WARN=0; _H_ERR=0
            _watchdog_check
            _ssl_check "$(hostname -f 2>/dev/null || hostname)" ;;
        --health)
            echo "[CLI] Health check complet..."
            show_health "cli"
            rc=$? ;;
        --fix-perms)
            echo "[CLI] Rétablissement des droits..."
            fix_permissions "cli"
            rc=$? ;;
        --upgrade-security)
            echo "[CLI] unattended-upgrade..."
            if command -v unattended-upgrade &>/dev/null; then
                unattended-upgrade --debug 2>&1
                rc=$?
                log_action "CLI --upgrade-security (rc=${rc})"
            else
                echo "unattended-upgrades non installé."
                rc=1
            fi ;;
        *)
            echo "Usage: sudo bash $0 [option]"
            echo "  --backup            Lancer une sauvegarde"
            echo "  --repair-db         Réparer la base de données"
            echo "  --check             Vérification rapide"
            echo "  --health            Health check complet (code retour : 0 OK, 1 avertissement, 2 erreur)"
            echo "  --fix-perms         Rétablir les droits fichiers"
            echo "  --upgrade-security  unattended-upgrade"
            exit 1 ;;
    esac
    exit $rc
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
        "🆘  Mode secours (interface web injoignable)"
        "❌  Quitter"
    )

    while true; do
        nav_menu "Menu principal" "${opts[@]}"
        case $MENU_RESULT in
            -1|10) _exit_clean ;;
            0) show_system_info ;;
            1) menu_health      ;;
            2) menu_backups     ;;
            3) menu_database    ;;
            4) menu_services    ;;
            5) menu_logs        ;;
            6) menu_network     ;;
            7) menu_updates     ;;
            8) menu_cleanup     ;;
            9) menu_rescue      ;;
        esac
    done
}

# ── Point d'entrée ───────────────────────────────────────────
[[ -n "$1" ]] && cli_mode "$@"
check_root
check_jeedom
main_menu
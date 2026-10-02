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
readonly MAX_BACKUPS=3

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

# Sortie sur signal OS réel (INT/TERM envoyé par un superviseur ou un
# opérateur en dehors de la lecture clavier du menu) : _exit_clean sert au
# "Quitter" coopératif du menu et doit garder exit 0. Ici on code le retour
# en 128+signal (convention shell standard) pour qu'un appelant/superviseur
# puisse distinguer une interruption d'un succès.
_exit_signal() {
    local code="$1"
    _cursor_show
    stty echo 2>/dev/null
    echo -e "\n${Y}Interrompu.${N}\n"
    exit "${code}"
}

declare -ga _TMP_CLEAN=()

_cleanup_optfile() {
    [[ -n "${DB_OPTFILE:-}" && -f "${DB_OPTFILE}" ]] && rm -f "${DB_OPTFILE}"
}

_on_exit() { _cursor_show; _cleanup_optfile; [[ ${#_TMP_CLEAN[@]} -gt 0 ]] && rm -rf -- "${_TMP_CLEAN[@]}" 2>/dev/null; }

trap '_exit_signal 130' INT
trap '_exit_signal 143' TERM
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
    echo -e "${B}║${W}        🏠  JEEDOM — Helper by Limad44                ${B}║${N}"
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
#  Retourne dans $KEY_RESULT : "up" "down" "enter" "esc" "ctrlc" "eof" ou le char
read_key() {
    local key seq
    # `read -n1` renvoie key="" à la fois sur un Entrée réel (il consomme le
    # saut de ligne comme délimiteur) ET sur un EOF véritable (stdin fermé) —
    # mais SEUL l'EOF fait échouer read (rc != 0). Sans ce test, un stdin
    # fermé (lancement sans TTY, pipe vide) ferait boucler le menu à l'infini
    # en traitant chaque lecture ratée comme un appui sur Entrée.
    if ! IFS= read -rsn1 key; then
        KEY_RESULT="eof"
        return
    fi

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
            ctrlc|ctrld|eof)
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
    # Exécuté en www-data, PAS en root : common.config.php est possédé par
    # www-data (comme tout core Jeedom), donc modifiable par n'importe quel
    # plugin/daemon tournant sous ce compte. Un `require` de ce fichier
    # lancé directement par le `php` root donnerait à un www-data compromis
    # un chemin d'exécution de code arbitraire EN ROOT au prochain appel
    # d'une fonction MySQL de jeehelp. En le exécutant sous www-data (même
    # compte qui possède déjà le fichier), aucune élévation de privilège
    # n'est possible.
    local raw
    # La variable d'environnement est fixée par `env`, lui-même exécuté en
    # www-data APRÈS le changement d'utilisateur par sudo : elle n'a donc
    # pas besoin de traverser le reset d'environnement de sudo
    # (contrairement à `VAR=val sudo -u ... php`, où `sudo` repartirait
    # d'un environnement nettoyé et perdrait VAR sans --preserve-env).
    # Même pattern que _jee_php_env ci-dessus.
    raw=$(sudo -u www-data env "CONF_FILE_PATH=${CONF_FILE}" php -r '
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

# `systemctl list-units` ne liste que les unités déjà chargées (typiquement
# actives) : un service installé mais jamais démarré depuis le boot n'y
# apparaît pas et serait déclaré "absent" à tort. `list-unit-files` liste
# toutes les unités présentes sur le disque, quel que soit leur état.
# Les alias sont exclus (ex: mysql.service -> mariadb.service) : sinon
# MariaDB apparaîtrait deux fois et "Redémarrer MySQL/MariaDB" le
# redémarrerait deux fois.
_svc_exists() {
    systemctl list-unit-files --type=service 2>/dev/null \
        | awk -v u="${1}.service" '$1==u && $2!="alias" {f=1} END{exit !f}'
}

svc_ctl() {
    local action="$1" svc="$2"
    _svc_exists "${svc}" \
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

#  État du moteur cron Jeedom. Sur 4.6, jeeCron.php n'est PAS un daemon
#  persistant : /etc/cron.d/jeedom le lance chaque minute, il écrit son PID
#  dans jeedom::getTmpFolder().'/jeeCron.pid', exécute les tâches dues puis
#  se termine. cron::jeeCronRun() (PID vivant) n'est donc vrai que pendant
#  ces quelques secondes, et seul il rapportait "introuvable" à tort. Le
#  moteur est considéré actif si un run est en cours OU si le PID file a été
#  réécrit il y a moins de 120 s (au moins un passage dans la dernière
#  minute écoulée).
_daemon_running() {
    sudo -u www-data php -r "require '${CORE_INC}'; \$p = jeedom::getTmpFolder() . '/jeeCron.pid'; exit((cron::jeeCronRun() || (is_file(\$p) && time() - filemtime(\$p) < 120)) ? 0 : 1);" 2>/dev/null
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
    printf "  ${W}%-16s${N} %s\n" "MariaDB"  "$(mysql_cmd -N -e "SELECT VERSION();" 2>/dev/null || mysql --version 2>/dev/null | awk '{print $5}' | tr -d ',')"
    echo
    printf "  ${W}%-16s${N} %s\n" "Uptime"    "$(uptime -p 2>/dev/null || uptime)"
    printf "  ${W}%-16s${N} %s\n" "CPU load"  "$(awk '{print $1,$2,$3}' /proc/loadavg)"
    printf "  ${W}%-16s${N} %s\n" "RAM"       "$(free -h | awk '/^Mem:/{print $3"/"$2}')"
    printf "  ${W}%-16s${N} %s\n" "Disque"    "$(df -h "${JEEDOM_DIR}" | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    section "Services"
    for svc in apache2 nginx mysql mariadb; do
        _svc_exists "${svc}" || continue
        local st; st=$(systemctl is-active "${svc}" 2>/dev/null)
        [[ "${st}" == "active" ]] \
            && echo -e "  ${G}●${N} ${svc}" \
            || echo -e "  ${R}● ${st}${N}  ${svc}"
    done
    section "Watchdog"
    _watchdog_check
    section "Certificat SSL local"
    _ssl_check_auto
    pause
}

# Renvoie 0 si tout est OK, 1 si une anomalie est signalée — utilisé par
# `--check` pour que le code de sortie CLI reflète réellement le résultat
# (il affichait les mêmes messages mais retournait toujours 0 à l'appelant).
_watchdog_check() {
    local rc=0
    _daemon_running \
        && echo -e "  ${G}✔${N} Daemon Jeedom actif" \
        || { echo -e "  ${R}✘${N} Daemon Jeedom introuvable"; rc=1; }
    local pct; pct=$(df "${JEEDOM_DIR}" | awk 'NR==2{gsub(/%/,""); print $5}')
    if [[ $pct -ge 90 ]]; then
        echo -e "  ${R}⚠  Disque ${pct}% utilisé !${N}"; rc=1
    else
        echo -e "  ${G}✔${N} Disque ${pct}% utilisé"
    fi
    return $rc
}

# Même convention de retour que _watchdog_check (0=OK, 1=anomalie).
# Hôtes dont on teste le certificat : le nom local, l'adresse externe configurée dans Jeedom
# (service DNS Jeedom *.jeedom.link, nom de domaine perso...) et le nom HTTPS de Tailscale quand
# il est actif. Ces accès terminent le TLS ailleurs : Apache local n'a alors aucun certificat et le
# seul test du nom d'hôte signalait à tort « HTTPS non détecté ».
_ssl_targets() {
    {
        hostname -f 2>/dev/null || hostname
        local ext; ext=$(_jee_php 'echo network::getNetworkAccess("external");' 2>/dev/null | tail -1)
        if [[ "${ext}" =~ ^https://([A-Za-z0-9.-]+)(:[0-9]+)?(/.*)?$ ]]; then
            local eh="${BASH_REMATCH[1]}"
            [[ "${eh}" =~ ^[0-9.]+$ || "${eh}" == localhost ]] || echo "${eh}"
        fi
        if command -v tailscale &>/dev/null; then
            timeout 5 tailscale status --json 2>/dev/null | php -r '
                $j = json_decode(stream_get_contents(STDIN), true);
                $d = rtrim((string)($j["Self"]["DNSName"] ?? ""), ".");
                if (($j["BackendState"] ?? "") === "Running" && $d !== "") echo $d . "\n";'
        fi
    } | awk 'NF && !seen[$0]++'
}

_ssl_expiry() {  # hôte → date d'expiration (vide si pas de TLS sur :443) ; délai borné
    echo | timeout 10 openssl s_client -connect "$1:443" -servername "$1" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

_ssl_check() {
    local domain="${1:-$(hostname -f)}"
    command -v openssl &>/dev/null || { echo -e "  ${Y}openssl non disponible${N}"; return 1; }
    local expiry; expiry=$(_ssl_expiry "${domain}")
    if [[ -z "$expiry" ]]; then
        echo -e "  ${Y}Pas de HTTPS détecté sur ${domain}${N}"; return 0
    fi
    local diff_days; diff_days=$(( ($(date -d "$expiry" +%s 2>/dev/null) - $(date +%s)) / 86400 ))
    if [[ $diff_days -le 14 ]]; then
        echo -e "  ${R}⚠  SSL ${domain} expire dans ${diff_days}j (${expiry})${N}"; return 1
    fi
    echo -e "  ${G}✔${N} SSL ${domain} valide encore ${diff_days} jours"
    return 0
}

# Teste tous les hôtes connus ; "pas de HTTPS" n'est une anomalie pour aucun (réseau local possible)
_ssl_check_auto() {
    command -v openssl &>/dev/null || { echo -e "  ${Y}openssl non disponible${N}"; return 1; }
    local h found=0 rc=0 tested=()
    while IFS= read -r h; do
        [[ -z "${h}" ]] && continue
        tested+=("${h}")
        if [[ -n "$(_ssl_expiry "${h}")" ]]; then _ssl_check "${h}" || rc=1; found=1; fi
    done < <(_ssl_targets)
    [[ ${found} -eq 0 ]] && echo -e "  ${Y}Pas de HTTPS détecté (hôtes testés : ${tested[*]})${N}"
    return ${rc}
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

# Compte les fichiers proches du datadir par défaut qui n'appartiennent pas
# à mysql. Ce contrôle borné reste léger et ne suit pas les autres systèmes
# de fichiers montés sous le répertoire.
_mysql_datadir_bad_owner_count() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo 0; return 0; }
    find "$dir" -xdev -maxdepth 2 -type f ! -user mysql ! -name 'debian-*.flag' ! -name mariadb_upgrade_info -printf . 2>/dev/null | wc -c
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

    # ── MariaDB : distinguer serveur joignable, base sélectionnée et schéma ──
    load_mysql_creds
    if mysql --defaults-extra-file="${DB_OPTFILE}" -N -e "SELECT 1;" &>/dev/null; then
        _chk "MariaDB" ok "serveur joignable"
        if mysql_cmd -e "SELECT 1;" &>/dev/null; then
            _chk "Base Jeedom" ok "connectée (${DB_NAME})"
            local schema_tables schema_rc
            schema_tables=$(mysql_cmd -N -e "SHOW TABLES;"); schema_rc=$?
            if [[ ${schema_rc} -ne 0 ]]; then
                _chk "Schéma Jeedom" err "impossible d'énumérer les tables"
            elif [[ -z "${schema_tables}" ]]; then
                _chk "Schéma Jeedom" err "base vide : aucune table"
            elif ! grep -Fxq "config" <<< "${schema_tables}"; then
                _chk "Schéma Jeedom" err "table config absente (${DB_NAME})"
            else
                _chk "Schéma Jeedom" ok "table config présente ($(wc -l <<< "${schema_tables}") tables)"
            fi
        else
            _chk "Base Jeedom" err "base '${DB_NAME}' absente ou inaccessible"
        fi
    else
        _chk "MariaDB" err "serveur/socket inaccessible"
    fi

    # ── Services web ──
    for svc in apache2 nginx; do
        _svc_exists "${svc}" || continue
        local st; st=$(systemctl is-active "$svc" 2>/dev/null)
        [[ "$st" == "active" ]] && _chk "$svc" ok "actif" || _chk "$svc" err "$st"
    done

    # ── Services DB ──
    for svc in mysql mariadb; do
        _svc_exists "${svc}" || continue
        local st; st=$(systemctl is-active "$svc" 2>/dev/null)
        [[ "$st" == "active" ]] && _chk "$svc" ok "actif" || _chk "$svc" err "$st"
    done

    # Datadir Debian par défaut : vérification en lecture seule des droits et
    # de l'espace. Un datadir personnalisé reste à contrôler séparément.
    local mysql_dir="/var/lib/mysql"
    if [[ -d "${mysql_dir}" ]]; then
        local mysql_dir_meta mysql_dir_pct mysql_dir_ipct
        mysql_dir_meta=$(stat -c '%U:%G %a' "${mysql_dir}" 2>/dev/null || echo "stat indisponible")
        if id mysql &>/dev/null; then
            sudo -u mysql test -w "${mysql_dir}" \
                && _chk "Datadir MariaDB" ok "mysql peut écrire (${mysql_dir_meta})" \
                || _chk "Datadir MariaDB" err "mysql ne peut pas écrire (${mysql_dir_meta})"
            local bad_owner_count; bad_owner_count=$(_mysql_datadir_bad_owner_count "${mysql_dir}")
            if [[ "${bad_owner_count}" =~ ^[[:space:]]*[1-9][0-9]*$ ]]; then
                _chk "Fichiers datadir MariaDB" warn "${bad_owner_count} fichier(s) non possédé(s) par mysql (profondeur 2)"
            else
                _chk "Fichiers datadir MariaDB" ok "propriétaire mysql à la profondeur contrôlée"
            fi
        else
            _chk "Datadir MariaDB" warn "compte système mysql absent (${mysql_dir_meta})"
        fi
        mysql_dir_pct=$(df -P "${mysql_dir}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
        mysql_dir_ipct=$(df -Pi "${mysql_dir}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
        if [[ "${mysql_dir_pct}" =~ ^[0-9]+$ ]]; then
            if [[ ${mysql_dir_pct} -ge 90 ]]; then _chk "Espace datadir MariaDB" err "${mysql_dir_pct}% utilisé"
            elif [[ ${mysql_dir_pct} -ge 80 ]]; then _chk "Espace datadir MariaDB" warn "${mysql_dir_pct}% utilisé"
            else _chk "Espace datadir MariaDB" ok "${mysql_dir_pct}% utilisé"; fi
        fi
        if [[ "${mysql_dir_ipct}" =~ ^[0-9]+$ && ${mysql_dir_ipct} -ge 90 ]]; then
            _chk "Inodes datadir MariaDB" err "${mysql_dir_ipct}% utilisés"
        elif [[ "${mysql_dir_ipct}" =~ ^[0-9]+$ && ${mysql_dir_ipct} -ge 80 ]]; then
            _chk "Inodes datadir MariaDB" warn "${mysql_dir_ipct}% utilisés"
        fi
    fi

    # ── Daemon Jeedom ──
    _daemon_running \
        && _chk "Daemon Jeedom" ok "actif" \
        || _chk "Daemon Jeedom" err "introuvable"

    local started_state
    started_state=$(_jee_php 'echo jeedom::isStarted() ? "1" : "0";' 2>/dev/null | tail -1)
    case "${started_state}" in
        1) _chk "Démarrage Jeedom" ok "marqueur actif" ;;
        0) _chk "Démarrage Jeedom" warn "marqueur absent : démarrage potentiellement bloqué" ;;
        *) _chk "Démarrage Jeedom" warn "état indéterminé (core PHP indisponible)" ;;
    esac

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
    command -v openssl &>/dev/null && {
        local ssl_host ssl_exp ssl_days ssl_found=0 ssl_tested=()
        while IFS= read -r ssl_host; do
            [[ -z "${ssl_host}" ]] && continue
            ssl_tested+=("${ssl_host}")
            ssl_exp=$(_ssl_expiry "${ssl_host}")
            [[ -z "${ssl_exp}" ]] && continue
            ssl_found=1
            ssl_days=$(( ($(date -d "${ssl_exp}" +%s) - $(date +%s)) / 86400 ))
            [[ ${ssl_days} -le 14 ]] \
                && _chk "SSL ${ssl_host}" warn "expire dans ${ssl_days}j" \
                || _chk "SSL ${ssl_host}" ok   "valide ${ssl_days}j"
        done < <(_ssl_targets)
        [[ ${ssl_found} -eq 0 ]] && _chk "SSL" warn "HTTPS non détecté (testé : ${ssl_tested[*]})"
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

#  Les liens symboliques sont exclus (! -type l) : chmod suit le lien et échoue
#  sur un lien cassé (ex: anciens venv dans plugins/bak), ce qui faisait
#  échouer toute l'étape alors que chmod -R du core les ignore.
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
        "find '${JEEDOM_DIR}' -mindepth 1 ! -type l ! -path '*/.*' -exec chmod 775 {} +"
        "find '${JEEDOM_DIR}' -mindepth 1 ! -type l -path '*/.*' -exec chmod 775 {} +"
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

    # Capturé via substitution de commande (pas un pipe vers `while`) pour
    # pouvoir tester le code retour de SHOW TABLES : avec `done < <(...)`,
    # un échec de connexion MySQL produirait juste une liste vide et la
    # boucle ne s'exécuterait pas — "terminé" aurait alors été annoncé à
    # tort alors qu'aucune table n'a réellement été vérifiée.
    local raw_tables
    raw_tables=$(mysql_cmd -N -e "SHOW TABLES;")
    if [[ $? -ne 0 ]]; then
        echo -e "${R}✘ Impossible d'énumérer les tables (SHOW TABLES a échoué).${N}"
        log_action "DB ${cmd} : échec SHOW TABLES"
        [[ "$mode" == "interactive" ]] && pause
        return 1
    fi

    local -a tables=()
    [[ -n "${raw_tables}" ]] && mapfile -t tables <<< "${raw_tables}"

    if [[ ${#tables[@]} -eq 0 ]]; then
        echo -e "${R}✘ Aucune table trouvée : base vide ou schéma inaccessible, aucune opération lancée.${N}"
        log_action "DB ${cmd} : aucune table trouvée"
        [[ "$mode" == "interactive" ]] && pause
        return 1
    fi
    local has_config=0
    for tbl in "${tables[@]}"; do [[ "${tbl}" == "config" ]] && has_config=1; done
    if [[ ${has_config} -eq 0 ]]; then
        echo -e "${R}✘ Table Jeedom 'config' absente : schéma incomplet, aucune opération lancée.${N}"
        log_action "DB ${cmd} : table config absente"
        [[ "$mode" == "interactive" ]] && pause
        return 1
    fi

    local failed=0 tbl tbl_escaped res
    for tbl in "${tables[@]}"; do
        # Échappe un éventuel accent grave dans le nom de table (doublé,
        # convention MySQL) avant de le réinjecter comme identifiant entre
        # backticks : sans ça, un nom de table contenant ` casserait la
        # requête générée (injection SQL de second ordre).
        tbl_escaped="${tbl//\`/\`\`}"
        # Sortie MySQL : Table, Op, Msg_type, Msg_text (séparés par tab).
        # Anomalie = ligne "error", ou statut "Operation failed" ; les notes
        # (ex: moteur MEMORY qui ne supporte pas analyze) et "already up to
        # date" sont normaux. Sortie vide = requête échouée.
        local out; out=$(mysql_cmd -N -e "${cmd} TABLE \`${tbl_escaped}\`;")
        res=$(awk -F'\t' '{ if ($3=="error" || ($3=="status" && $4=="Operation failed")) bad=1; last=$4 }
                         END { if (last=="") bad=1; printf "%s", (bad ? "ERREUR : " : "") (last=="" ? "pas de réponse" : last) }' <<< "${out}")
        printf "  %-35s %s\n" "${tbl}" "${res}"
        [[ "${res}" == ERREUR* ]] && failed=1
    done

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
    if mysqlcheck --defaults-extra-file="${DB_OPTFILE}" \
               --auto-repair --check "${DB_NAME}" 2>/dev/null; then
        echo -e "\n${G}✔ Terminé.${N}"
        log_action "DB mysqlcheck"
    else
        echo -e "\n${R}✘ Erreur lors de mysqlcheck.${N}"
        log_action "DB mysqlcheck ÉCHEC"
    fi
    pause
}

_db_dump() {
    header; section "Dump MariaDB"
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

    # Vérification d'intégrité avant toute écriture en base : un dump SQL
    # n'est pas transactionnel, donc même avec pipefail une partie des
    # requêtes peut déjà avoir été appliquée avant qu'une erreur de flux ne
    # soit détectée. gzip -t ne garantit pas la validité du SQL contenu,
    # mais élimine la cause la plus fréquente d'import partiel (archive
    # tronquée/corrompue) avant de toucher à la base.
    if ! gzip -t "${PICKED_FILE}" 2>/dev/null; then
        echo -e "${R}✘ Archive corrompue (gzip -t a échoué) — import annulé, base non touchée.${N}"
        log_action "DB IMPORT annulé (archive corrompue) : ${PICKED_FILE}"
        pause; return
    fi

    load_mysql_creds
    if (set -o pipefail; zcat "${PICKED_FILE}" \
            | mysql --defaults-extra-file="${DB_OPTFILE}" "${DB_NAME}" 2>/dev/null); then
        echo -e "${G}✔ Import terminé.${N}"; log_action "DB IMPORT: ${PICKED_FILE}"
    else
        echo -e "${R}✘ Erreur — la base peut avoir été partiellement modifiée (dump non transactionnel).${N}"
        log_action "DB IMPORT ÉCHEC (possible état partiel) : ${PICKED_FILE}"
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
        "🗄️   Redémarrer MariaDB"
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
            2) header; section "Redémarrage MariaDB"
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
        _svc_exists "${svc}" || continue
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
               # pipefail scopé : sans lui, le `| tail -5` masquerait le code
               # retour réel d'apt-get update (celui de `tail`, toujours 0).
               if (set -o pipefail; apt-get update 2>&1 | tail -5) && apt-get upgrade -y 2>&1; then
                   echo -e "\n${G}✔ Système à jour.${N}"; log_action "apt upgrade"
               else
                   echo -e "\n${R}✘ Échec lors de la mise à jour système (update ou upgrade).${N}"
                   log_action "apt upgrade ÉCHEC"
               fi
               pause ;;
            3) _unattended_setup  ;;
            4) _unattended_dryrun ;;
            5) _unattended_status ;;
        esac
    done
}

#  Renvoie 0 si la directive est déjà active OU appliquée avec succès,
#  1 si `sed` a réellement échoué — jusqu'ici la coche verte s'affichait
#  après `sed -i` sans vérifier son code retour.
_unatd_set() {
    local file="$1" old="$2" new="$3"
    if grep -qF "${old}" "$file" 2>/dev/null; then
        if sed -i "s|${old}|${old}\n${new}|" "$file"; then
            echo -e "  ${G}✔${N} ${new}"
        else
            echo -e "  ${R}✘${N} Échec d'application : ${new}"
            return 1
        fi
    else
        echo -e "  ${Y}–${N} Déjà actif ou non trouvé : ${new}"
    fi
    return 0
}

_unattended_setup() {
    header; section "Installation & configuration unattended-upgrades"
    if ! apt-get install -y unattended-upgrades apt-listchanges debconf-utils 2>&1; then
        echo -e "${R}✘ Échec de l'installation des paquets.${N}"
        log_action "unattended-upgrades : échec apt-get install"
        pause; return
    fi
    export PATH=$PATH:/usr/sbin
    dpkg-reconfigure --priority=low unattended-upgrades \
        || echo -e "${Y}⚠ dpkg-reconfigure a retourné une erreur — poursuite malgré tout.${N}"
    local conf="/etc/apt/apt.conf.d/50unattended-upgrades"
    [[ ! -f "$conf" ]] && { echo -e "${R}Fichier conf introuvable.${N}"; pause; return; }
    echo -e "\n${Y}Application configuration recommandée (communauté Jeedom)...${N}"
    # Redémarrage automatique : OPTIONNEL, refusé par défaut. Redémarrer une box domotique
    # sans surveillance est risqué (daemons, scénarios, disque externe) et ne relève pas de
    # ce script : on ne l'active que sur demande explicite.
    local reboot=0
    echo -e "\n${Y}⚠ Redémarrage automatique${N} : le système redémarrerait seul à 05h00 (heure locale du serveur)"
    echo -e "  quand une mise à jour du noyau l'exige, même si des utilisateurs sont connectés."
    echo -e "  ${DIM}Déconseillé sur une box Jeedom 24/7 ; sans cela, un redémarrage manuel reste nécessaire après un noyau.${N}"
    confirm "Activer le redémarrage automatique" && reboot=1
    local failed=0
    if [[ ${reboot} -eq 1 ]]; then
    _unatd_set "$conf" '//Unattended-Upgrade::Automatic-Reboot "false";'               'Unattended-Upgrade::Automatic-Reboot "true";'               || failed=1
    _unatd_set "$conf" '//Unattended-Upgrade::Automatic-Reboot-WithUsers "true";'     'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";'     || failed=1
    _unatd_set "$conf" '//Unattended-Upgrade::Automatic-Reboot-Time "02:00";'         'Unattended-Upgrade::Automatic-Reboot-Time "05:00";'         || failed=1
    fi
    _unatd_set "$conf" '//Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'  'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'  || failed=1
    _unatd_set "$conf" '//Unattended-Upgrade::Remove-New-Unused-Dependencies "true";' 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";' || failed=1
    _unatd_set "$conf" '//Unattended-Upgrade::Remove-Unused-Dependencies "false";'    'Unattended-Upgrade::Remove-Unused-Dependencies "true";'     || failed=1
    if [[ $failed -eq 0 ]]; then
        if [[ ${reboot} -eq 1 ]]; then
            echo -e "\n${G}✔ Configuré — redémarrage automatique à 05h00 (heure locale du serveur) si une mise à jour du noyau l'exige.${N}"
        else
            echo -e "\n${G}✔ Configuré — sans redémarrage automatique (un redémarrage manuel reste nécessaire après une mise à jour du noyau).${N}"
        fi
        log_action "unattended-upgrades configuré"
    else
        echo -e "\n${R}✘ Configuration incomplète — voir les échecs ci-dessus.${N}"
        log_action "unattended-upgrades configuré avec erreurs"
    fi
    pause
}

_unattended_dryrun() {
    header; section "Dry-run unattended-upgrades"
    command -v unattended-upgrade &>/dev/null \
        && unattended-upgrade --dry-run -v 2>&1 | tail -30 \
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

# Ajoute une ligne SANS jamais suivre un lien symbolique : ouverture en O_NOFOLLOW
# (un test -L suivi d'un >> laisserait une fenêtre TOCTOU, log/ étant modifiable
# par www-data). Création en www-data 664 comme les autres logs Jeedom.
_safe_append() {  # fichier ligne
    perl -MFcntl -e '
my ($f, $l) = @ARGV;
sysopen(my $h, $f, O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW, 0664) or exit 1;
my @pw = getpwnam("www-data"); chown $pw[2], $pw[3], $h if @pw; chmod 0664, $h;
syswrite($h, $l . "\n"); close $h;' "$1" "$2"
}

_rescue_log() {
    local msg="$1"
    local line; line="$(date '+%Y-%m-%d %H:%M:%S') [$(whoami)] ${msg}"
    local target="${LOG_DIR}/jeehelp_rescue.log"
    _safe_append "${target}" "${line}" 2>/dev/null \
        || log_action "RESCUE-LOG-ALERTE: écriture refusée dans ${target} (lien symbolique ou erreur)"
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
    # Liste des plugins actifs, relevée AVANT la désactivation pour pouvoir
    # les réactiver ensuite (la commande Jeedom met tout à 0 sans mémoire).
    local active; active=$(mysql_cmd -N -e "SELECT plugin FROM config WHERE \`key\`='active' AND \`value\`='1' ORDER BY plugin;" | paste -sd' ')
    local before; before=$(wc -w <<< "${active}")
    echo -e "  Reproduit exactement la commande rapide Jeedom (page Database, mode secours) :"
    echo -e "  ${DIM}UPDATE \`config\` SET \`value\`=0 WHERE \`key\`='active';${N}"
    echo -e "  Plugins actuellement actifs (${W}${before}${N}) : ${active:-aucun}\n"
    echo -e "  ${R}⚠  Utile si un plugin bloque le rendu de l'interface web.${N}"
    echo -e "  ${Y}   La liste sera journalisée dans ${LOG_DIR}/jeehelp_rescue.log${N}"
    echo -e "  ${Y}   pour une réactivation ultérieure.${N}\n"

    confirm "Désactiver les ${before} plugin(s) actif(s)" || { echo -e "${Y}Annulé.${N}"; pause; return; }

    # Journalisé avant l'UPDATE : la liste reste disponible même en cas d'échec.
    _rescue_log "Plugins actifs avant désactivation (${before}) : ${active:-aucun}"
    if mysql_cmd -e "UPDATE \`config\` SET \`value\`=0 WHERE \`key\`='active';"; then
        echo -e "\n${G}✔ ${before} plugin(s) désactivé(s).${N}"
        _rescue_log "Plugins désactivés (${before})"
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
#  RAPPORT DE DIAGNOSTIC
# ============================================================
#  Rassemble en un seul document tout ce qui peut justifier un blocage :
#  contrôles de la page Santé, accessibilité de l'UI et de la page de
#  secours, moteur cron, plugins actifs et leurs daemons/dépendances,
#  MariaDB, ressources, services, logs, messages Jeedom, sauvegardes,
#  droits, réseau, mises à jour et actions récentes de jeehelp.
#  Enregistré dans ${LOG_DIR}/jeehelp_rapport_<date>.txt (10 derniers
#  conservés). Aucun secret n'y figure (pas de mots de passe, ni de lignes
#  de commande complètes : elles peuvent contenir des clés API).

declare -g _R_BODY=""
declare -ga _R_ISSUES=()

_r_out() { printf '%s\n' "$*" >> "${_R_BODY}"; }
_r_sec() { _r_out ""; _r_out "── $1"; }
# _r_item ok|warn|err|info "libellé" "détail"
_r_item() {
    local st="$1" label="$2" detail="${3:-}" tag
    case "${st}" in
        ok)   tag="[OK]  " ;;
        warn) tag="[WARN]"; _R_ISSUES+=("WARN|${label}|${detail}") ;;
        err)  tag="[ERR] "; _R_ISSUES+=("ERR|${label}|${detail}") ;;
        *)    tag="[INFO]" ;;
    esac
    _r_out "$(printf '%s %-32s %s' "${tag}" "${label}" "${detail}")"
}
_r_pct_item() {  # label pct detail (seuils 80/90)
    local label="$1" pct="$2" detail="$3"
    if   [[ "${pct}" -ge 90 ]]; then _r_item err  "${label}" "${detail}"
    elif [[ "${pct}" -ge 80 ]]; then _r_item warn "${label}" "${detail}"
    else                             _r_item ok   "${label}" "${detail}"; fi
}
_r_kv() { awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,""); print; exit}' <<< "$1"; }

generate_report() {
    local mode="${1:-interactive}"
    _R_BODY=$(mktemp); _R_ISSUES=()
    load_mysql_creds
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local jv; jv=$(_jee_php 'echo jeedom::version();' | tail -1)

    # ── Jeedom : état du core ──
    local core; core=$(_jee_php '
        $c = config::byKey("enableCron");     echo "enableCron=" . ($c === "" ? 1 : $c) . "\n";
        $s = config::byKey("enableScenario"); echo "enableScenario=" . ($s === "" ? 1 : $s) . "\n";
        echo "started=" . (jeedom::isStarted() ? 1 : 0) . "\n";
        echo "dateok=" . (jeedom::isDateOk() ? 1 : 0) . "\n";
        $all = scenario::all(); $en = 0; $run = 0;
        foreach ($all as $sc) { if ($sc->getIsActive()) $en++; if ($sc->getState() == "in progress") $run++; }
        echo "scenarios=" . count($all) . " dont " . $en . " actifs, " . $run . " en cours\n";
        echo "needupdate=" . update::nbNeedUpdate() . "\n";
    ')
    _r_sec "Jeedom (état du core)"
    _r_item info "Version Jeedom" "${jv:-inconnue}"
    [[ "$(_r_kv "${core}" enableCron)" == "0" ]] \
        && _r_item err "Système cron" "DÉSACTIVÉ (enableCron=0) : plus de tâches, ni de daemons de plugins" \
        || _r_item ok  "Système cron" "activé"
    if _daemon_running; then _r_item ok "Moteur cron (jeeCron)" "actif (PID file récent)"
    else _r_item err "Moteur cron (jeeCron)" "aucun passage depuis plus de 120 s"; fi
    [[ "$(_r_kv "${core}" enableScenario)" == "0" ]] \
        && _r_item warn "Scénarios" "DÉSACTIVÉS globalement (enableScenario=0)" \
        || _r_item ok   "Scénarios" "$(_r_kv "${core}" scenarios)"
    [[ "$(_r_kv "${core}" started)" == "1" ]] \
        && _r_item ok   "Jeedom démarré" "oui" \
        || _r_item warn "Jeedom démarré" "fichier 'started' absent : les daemons restent bloqués"
    [[ "$(_r_kv "${core}" dateok)" == "1" ]] \
        && _r_item ok  "Date système" "cohérente" \
        || _r_item err "Date système" "incohérente (Jeedom bloque certaines tâches)"
    local nu; nu=$(_r_kv "${core}" needupdate)
    [[ "${nu:-0}" -gt 0 ]] && _r_item info "Mises à jour Jeedom/plugins" "${nu} élément(s)" || _r_item ok "Mises à jour Jeedom/plugins" "à jour"

    # ── Santé ──
    _r_sec "Santé"
    local h l t
    h=$(show_health cli 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g')
    while IFS= read -r l; do
        [[ "${l}" == *"avertissement(s)"* ]] && continue
        # Les contrôles MariaDB sont détaillés plus bas avec distinction
        # serveur/base/schéma et ne doivent pas apparaître deux fois.
        [[ "${l}" == *"MariaDB"* || "${l}" == *"Base Jeedom"* || "${l}" == *"Schéma Jeedom"* ]] && continue
        case "${l}" in
            *✔*) t="${l#*✔}"; _r_out "[OK]   ${t#"${t%%[! ]*}"}" ;;
            *⚠*) t="${l#*⚠}"; t="${t#"${t%%[! ]*}"}"; _r_out "[WARN] ${t}"
                 # Permissions et http.error ont leur propre section détaillée plus bas
                 [[ "${t}" == Permissions* || "${t}" == http.error* ]] || _R_ISSUES+=("WARN|Santé|${t}") ;;
            *✘*) t="${l#*✘}"; t="${t#"${t%%[! ]*}"}"; _r_out "[ERR]  ${t}"; _R_ISSUES+=("ERR|Santé|${t}") ;;
        esac
    done <<< "${h}"

    # ── Accessibilité de l'interface et de la page de secours ──
    _r_sec "Accessibilité web (interface et page de secours)"
    local -a hosts=("127.0.0.1"); [[ -n "${ip}" && "${ip}" != "127.0.0.1" ]] && hosts+=("${ip}")
    local h2 p res code tm label
    for h2 in "${hosts[@]}"; do
        for p in "/index.php?v=d" "/index.php?v=d&p=database&rescue=1"; do
            res=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 8 "http://${h2}${p}" 2>/dev/null)
            code="${res%% *}"; tm="${res##* }"
            [[ "${p}" == *rescue* ]] && label="Page de secours @${h2}" || label="Interface Jeedom @${h2}"
            if   [[ "${code}" == "200" || "${code}" == "302" ]]; then
                 awk -v t="${tm}" 'BEGIN{exit !(t>3)}' \
                    && _r_item warn "${label}" "HTTP ${code} mais lente (${tm}s)" \
                    || _r_item ok   "${label}" "HTTP ${code} (${tm}s)"
            elif [[ -z "${code}" || "${code}" == "000" ]]; then _r_item err "${label}" "injoignable (timeout 8 s)"
            else _r_item err "${label}" "HTTP ${code}"; fi
        done
    done

    # ── Plugins actifs, daemons et dépendances ──
    _r_sec "Plugins actifs"
    local active; active=$(mysql_cmd -N -e "SELECT plugin FROM config WHERE \`key\`='active' AND \`value\`='1' ORDER BY plugin;" | paste -sd' ')
    _r_item info "Plugins actifs ($(wc -w <<< "${active}"))" ""
    fold -s -w 100 <<< "${active}" | sed 's/^/        /' >> "${_R_BODY}"
    local pl pid pstate pauto pdep pmsg
    pl=$(_jee_php '
        foreach (plugin::listPlugin(true) as $p) {
            try {
                $dep = "-";
                if ($p->getHasDependency() == 1 && method_exists($p->getId(), "dependancy_info")) { $d = $p->dependancy_info(); $dep = $d["state"] ?? "?"; }
                if ($p->getHasOwnDeamon() == 1) { $i = $p->deamon_info(); echo $p->getId() . "|" . $i["state"] . "|" . $i["auto"] . "|" . $dep . "|" . str_replace(["\n","|"], " ", $i["launchable_message"] ?? "") . "\n"; }
                elseif ($dep != "-" && $dep != "ok") { echo $p->getId() . "|-|-|" . $dep . "|\n"; }
            } catch (\Throwable $e) { echo $p->getId() . "|exception|-|-|" . str_replace(["\n","|"], " ", $e->getMessage()) . "\n"; }
        }
    ')
    local nd=0 ndok=0
    while IFS='|' read -r pid pstate pauto pdep pmsg; do
        [[ -z "${pid}" || "${pid}" == *" "* || "${pid}" == PHP* ]] && continue
        nd=$((nd+1))
        if   [[ "${pstate}" == "exception" ]]; then _r_item warn "Plugin ${pid}" "erreur lecture état : ${pmsg:0:100}"
        elif [[ "${pstate}" == "nok" && "${pauto}" == "1" ]]; then _r_item warn "Daemon ${pid}" "ARRÊTÉ alors que la gestion auto est active ${pmsg:+(${pmsg:0:80})}"
        elif [[ "${pstate}" == "nok" ]]; then _r_item info "Daemon ${pid}" "arrêté (gestion auto désactivée)"
        else ndok=$((ndok+1)); fi
        [[ "${pdep}" != "-" && "${pdep}" != "ok" && "${pdep}" != "" ]] && _r_item warn "Dépendances ${pid}" "état : ${pdep}"
    done <<< "${pl}"
    _r_item info "Daemons de plugins" "${ndok} en marche sur ${nd} signalés/suivis (les anomalies sont listées ci-dessus)"

    # ── Diagnostic serveur / base / schéma MariaDB ──
    _r_sec "Diagnostic MariaDB"
    local db_server_ok=0 db_database_ok=0 db_schema db_schema_rc
    if mysql --defaults-extra-file="${DB_OPTFILE}" -N -e "SELECT 1;" &>/dev/null; then
        db_server_ok=1
        _r_item ok "Serveur MariaDB" "connexion sans sélection de base réussie"
        if mysql_cmd -e "SELECT 1;" &>/dev/null; then
            db_database_ok=1
            db_schema=$(mysql_cmd -N -e "SHOW TABLES;"); db_schema_rc=$?
            if [[ ${db_schema_rc} -ne 0 ]]; then
                _r_item err "Schéma Jeedom" "SHOW TABLES a échoué"
            elif [[ -z "${db_schema}" ]]; then
                _r_item err "Schéma Jeedom" "base vide : aucune table"
            elif ! grep -Fxq "config" <<< "${db_schema}"; then
                _r_item err "Schéma Jeedom" "table config absente (${DB_NAME})"
            else
                _r_item ok "Schéma Jeedom" "table config présente ($(wc -l <<< "${db_schema}") tables)"
            fi
        else
            _r_item err "Base Jeedom" "${DB_NAME} absente ou inaccessible sur le serveur"
        fi
    else
        _r_item err "Serveur MariaDB" "connexion impossible (service, socket ou identifiants)"
    fi

    # ── MariaDB ──
    _r_sec "MariaDB"
    local st mc size
    st=$(mysql_cmd -N -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_connected','Max_used_connections','Aborted_connects','Slow_queries');")
    if [[ -z "${st}" ]]; then
        [[ ${db_server_ok} -eq 1 && ${db_database_ok} -eq 1 ]] && _r_item warn "Statistiques MariaDB" "base accessible, mais SHOW GLOBAL STATUS sans résultat"
    else
        mc=$(mysql_cmd -N -e "SELECT @@max_connections;")
        size=$(mysql_cmd -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
        local tc; tc=$(awk '$1=="Threads_connected"{print $2}' <<< "${st}")
        _r_item ok   "Connexion MariaDB" "$(mysql_cmd -N -e 'SELECT VERSION();'), base ${DB_NAME} (${size:-?} Mo)"
        _r_pct_item  "Connexions simultanées" "$(( ${tc:-0} * 100 / ${mc:-1} ))" "${tc}/${mc} (pic $(awk '$1=="Max_used_connections"{print $2}' <<< "${st}"))"
        _r_item info "Uptime / requêtes lentes" "$(awk '$1=="Uptime"{printf "%dj %dh", $2/86400, ($2%86400)/3600}' <<< "${st}") / $(awk '$1=="Slow_queries"{print $2}' <<< "${st}") lentes / $(awk '$1=="Aborted_connects"{print $2}' <<< "${st}") connexions refusées"
    fi

    # Datadir Debian par défaut : contrôle sans écriture. Un chemin absent
    # peut indiquer une configuration personnalisée; il n'est pas déclaré en panne.
    local mysql_dir="/var/lib/mysql" mysql_dir_pct mysql_dir_ipct
    if [[ -d "${mysql_dir}" ]]; then
        local mysql_dir_meta; mysql_dir_meta=$(stat -c '%U:%G %a' "${mysql_dir}" 2>/dev/null || echo "stat indisponible")
        if id mysql &>/dev/null; then
            sudo -u mysql test -w "${mysql_dir}" \
                && _r_item ok "Écriture datadir MariaDB" "mysql peut écrire (${mysql_dir_meta})" \
                || _r_item err "Écriture datadir MariaDB" "mysql ne peut pas écrire (${mysql_dir_meta})"
            local bad_owner_count; bad_owner_count=$(_mysql_datadir_bad_owner_count "${mysql_dir}")
            if [[ "${bad_owner_count}" =~ ^[[:space:]]*[1-9][0-9]*$ ]]; then
                _r_item warn "Propriétaires fichiers MariaDB" "${bad_owner_count} fichier(s) non possédé(s) par mysql (profondeur 2)"
            else
                _r_item ok "Propriétaires fichiers MariaDB" "mysql à la profondeur contrôlée"
            fi
        else
            _r_item warn "Écriture datadir MariaDB" "compte système mysql absent (${mysql_dir_meta})"
        fi
        mysql_dir_pct=$(df -P "${mysql_dir}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
        mysql_dir_ipct=$(df -Pi "${mysql_dir}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
        [[ "${mysql_dir_pct}" =~ ^[0-9]+$ ]] && _r_pct_item "Disque datadir MariaDB" "${mysql_dir_pct}" "${mysql_dir_pct}% utilisé"
        [[ "${mysql_dir_ipct}" =~ ^[0-9]+$ ]] && _r_pct_item "Inodes datadir MariaDB" "${mysql_dir_ipct}" "${mysql_dir_ipct}% utilisés"
    else
        _r_item info "Datadir MariaDB" "/var/lib/mysql absent (chemin personnalisé possible)"
    fi

    # ── Ressources ──
    _r_sec "Ressources système"
    local d pct ipct
    for d in / "${JEEDOM_DIR}" /tmp; do
        pct=$(df -P "${d}" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
        ipct=$(df -Pi "${d}" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
        [[ -n "${pct}" ]]  && _r_pct_item "Disque ${d}" "${pct}"  "${pct}% utilisé ($(df -Ph "${d}" | awk 'NR==2{print $3"/"$2}'))"
        [[ "${ipct}" =~ ^[0-9]+$ ]] && _r_pct_item "Inodes ${d}" "${ipct}" "${ipct}% utilisés"
    done
    local mem_t mem_a sw_t sw_u load cpus
    read -r mem_t mem_a < <(free -m | awk '/^Mem:/{print $2, $7}')
    read -r sw_t sw_u < <(free -m | awk '/^Swap:/{print $2, $3}')
    [[ $(( mem_a * 100 / (mem_t + 1) )) -lt 10 ]] \
        && _r_item err  "Mémoire disponible" "${mem_a} Mo sur ${mem_t} Mo (< 10 %)" \
        || _r_item ok   "Mémoire disponible" "${mem_a} Mo sur ${mem_t} Mo"
    [[ "${sw_t:-0}" -gt 0 && $(( sw_u * 100 / sw_t )) -ge 50 ]] \
        && _r_item warn "Swap" "${sw_u}/${sw_t} Mo utilisés (≥ 50 %)" \
        || _r_item ok   "Swap" "${sw_u:-0}/${sw_t:-0} Mo"
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg); cpus=$(nproc 2>/dev/null || echo 1)
    awk -v l="${load%% *}" -v c="${cpus}" 'BEGIN{exit !(l>c*1.5)}' \
        && _r_item warn "Charge CPU" "${load} sur ${cpus} cœurs (> 1,5 × cœurs)" \
        || _r_item ok   "Charge CPU" "${load} sur ${cpus} cœurs"
    local zomb; zomb=$(ps -eo stat | grep -c '^Z')
    [[ "${zomb}" -gt 0 ]] && _r_item warn "Processus zombies" "${zomb}" || _r_item ok "Processus zombies" "0"
    local oom; oom=$(journalctl -k --since "7 days ago" --no-pager 2>/dev/null | grep -ciE "out of memory|oom-kill|killed process")
    [[ "${oom:-0}" -gt 0 ]] && _r_item err "OOM killer (7 jours)" "${oom} événement(s) : la mémoire a été saturée" || _r_item ok "OOM killer (7 jours)" "aucun"
    _r_item info "Top CPU (noms seuls)" "$(ps -eo comm,pcpu --sort=-pcpu | awk 'NR>1 && NR<=6{printf "%s %s%%  ", $1, $2}')"
    _r_item info "Top mémoire (noms seuls)" "$(ps -eo comm,pmem --sort=-pmem | awk 'NR>1 && NR<=6{printf "%s %s%%  ", $1, $2}')"

    # ── Services ──
    _r_sec "Services"
    local svc s_st
    for svc in apache2 mariadb cron; do
        _svc_exists "${svc}" || continue
        s_st=$(systemctl is-active "${svc}" 2>/dev/null)
        [[ "${s_st}" == "active" ]] && _r_item ok "Service ${svc}" "actif" || _r_item err "Service ${svc}" "${s_st}"
    done
    local failed_units; failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    if [[ -n "${failed_units}" ]]; then
        while IFS= read -r l; do _r_item warn "Unité systemd en échec" "${l}"; done <<< "${failed_units}"
    else _r_item ok "Unités systemd en échec" "aucune"; fi

    local db_journal apache_journal journal_line
    db_journal=$(journalctl -u mariadb -u mysql --since "24 hours ago" -p err -n 3 --no-pager 2>/dev/null)
    if [[ -n "${db_journal}" ]]; then
        _r_item warn "Erreurs MariaDB (24 h)" "messages trouvés; extraits ci-dessous"
        while IFS= read -r journal_line; do _r_out "          [mariadb] ${journal_line:0:300}"; done <<< "${db_journal}"
    else
        _r_item info "Erreurs MariaDB (24 h)" "aucune erreur visible dans le journal systemd"
    fi
    apache_journal=$(journalctl -u apache2 --since "24 hours ago" -p err -n 3 --no-pager 2>/dev/null)
    if [[ -n "${apache_journal}" ]]; then
        _r_item warn "Erreurs Apache (24 h)" "messages trouvés; extraits ci-dessous"
        while IFS= read -r journal_line; do _r_out "          [apache2] ${journal_line:0:300}"; done <<< "${apache_journal}"
    else
        _r_item info "Erreurs Apache (24 h)" "aucune erreur visible dans le journal systemd"
    fi

    # ── Logs et messages Jeedom ──
    _r_sec "Logs et messages Jeedom"
    local he=0; [[ -f "${LOG_DIR}/http.error" ]] && he=$(wc -l < "${LOG_DIR}/http.error")
    [[ "${he}" -gt 500 ]] && _r_item warn "log/http.error" "${he} lignes" || _r_item ok "log/http.error" "${he} lignes"
    _r_item info "Taille du dossier log" "$(du -sh "${LOG_DIR}" 2>/dev/null | cut -f1) ; plus gros : $(ls -S "${LOG_DIR}" 2>/dev/null | head -3 | while read -r f; do printf '%s(%s) ' "${f}" "$(du -h "${LOG_DIR}/${f}" 2>/dev/null | cut -f1)"; done)"
    local big; big=$(find "${LOG_DIR}" -maxdepth 1 -type f -size +100M 2>/dev/null)
    [[ -n "${big}" ]] && _r_item warn "Log > 100 Mo" "$(basename -a ${big} | paste -sd' ')"
    if [[ -f "${LOG_DIR}/http.error" ]]; then
        # Une ligne = une erreur, attribuée au premier chemin plugins/xxx ou core/xxx cité
        # après " in /var/www/html/" (et non à chaque occurrence dans la trace de pile).
        local fat; fat=$(grep -a "PHP Fatal error" "${LOG_DIR}/http.error" | awk 'match($0, / in \/var\/www\/html\/(plugins\/[^\/]+|core\/[^\/]+)/) {print substr($0,RSTART+18,RLENGTH-18)}' | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s (%s)  ", $2, $1}')
        [[ -n "${fat}" ]] && _r_item warn "Erreurs fatales PHP (dans http.error)" "${fat}"
        _r_out "        dernières lignes de http.error :"
        tail -n 5 "${LOG_DIR}/http.error" | cut -c1-200 | sed 's/^/          /' >> "${_R_BODY}"
    fi
    local nmsg; nmsg=$(mysql_cmd -N -e "SELECT COUNT(*) FROM message;")
    [[ "${nmsg:-0}" -gt 50 ]] && _r_item warn "Messages Jeedom (centre de messages)" "${nmsg} messages" || _r_item ok "Messages Jeedom (centre de messages)" "${nmsg:-?} messages"
    if [[ "${nmsg:-0}" -gt 0 ]]; then
        _r_item info "Messages par plugin (top 5)" "$(mysql_cmd -N -e "SELECT CONCAT(plugin,' (',COUNT(*),')') FROM message GROUP BY plugin ORDER BY COUNT(*) DESC LIMIT 5;" | paste -sd' ')"
        _r_out "        5 derniers messages :"
        mysql_cmd -N -e "SELECT CONCAT(date,'  ',plugin,'  ',LEFT(REPLACE(message,CHAR(10),' '),110)) FROM message ORDER BY date DESC LIMIT 5;" | sed 's/^/          /' >> "${_R_BODY}"
    fi

    # ── Sauvegardes ──
    _r_sec "Sauvegardes"
    local lb age; lb=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -1)
    if [[ -z "${lb}" ]]; then _r_item err "Dernière sauvegarde" "aucune"
    else
        age=$(( ($(date +%s) - $(stat -c %Y "${lb}")) / 86400 ))
        if   [[ ${age} -le 1 ]]; then _r_item ok   "Dernière sauvegarde" "${age} j : $(basename "${lb}") ($(du -h "${lb}" | cut -f1))"
        elif [[ ${age} -le 7 ]]; then _r_item warn "Dernière sauvegarde" "${age} j : $(basename "${lb}")"
        else _r_item err "Dernière sauvegarde" "${age} j : $(basename "${lb}")"; fi
    fi
    _r_item info "Nombre / taille du dossier backup" "$(ls "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | wc -l) fichier(s) / $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)"

    # ── Droits ──
    _r_sec "Droits et propriétaires"
    local bad nbad; bad=$(find "${JEEDOM_DIR}" -maxdepth 3 ! -user www-data ! -type l 2>/dev/null | grep -v "^${JEEDOM_DIR}$")
    nbad=$(grep -c . <<< "${bad}")
    if [[ "${nbad}" -eq 0 ]]; then _r_item ok "Fichiers non www-data (prof. 3)" "0"
    else
        _r_item warn "Fichiers non www-data (prof. 3)" "${nbad} (ex. : $(head -3 <<< "${bad}" | paste -sd' '))"
    fi
    _r_item info "common.config.php" "$(stat -c '%U:%G %a' "${CONF_FILE}" 2>/dev/null)"
    sudo -u www-data test -w "${LOG_DIR}" \
        && _r_item ok  "Écriture de log/ par www-data" "oui" \
        || _r_item err "Écriture de log/ par www-data" "NON : Jeedom ne peut plus écrire ses logs"

    # ── Réseau ──
    _r_sec "Réseau"
    _r_item info "Adresses IP" "$(hostname -I 2>/dev/null | cut -c1-100)"
    ping -c1 -W2 1.1.1.1 &>/dev/null && _r_item ok "Connectivité Internet (ping 1.1.1.1)" "oui" || _r_item warn "Connectivité Internet (ping 1.1.1.1)" "KO"
    getent hosts market.jeedom.com &>/dev/null && _r_item ok "Résolution DNS (market.jeedom.com)" "oui" || _r_item warn "Résolution DNS (market.jeedom.com)" "KO"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://market.jeedom.com 2>/dev/null)
    [[ "${code}" =~ ^[23] ]] && _r_item ok "Market Jeedom (HTTPS)" "HTTP ${code}" || _r_item warn "Market Jeedom (HTTPS)" "HTTP ${code:-timeout}"

    # ── Système : mises à jour ──
    _r_sec "Système"
    _r_item info "OS / noyau / uptime" "$(. /etc/os-release; echo "${PRETTY_NAME}") / $(uname -r) / $(uptime -p)"
    local nup; nup=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
    [[ "${nup}" -gt 20 ]] && _r_item warn "Paquets à mettre à jour" "${nup}" || _r_item ok "Paquets à mettre à jour" "${nup}"
    [[ -f /var/run/reboot-required ]] && _r_item warn "Redémarrage requis" "oui (mise à jour noyau/libc)" || _r_item ok "Redémarrage requis" "non"

    # ── Actions récentes de jeehelp ──
    _r_sec "Actions récentes de jeehelp (audit et mode secours)"
    if [[ -f "${AUDIT_LOG}" ]]; then tail -n 8 "${AUDIT_LOG}" | cut -c1-200 | sed 's/^/        /' >> "${_R_BODY}"; else _r_out "        (aucune)"; fi
    if [[ -f "${LOG_DIR}/jeehelp_rescue.log" ]]; then
        _r_out "        journal du mode secours :"
        tail -n 8 "${LOG_DIR}/jeehelp_rescue.log" | cut -c1-300 | sed 's/^/          /' >> "${_R_BODY}"
    fi

    # ── Assemblage : synthèse en tête ──
    local nerr=0 nwarn=0 it
    for it in "${_R_ISSUES[@]}"; do [[ "${it}" == ERR* ]] && nerr=$((nerr+1)) || nwarn=$((nwarn+1)); done
    local file="${LOG_DIR}/jeehelp_rapport_$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "RAPPORT DE DIAGNOSTIC JEEHELP"
        echo "Généré le $(date '+%Y-%m-%d %H:%M:%S') sur $(hostname) (Jeedom ${jv:-?})"
        echo
        echo "SYNTHÈSE : ${nerr} erreur(s), ${nwarn} avertissement(s)"
        if [[ ${#_R_ISSUES[@]} -eq 0 ]]; then
            echo "  Aucun élément bloquant détecté."
        else
            for it in "${_R_ISSUES[@]}"; do
                [[ "${it}" == ERR* ]] || continue
                IFS='|' read -r _ lab det <<< "${it}"; echo "  [ERR]  ${lab} : ${det}"
            done
            for it in "${_R_ISSUES[@]}"; do
                [[ "${it}" == WARN* ]] || continue
                IFS='|' read -r _ lab det <<< "${it}"; echo "  [WARN] ${lab} : ${det}"
            done
        fi
        cat "${_R_BODY}"
        echo
        echo "Fin du rapport."
    } > "${_R_BODY}.final"
    rm -f "${_R_BODY}"
    # Le texte libre (messages Jeedom, lignes de log) peut contenir un secret : masqué avant d'être persisté
    _ai_prepare "${_R_BODY}.final" "${_R_BODY}.red" /dev/null local 1 2>/dev/null && mv "${_R_BODY}.red" "${_R_BODY}.final"
    # noclobber : ne suit jamais un lien symbolique préexistant (log/ est écrit par www-data)
    if ( set -C; cat "${_R_BODY}.final" > "${file}" ) 2>/dev/null; then
        chown www-data:www-data "${file}" 2>/dev/null; chmod 640 "${file}"
        ls -t "${LOG_DIR}"/jeehelp_rapport_*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f
        log_action "RAPPORT généré : ${file} (${nerr} erreur(s), ${nwarn} avertissement(s))"
    else
        file=""
        log_action "RAPPORT : écriture impossible dans ${LOG_DIR}"
    fi
    if [[ "${mode}" == "silent" ]]; then
        _R_FINAL="${_R_BODY}.final"
        [[ ${nerr} -gt 0 ]] && return 2
        [[ ${nwarn} -gt 0 ]] && return 1
        return 0
    fi
    if [[ "${mode}" == "cli" || ! -t 1 ]]; then
        cat "${_R_BODY}.final"
        [[ -n "${file}" ]] && echo "Rapport enregistré : ${file}"
    else
        if command -v less &>/dev/null; then less -FRX -P"Rapport de diagnostic (flèches/espace pour défiler, q pour quitter)" "${_R_BODY}.final"; else cat "${_R_BODY}.final"; fi
        [[ -n "${file}" ]] && echo -e "\n${G}Rapport enregistré : ${file}${N}"
    fi
    rm -f "${_R_BODY}.final"
    [[ ${nerr} -gt 0 ]] && return 2
    [[ ${nwarn} -gt 0 ]] && return 1
    return 0
}

menu_report() {
    header; section "Rapport de diagnostic"
    echo -e "  ${DIM}Collecte en cours (30 s environ)...${N}"
    generate_report interactive
    pause
}

# ============================================================
#  ANALYSE PAR IA  (jeehelp --ask / menu « Analyser avec l'IA »)
# ============================================================
#  Envoie le rapport de diagnostic à une IA et affiche son analyse.
#  Canaux : (1) plugin ai_assistant via son CLI PHP (aucune clé API ni
#  Apache requis, MariaDB + core suffisent) ; (2) appel direct d'une API
#  compatible OpenAI configurée dans /etc/jeehelp/ai.conf (seul canal si
#  Jeedom/MariaDB sont HS). Ordre : fournisseurs LOCAUX d'abord, puis cloud.
#
#  Garde-fous :
#   - cloud : rapport ANONYMISÉ (IP, hôte, chemins, logs retirés) + accord
#     explicite par fournisseur ; local : rapport complet, secrets masqués ;
#   - l'IA ne fait que PROPOSER : le texte de sa réponse n'est JAMAIS exécuté.
#     Seuls les identifiants du catalogue AI_ACTIONS sont reconnus, chacun
#     exige une confirmation [o/N], et rien n'est proposé hors TTY ;
#   - sortie de l'IA assainie (caractères de contrôle/ANSI supprimés).
#
#  /etc/jeehelp/ai.conf (root, 600) — clés :
#    AI_ALLOWED_CLOUD="2386 direct"   fournisseurs cloud déjà autorisés
#    AI_ORDER="2981 2386"             ordre de préférence des cloud (optionnel)
#    AI_DIRECT_URL / AI_DIRECT_MODEL / AI_DIRECT_KEY   canal direct (optionnel)

readonly AI_CONF="/etc/jeehelp/ai.conf"
readonly AI_CLI="${JEEDOM_DIR}/plugins/ai_assistant/core/php/ai_assistant.cli.php"
readonly _SELF="$(readlink -f "${BASH_SOURCE[0]}")"
declare -g _R_FINAL=""

# id → "option CLI|risque|description". Seuls ces ids existent.
declare -gA AI_ACTIONS=(
    [check]="--check|lecture|Vérification rapide (cron, disque, SSL)"
    [health]="--health|lecture|Contrôle de santé complet"
    [report]="--report|lecture|Régénérer le rapport de diagnostic"
    [fix-perms]="--fix-perms|modification|Rétablir les droits fichiers (comme le bouton Jeedom)"
    [repair-db]="--repair-db|modification|REPAIR TABLE sur toutes les tables"
    [backup]="--backup|modification|Lancer une sauvegarde Jeedom"
)

_ai_conf_get() {
    [[ -r "${AI_CONF}" ]] || return 0
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "${AI_CONF}"
}

_ai_conf_add() {  # clé valeur : ajoute une valeur à une liste séparée par des espaces
    local cur; cur=$(_ai_conf_get "$1")
    [[ " ${cur} " == *" $2 "* ]] && return 0
    ( umask 077
      install -d -m 700 "$(dirname "${AI_CONF}")"
      { grep -v "^$1=" "${AI_CONF}" 2>/dev/null; echo "$1=\"${cur:+${cur} }$2\""; } > "${AI_CONF}.tmp"
      mv "${AI_CONF}.tmp" "${AI_CONF}"; chmod 600 "${AI_CONF}" )
}

_ai_url_scope() {  # URL → local|cloud (hôte EXACT ; au moindre doute : cloud)
    local u="$1" h
    [[ "${u}" =~ ^https?://([^/@?#]*@)?(\[[0-9a-fA-F:]+\]|[^/:?#]+)(:[0-9]+)?([/?#]|$) ]] || { echo cloud; return; }
    [[ -n "${BASH_REMATCH[1]}" ]] && { echo cloud; return; }      # userinfo : ambigu
    h="${BASH_REMATCH[2]}"
    if [[ "${h}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
        if (( a > 255 || b > 255 || c > 255 || d > 255 )); then echo cloud
        elif (( a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) )); then echo local
        else echo cloud; fi
    elif [[ "${h,,}" == localhost || "${h}" == "[::1]" ]]; then echo local
    elif [[ "${h,,}" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)*\.(local|lan)$ ]]; then echo local
    else echo cloud; fi
}

# Masque les secrets ; en mode cloud anonymise aussi (IP, MAC, hôte, chemins)
# et retire les blocs de logs/messages (lignes indentées de 10 espaces).
# $1 entrée  $2 sortie  $3 fichier de correspondances  $4 local|cloud  $5 1 = garder les logs
_ai_prepare() {
    perl -e '
use strict; use warnings;
my ($in,$out,$map,$mode,$logs,$host)=@ARGV;
my (%m,%n,@map);
sub tok { my($k,$v)=@_; return $m{$k}{$v} //= do { my $t=$k."_".(++$n{$k}); push @map,"$t\t$v"; $t } }
open my $fh,"<:encoding(UTF-8)",$in or die; my @lines=<$fh>; close $fh;
my @o;
for my $l (@lines) {
  next if $mode eq "cloud" && !$logs && $l =~ /^ {10}\S/;
  $l =~ s/\b(Bearer|Basic)\s+\S+/$1 [REDACTED]/g;
  $l =~ s/(api[_-]?key|token|secret|passw(?:or)?d|authorization)("?\s*[=:]\s*"?)[^\s"}]+/$1$2\[REDACTED]/ig;
  $l =~ s/\bsk-[A-Za-z0-9_-]{16,}/[REDACTED]/g;
  $l =~ s/\b[A-Za-z0-9+=_-]{40,}\b/[REDACTED]/g;
  if ($mode eq "cloud") {
    $l =~ s/\b((?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2})\b/tok("MAC",$1)/ge;
    $l =~ s{/home/[^/\s]+}{/home/USER}g;
    $l =~ s/\b((?:\d{1,3}\.){3}\d{1,3})\b/tok("IP",$1)/ge;
    $l =~ s/(?<![0-9A-Za-z:])((?=[0-9a-fA-F:]*[a-fA-F])[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7})(?![0-9A-Za-z:])/tok("IP6",$1)/ge;
    $l =~ s/\Q$host\E/HOST/g if length $host;
    $l =~ s{/var/www/html}{<JEEDOM>}g;
  }
  push @o,$l;
}
open my $oh,">:encoding(UTF-8)",$out or die; print $oh @o; close $oh;
open my $mh,">:encoding(UTF-8)",$map or die; print $mh map {"$_\n"} @map;
print $mh "HOST\t$host\n<JEEDOM>\t/var/www/html\n"; close $mh;
' "$1" "$2" "$3" "$4" "$5" "$(hostname)"
}

# Remet les valeurs d'origine dans le texte de l'IA (jetons IP_1, HOST, <JEEDOM>...)
_ai_deanon() {  # fichier de correspondances ; filtre stdin → stdout
    perl -e '
use strict; use warnings; binmode(STDIN,":encoding(UTF-8)"); binmode(STDOUT,":encoding(UTF-8)");
my %m; open my $f,"<:encoding(UTF-8)",$ARGV[0] or exit; while(<$f>){chomp; my($k,$v)=split /\t/,$_,2; $m{$k}=$v if defined $v}
while(<STDIN>){ s/(<JEEDOM>|\b(?:IP6?|MAC)_\d+\b|\bHOST\b)/exists $m{$1} ? $m{$1} : $1/ge; print }
' "$1"
}

# Rapport trop gros : on ne garde que l'en-tête, la synthèse et les lignes WARN/ERR
_ai_trim() {  # fichier
    local max="${JEEHELP_AI_MAXBYTES:-20000}"
    [[ $(wc -c < "$1") -le ${max} ]] && return 0
    awk '/^── /{sec=1; print; next} !sec{print; next} /^\[(WARN|ERR)\]/{print}' "$1" > "$1.trim" && mv "$1.trim" "$1"
    echo "[Rapport réduit : seules les lignes WARN/ERR de chaque section sont conservées]" >> "$1"
}

_ai_system_prompt() {  # fichier de sortie
    {
        cat <<'TXT'
Rôle : expert Jeedom 4.6 / Debian 13 / MariaDB. Tu analyses un rapport de diagnostic généré par l'outil jeehelp.
Le rapport peut être anonymisé : IP_n, MAC_n, HOST et <JEEDOM> sont des jetons, pas de vraies valeurs.

Règles strictes :
- Tu ne demandes ni ne produis jamais de secret (mot de passe, clé API, token).
- Tu n'exécutes rien : tu proposes seulement. N'écris aucun appel d'outil, aucun bloc de commandes shell, aucune commande Jeedom.
- Appuie chaque hypothèse sur des lignes précises du rapport. N'invente rien : si l'information manque, dis-le.
- Classe la situation : critique (Jeedom inutilisable ou données en danger), majeur, mineur, info.

Sois très concis (la réponse est limitée en taille) : diagnostic en 3 phrases maximum, 4 causes maximum, 2 preuves courtes par cause (120 caractères max), pas de markdown.
Réponds UNIQUEMENT par un objet JSON (sans texte autour, sans bloc de code) :
{"gravite":"critique|majeur|mineur|info",
 "diagnostic":"résumé en 2-4 phrases, en français",
 "causes":[{"hypothese":"...","preuves":["ligne ou valeur du rapport"],"confiance":"haute|moyenne|faible"}],
 "actions":[{"id":"<id du catalogue>","raison":"pourquoi"}],
 "demande_section":null}
"actions" ne peut contenir QUE des id du catalogue ci-dessous ; tout autre id sera ignoré. "demande_section" : texte libre si une information supplémentaire est nécessaire, sinon null.

Catalogue des actions (id : effet) :
TXT
        local id spec
        for id in "${!AI_ACTIONS[@]}"; do
            spec="${AI_ACTIONS[$id]}"
            echo "- ${id} : ${spec#*|*|} [risque : $(cut -d'|' -f2 <<< "${spec}")]"
        done | sort
    } > "$1"
}

_AI_RENDER_PHP='
$t = trim((string)file_get_contents(getenv("AI_IN")));
$t = preg_replace("/^```(?:json)?\s*|\s*```$/m", "", $t);
$a = strpos($t, "{"); $b = strrpos($t, "}");
if ($a === false || $b === false) exit(3);
$j = json_decode(substr($t, $a, $b - $a + 1), true);
if (!is_array($j) || !isset($j["gravite"], $j["diagnostic"])) exit(3);
$c = function ($s) { $s = is_scalar($s) ? (string)$s : json_encode($s, JSON_UNESCAPED_UNICODE);
    return preg_replace("/[\x00-\x08\x0B-\x1F\x7F]/", "", $s); };
$g = strtolower($c($j["gravite"]));
if (!in_array($g, ["critique", "majeur", "mineur", "info"], true)) $g = "inconnue";
$o = "GRAVITE=" . $g . "\nDiagnostic : " . $c($j["diagnostic"]) . "\n";
if (!empty($j["causes"]) && is_array($j["causes"])) {
    $o .= "\nCauses probables :\n"; $i = 0;
    foreach ($j["causes"] as $cs) { if (!is_array($cs)) continue; $i++;
        $o .= "  " . $i . ". " . $c($cs["hypothese"] ?? "?") . " (confiance : " . $c($cs["confiance"] ?? "?") . ")\n";
        foreach ((array)($cs["preuves"] ?? []) as $p) $o .= "       - " . $c($p) . "\n"; }
}
if (!empty($j["demande_section"])) $o .= "\nInformation demandée par l IA : " . $c($j["demande_section"]) . "\n";
file_put_contents(getenv("AI_OUT"), $o);
$acts = "";
foreach ((array)($j["actions"] ?? []) as $x) { if (!is_array($x)) continue;
    $acts .= str_replace(["\t", "\n"], " ", $c($x["id"] ?? "")) . "\t" . str_replace(["\t", "\n"], " ", $c($x["raison"] ?? "")) . "\n"; }
file_put_contents(getenv("AI_ACT"), $acts);
'

_ai_render() {  # réponse_brute texte_sorti actions_sortie
    AI_IN="$1" AI_OUT="$2" AI_ACT="$3" php -r "${_AI_RENDER_PHP}"
}

# Appel direct d'une API compatible OpenAI (chat/completions)
# Appel du CLI du plugin dans un répertoire éphémère : root le remplit, le confie à www-data,
# n'y réécrit plus, puis relit la réponse (fichier régulier uniquement, taille bornée).
_ai_plugin_call() {  # wd id msgfile sysfile resp scope → ligne de statut ; rc = code de timeout/php
    local wd="$1" id="$2" msg="$3" sys="$4" resp="$5" scope="$6" sh rc
    local -a extra=(); [[ "${scope}" == cloud ]] && extra=(--allow-cloud 1)
    sh=$(mktemp -d); chmod 700 "${sh}"; _TMP_CLEAN+=("${sh}")
    cp "${msg}" "${sh}/m.txt"; cp "${sys}" "${sh}/s.txt"; : > "${sh}/r.txt"
    chown -R www-data:www-data "${sh}"
    timeout 240 sudo -u www-data php "${AI_CLI}" ask --id "${id}" --message-file "${sh}/m.txt" \
        --system-file "${sh}/s.txt" --out "${sh}/r.txt" "${extra[@]}" > "${wd}/status" 2>/dev/null
    rc=$?
    if [[ -f "${sh}/r.txt" && ! -L "${sh}/r.txt" ]]; then head -c 200000 "${sh}/r.txt" > "${resp}"; else : > "${resp}"; fi
    rm -rf "${sh}"
    tail -n 1 "${wd}/status"
    return ${rc}
}

_ai_direct_call() {  # wd msgfile sysfile resp → ligne OK|...|ERR|... ; rc 0/1
    local wd="$1" url key model code
    url=$(_ai_conf_get AI_DIRECT_URL); key=$(_ai_conf_get AI_DIRECT_KEY); model=$(_ai_conf_get AI_DIRECT_MODEL)
    [[ -n "${url}" && -n "${model}" ]] || { echo "ERR|direct|AI_DIRECT_URL/AI_DIRECT_MODEL manquants"; return 1; }
    [[ -z "${key}" || "${key}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || { echo "ERR|direct|AI_DIRECT_KEY invalide"; return 1; }
    AI_MSG="$2" AI_SYS="$3" AI_MODEL="${model}" php -r 'echo json_encode(["model"=>getenv("AI_MODEL"),"temperature"=>0.2,"messages"=>[["role"=>"system","content"=>file_get_contents(getenv("AI_SYS"))],["role"=>"user","content"=>file_get_contents(getenv("AI_MSG"))]]], JSON_UNESCAPED_UNICODE);' > "${wd}/req.json"
    ( umask 077; { echo 'header = "Content-Type: application/json"'; [[ -n "${key}" ]] && echo "header = \"Authorization: Bearer ${key}\""; } > "${wd}/curl.cfg" )
    code=$(curl -sS --max-time 240 -K "${wd}/curl.cfg" -d "@${wd}/req.json" -o "${wd}/out.json" -w '%{http_code}' "${url}" 2>"${wd}/curl.err")
    if [[ "${code}" != 200 ]]; then echo "ERR|direct|HTTP ${code:-000} $(head -c 120 "${wd}/curl.err" | tr '\n|' '  ')"; return 1; fi
    AI_OUTJ="${wd}/out.json" AI_RESP="$4" php -r '$j=json_decode(file_get_contents(getenv("AI_OUTJ")),true); $t=trim((string)($j["choices"][0]["message"]["content"] ?? "")); if($t===""){exit(1);} file_put_contents(getenv("AI_RESP"),$t);' \
        || { echo "ERR|direct|réponse vide ou illisible"; return 1; }
    echo "OK|direct|$(_ai_url_scope "${url}")|${model}|-"
}

ask_ai() {
    # wd reste root:root 700 : jamais de fichier root écrit dans un répertoire modifiable par www-data
    local wd; wd=$(mktemp -d); chmod 700 "${wd}"
    _TMP_CLEAN+=("${wd}")
    _ask_ai_run "${wd}" "$@"; local rc=$?
    rm -rf "${wd}"
    return ${rc}
}

_ask_ai_run() {
    local wd="$1"; shift
    local tty=0 pick=0 with_logs=0 dry=0 incl_invalid=0 only="" rfile="" chan="auto"
    [[ -t 0 && -t 1 ]] && tty=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pick) pick=1 ;;
            --with-logs) with_logs=1 ;;
            --dry-run) dry=1 ;;
            --include-invalid) incl_invalid=1 ;;
            --provider) only="${2:-}"; shift ;;
            --file) rfile="${2:-}"; shift ;;
            --channel) chan="${2:-auto}"; shift ;;
            *) echo "Option inconnue : $1 (--pick --provider ID --file F --channel auto|plugin|direct --with-logs --dry-run --include-invalid)" >&2; return 2 ;;
        esac
        shift
    done

    # ── 1. Rapport ──
    local rep="${wd}/rapport.txt"
    if [[ -n "${rfile}" ]]; then
        [[ -r "${rfile}" ]] || { echo "Fichier illisible : ${rfile}" >&2; return 2; }
        cp "${rfile}" "${rep}"
    else
        echo -e "${DIM}Collecte du rapport de diagnostic...${N}"
        generate_report silent >/dev/null 2>&1
        [[ -n "${_R_FINAL}" && -f "${_R_FINAL}" ]] || { echo "Impossible de générer le rapport." >&2; return 2; }
        mv "${_R_FINAL}" "${rep}"; _R_FINAL=""
    fi
    local full="${wd}/full.txt" cloud="${wd}/cloud.txt" map="${wd}/map.tsv" map_l="${wd}/map_local.tsv"
    _ai_prepare "${rep}" "${full}" "${map_l}" local 1
    _ai_prepare "${rep}" "${cloud}" "${map}" cloud "${with_logs}"
    _ai_trim "${full}"; _ai_trim "${cloud}"
    if [[ ${dry} -eq 1 ]]; then
        echo "── Charge utile qui serait envoyée à un fournisseur CLOUD ($(wc -c < "${cloud}") octets) ──"
        cat "${cloud}"; return 0
    fi
    local sysf="${wd}/system.txt"; _ai_system_prompt "${sysf}"

    # ── 2. Candidats : "canal|id|nom|provider|modèle|scope" ──
    local -a cands=() locals=() clouds=()
    local line id name prov model scope state
    if [[ "${chan}" != direct && -f "${AI_CLI}" ]]; then
        while IFS='|' read -r id name prov model scope state; do
            [[ -n "${id}" && ( "${state}" == ok || ( ${incl_invalid} -eq 1 && "${state}" == invalid ) ) ]] || continue
            [[ -n "${only}" && "${only}" != "${id}" ]] && continue
            if [[ "${scope}" == local ]]; then locals+=("plugin|${id}|${name}|${prov}|${model}|local")
            else clouds+=("plugin|${id}|${name}|${prov}|${model}|cloud"); fi
        done < <(sudo -u www-data php "${AI_CLI}" list 2>/dev/null)
        # cloud : ordre de préférence AI_ORDER d'abord
        local ordered=() o c
        for o in $(_ai_conf_get AI_ORDER); do
            for c in "${clouds[@]}"; do [[ "${c}" == plugin\|"${o}"\|* ]] && ordered+=("${c}"); done
        done
        for c in "${clouds[@]}"; do [[ " ${ordered[*]} " == *"${c}"* ]] || ordered+=("${c}"); done
        clouds=("${ordered[@]}")
    fi
    if [[ "${chan}" != plugin && -z "${only}" ]]; then
        local durl dmodel; durl=$(_ai_conf_get AI_DIRECT_URL); dmodel=$(_ai_conf_get AI_DIRECT_MODEL)
        if [[ -n "${durl}" && -n "${dmodel}" ]]; then
            if [[ "$(_ai_url_scope "${durl}")" == local ]]; then locals+=("direct|direct|API directe|direct|${dmodel}|local")
            else clouds+=("direct|direct|API directe|direct|${dmodel}|cloud"); fi
        fi
    fi
    cands=("${locals[@]}" "${clouds[@]}")
    if [[ ${#cands[@]} -eq 0 ]]; then
        echo -e "${R}Aucun fournisseur utilisable.${N} Plugin ai_assistant absent/KO et aucune API directe configurée (${AI_CONF})." >&2
        return 1
    fi

    # ── 3. Choix manuel (liste) si demandé ──
    if [[ ${pick} -eq 1 ]]; then
        [[ ${tty} -eq 1 ]] || { echo "--pick nécessite un terminal." >&2; return 2; }
        local -a labels=("⚙️   Automatique (local d'abord, puis les suivants)")
        local cand
        for cand in "${cands[@]}"; do
            IFS='|' read -r _ id name prov model scope <<< "${cand}"
            labels+=("$([[ ${scope} == local ]] && echo '🏠' || echo '☁️ ')  ${name}  (${prov}/${model}, ${scope})")
        done
        labels+=("↩  Annuler")
        nav_menu "Fournisseur IA" "${labels[@]}"
        [[ ${MENU_RESULT} -eq -1 || ${MENU_RESULT} -eq $(( ${#labels[@]} - 1 )) ]] && return 0
        [[ ${MENU_RESULT} -gt 0 ]] && cands=("${cands[$(( MENU_RESULT - 1 ))]}")
    fi

    # ── 4. Essais successifs ──
    local allowed; allowed=" $(_ai_conf_get AI_ALLOWED_CLOUD) "
    local resp="${wd}/reponse.txt" txt="${wd}/analyse.txt" acts="${wd}/actions.tsv" raw_kept=""
    local cand ch msgf mapf status prc ok=0 used="" skipped=0
    for cand in "${cands[@]}"; do
        IFS='|' read -r ch id name prov model scope <<< "${cand}"
        if [[ "${scope}" == cloud ]]; then
            if [[ "${allowed}" != *" ${id} "* ]]; then
                if [[ ${tty} -eq 1 ]]; then
                    confirm "Envoyer le rapport ANONYMISÉ ($(wc -c < "${cloud}") octets) à ${name} (${prov}/${model}, cloud)" || { echo -e "  ${Y}– ${name} : refusé.${N}"; continue; }
                    confirm "Mémoriser ce fournisseur comme autorisé" && { _ai_conf_add AI_ALLOWED_CLOUD "${id}"; allowed+="${id} "; }
                else
                    skipped=$((skipped+1)); continue
                fi
            fi
            msgf="${cloud}"; mapf="${map}"
        else
            msgf="${full}"; mapf="${map_l}"
        fi
        echo -e "${DIM}→ ${name} (${prov}/${model}, ${scope})...${N}"
        rm -f "${resp}"
        if [[ "${ch}" == plugin ]]; then
            status=$(_ai_plugin_call "${wd}" "${id}" "${msgf}" "${sysf}" "${resp}" "${scope}"); prc=$?
            [[ ${prc} -eq 124 ]] && status="ERR|${id}|timeout (240 s)"
        else
            status=$(_ai_direct_call "${wd}" "${msgf}" "${sysf}" "${resp}"); prc=$?
        fi
        if [[ "${status}" != OK\|* ]]; then
            echo -e "  ${R}✘${N} échec : ${status#ERR|*|}"
            [[ ${prc} -eq 124 && "${scope}" == cloud ]] && echo -e "  ${Y}⚠ après un timeout, le fournisseur a peut-être déjà reçu le rapport.${N}"
            log_action "ASK ${name} (${scope}) ÉCHEC"
            continue
        fi
        if AI_IN="${resp}" AI_OUT="${txt}" AI_ACT="${acts}" php -r "${_AI_RENDER_PHP}"; then
            ok=1; used="${name} (${prov}/${model}, ${scope})"; log_action "ASK ${name} (${scope}) OK"
            _ai_deanon "${mapf}" < "${txt}" > "${txt}.d" && mv "${txt}.d" "${txt}"
            break
        fi
        echo -e "  ${Y}⚠${N} réponse non structurée (JSON attendu), essai suivant"
        raw_kept="${wd}/raw_$(date +%s).txt"; cp "${resp}" "${raw_kept}"
        log_action "ASK ${name} (${scope}) réponse non structurée"
    done

    [[ ${skipped} -gt 0 ]] && echo -e "${DIM}  ${skipped} fournisseur(s) cloud ignoré(s) : non autorisés (accord interactif, ou AI_ALLOWED_CLOUD dans ${AI_CONF}).${N}"
    if [[ ${ok} -ne 1 ]]; then
        echo -e "\n${R}✘ Aucune analyse exploitable.${N}"
        if [[ -n "${raw_kept}" ]]; then
            echo -e "${Y}Dernière réponse brute (non structurée, aucune action proposée) :${N}\n"
            tr -d '\000-\010\013-\037\177' < "${raw_kept}" | head -c 4000; echo
        fi
        return 1
    fi

    # ── 5. Affichage ──
    local grav; grav=$(sed -n 's/^GRAVITE=//p' "${txt}"); sed -i '/^GRAVITE=/d' "${txt}"
    local gc="${W}"; case "${grav}" in critique) gc="${R}" ;; majeur) gc="${Y}" ;; mineur) gc="${C}" ;; info) gc="${G}" ;; esac
    echo -e "\n${B}══ Analyse IA — ${used} ══${N}"
    echo -e "Gravité : ${gc}${grav}${N}"
    cat "${txt}"

    # ── 6. Actions : propositions seulement, confirmation obligatoire ──
    local aid reason spec flag risk desc n=0 shown=0
    local out="${txt}"
    if [[ -s "${acts}" ]]; then
        echo -e "\n${W}Actions proposées :${N}"
        # Fichier lu sur le descripteur 3 : confirm() lit le CLAVIER (stdin). Avec `done < fichier`,
        # la confirmation consommerait des caractères du texte de l'IA (auto-confirmation possible).
        while IFS=$'\t' read -r -u 3 aid reason; do
            n=$((n+1))
            if [[ -z "${AI_ACTIONS[${aid}]:-}" ]]; then
                printf '  %b%s. « %s » : hors catalogue, ignorée%b\n' "${DIM}" "${n}" "${aid:0:40}" "${N}"; continue
            fi
            spec="${AI_ACTIONS[${aid}]}"; flag="${spec%%|*}"; risk=$(cut -d'|' -f2 <<< "${spec}"); desc="${spec#*|*|}"
            echo -e "  ${n}. ${W}${aid}${N} — ${desc} ${DIM}[${risk}]${N}"
            printf "     raison de l'IA : %s\n" "$(_ai_deanon "${mapf}" <<< "${reason:0:200}")"
            echo "     commande : jeehelp ${flag}" >> /dev/null
            if [[ ${tty} -eq 1 ]]; then
                if confirm "     Exécuter « jeehelp ${flag} » (${risk})"; then
                    echo; bash "${_SELF}" "${flag}"; local arc=$?
                    echo -e "     ${DIM}→ code retour ${arc}${N}"; log_action "ASK action ${aid} confirmée, rc=${arc}"
                else
                    echo -e "     ${DIM}non exécutée${N}"
                fi
            fi
            shown=$((shown+1))
        done 3< "${acts}"
        [[ ${tty} -eq 0 && ${shown} -gt 0 ]] && echo -e "  ${DIM}(hors terminal : propositions seulement, rien n'est exécuté)${N}"
    fi

    # ── 7. Conservation de l'analyse (sans le rapport) ──
    local f="${LOG_DIR}/jeehelp_analyse_$(date +%Y%m%d-%H%M%S).txt"
    if ( set -C; { echo "Analyse IA — ${used} — $(date '+%F %T')"; echo "Gravité : ${grav}"; cat "${txt}"; } > "${f}" ) 2>/dev/null; then
        chown www-data:www-data "${f}" 2>/dev/null; chmod 640 "${f}"
        ls -t "${LOG_DIR}"/jeehelp_analyse_*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f
        echo -e "\n${DIM}Analyse enregistrée : ${f}${N}"
    fi
    [[ "${grav}" == critique ]] && return 2
    [[ "${grav}" == majeur ]] && return 1
    return 0
}

menu_ask() {
    header; section "Analyser le rapport avec l'IA"
    echo -e "  ${DIM}Local d'abord, puis les fournisseurs suivants. Cloud : rapport anonymisé + accord par fournisseur.${N}\n"
    ask_ai --pick
    pause
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
            _watchdog_check; local wd_rc=$?
            _ssl_check_auto; local ssl_rc=$?
            [[ ${wd_rc} -ne 0 || ${ssl_rc} -ne 0 ]] && rc=1 ;;
        --health)
            echo "[CLI] Health check complet..."
            show_health "cli"
            rc=$? ;;
        --report)
            generate_report cli
            rc=$? ;;
        --ask)
            shift
            ask_ai "$@"
            rc=$? ;;
        --fix-perms)
            echo "[CLI] Rétablissement des droits..."
            fix_permissions "cli"
            rc=$? ;;
        --upgrade-security)
            echo "[CLI] unattended-upgrade..."
            if command -v unattended-upgrade &>/dev/null; then
                unattended-upgrade -v 2>&1
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
            echo "  --check             Vérification rapide (code retour : 0 OK, 1 anomalie)"
            echo "  --health            Health check complet (code retour : 0 OK, 1 avertissement, 2 erreur)"
            echo "  --report            Rapport de diagnostic complet (code retour : 0 OK, 1 avertissement, 2 erreur)"
            echo "  --ask [options]     Analyse du rapport par IA (local d'abord) : --pick --provider ID --file F --channel auto|plugin|direct --with-logs --dry-run --include-invalid"
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
        "📝  Générer un rapport de diagnostic"
        "🤖  Analyser le rapport avec l'IA"
        "🆘  Mode secours (interface web injoignable)"
        "❌  Quitter"
    )

    while true; do
        nav_menu "Menu principal" "${opts[@]}"
        case $MENU_RESULT in
            -1|12) _exit_clean ;;
            0) show_system_info ;;
            1) menu_health      ;;
            2) menu_backups     ;;
            3) menu_database    ;;
            4) menu_services    ;;
            5) menu_logs        ;;
            6) menu_network     ;;
            7) menu_updates     ;;
            8) menu_cleanup     ;;
            9) menu_report      ;;
            10) menu_ask        ;;
            11) menu_rescue     ;;
        esac
    done
}

# ── Point d'entrée ───────────────────────────────────────────
[[ -n "$1" ]] && cli_mode "$@"
check_root
check_jeedom
# Le menu interactif lit le clavier en continu ; sans TTY (cron, stdin
# redirigé/fermé) read_key renverrait "eof" en boucle. La protection dans
# nav_menu suffit à ne plus boucler indéfiniment, mais autant refuser
# clairement ce mode ici plutôt que d'ouvrir un menu inutilisable.
if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Aucun terminal détecté : le menu interactif nécessite un TTY." >&2
    echo "Utilisez une option CLI, par exemple : sudo bash $0 --health" >&2
    exit 1
fi
main_menu

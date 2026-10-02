# jeehelp

Menu d'administration en ligne de commande pour une box Jeedom (Debian 11/12, Jeedom >= 4.4).
Un seul script bash, sans dépendance externe, pensé pour l'entretien courant d'une installation
Jeedom en SSH : sauvegardes, base de données, services, logs, réseau, mises à jour et sécurité.

Navigation interactive : ↑↓ sélection, ENTRÉE valider, ÉCHAP retour, CTRL+C quitter.
Chaque action sensible (restauration, suppression, reboot, mise à jour...) demande une
confirmation, et les actions sont journalisées dans `/var/log/jeedom-menu.log`.

## Installation

Sur la box Jeedom, en une commande (avec `curl`, présent par défaut sur Jeedom) :

```bash
curl -fsSL https://raw.githubusercontent.com/limad/jeehelp/beta/install.sh | sudo bash
```

Ou avec `wget` si `curl` n'est pas disponible :

```bash
wget -qO- https://raw.githubusercontent.com/limad/jeehelp/beta/install.sh | sudo bash
```

Cela installe la commande `jeehelp` dans `/usr/local/bin/jeehelp`.

### Installation depuis un clone local

```bash
git clone https://github.com/limad/jeehelp.git
cd jeehelp
sudo bash install.sh
```

## Utilisation

```bash
limad@Jeedom:~$ jeehelp
```

Lance le menu interactif. `jeehelp` nécessite les droits root (relance automatiquement un
message d'erreur si lancé sans `sudo`) et détecte Jeedom dans `/var/www/html`.

### Menu principal

| Section | Contenu |
|---|---|
| 📊 Informations système & watchdog | OS, uptime, charge, RAM, disque, version Jeedom, vérification watchdog |
| 🏥 Santé générale & droits fichiers | Diagnostic complet (PHP, MariaDB, services, daemon, disque, RAM, CPU, dernière sauvegarde, permissions, logs d'erreurs, SSL, mises à jour apt) + rétablissement des droits fichiers |
| 💾 Sauvegardes | Lister, créer, restaurer, supprimer, rotation (conserve les 3 dernières) |
| 🗄️ Base de données | ANALYZE / REPAIR / OPTIMIZE table par table, taille des tables, `mysqlcheck --auto-repair`, dump SQL complet, import d'un dump, vidage du cache Jeedom |
| ⚙️ Services & Jeedom | État des services, redémarrage Apache/Nginx, MariaDB, daemon Jeedom (cron), relance complète de Jeedom, reboot serveur |
| 📋 Logs & audit | Lister/afficher/suivre (`tail -f`) les logs Jeedom, vider tous les logs, journalctl système, journal d'audit des actions jeehelp |
| 🌐 Réseau & SSL | Interfaces réseau, test de connectivité internet, ports en écoute, connexions actives, ping, vérification SSL d'un domaine |
| 🔄 Mises à jour & sécurité | Vérifier/appliquer les mises à jour Jeedom, `apt update && upgrade`, configuration `unattended-upgrades` (reboot nocturne auto si patch noyau), dry-run et statut |
| 🧹 Nettoyage | Purge des vieilles sauvegardes, nettoyage de `/tmp` (avec aperçu et confirmation), analyse de l'espace disque, vidage de l'OPcache PHP, `apt autoremove` |
| 📝 Rapport de diagnostic | Document unique mettant en évidence tout ce qui peut justifier un blocage : état du core (cron, scénarios, démarrage, date), contrôles de la page Santé, accessibilité de l'interface et de la page de secours, plugins actifs avec état des daemons et dépendances, MariaDB (connexions, taille), ressources (disque, inodes, mémoire, swap, OOM), services et unités en échec, erreurs fatales PHP par plugin, messages Jeedom, sauvegardes, droits, réseau, mises à jour, actions récentes de jeehelp. Synthèse des erreurs/avertissements en tête ; enregistré dans `log/jeehelp_rapport_<date>.txt` (10 derniers conservés), sans secret |
| 🤖 Analyse par IA | `sudo jeehelp --ask` envoie le rapport à une IA et affiche gravité, causes probables (avec preuves tirées du rapport) et actions proposées. **Local d'abord** (Ollama sur le réseau local), puis les autres fournisseurs du plugin `ai_assistant` (via son script CLI, sans Apache ni clé API Jeedom), puis une API directe optionnelle (seul canal si Jeedom/MariaDB sont HS). **Cloud** : rapport anonymisé (IP, MAC, hôte, chemins, logs retirés, secrets masqués) et accord demandé par fournisseur. **L'IA ne fait que proposer** : seules les actions d'un catalogue fixe (`check`, `health`, `report`, `fix-perms`, `repair-db`, `backup`) sont reconnues, chacune demande une confirmation `[o/N]`, et rien n'est exécuté hors terminal ni à partir du texte de la réponse. Options : `--pick` (liste de choix), `--provider ID`, `--file rapport.txt`, `--channel auto\|plugin\|direct`, `--with-logs`, `--dry-run` (affiche la charge utile cloud sans rien envoyer) |
| 🆘 Mode secours | Pour quand l'interface web de Jeedom (y compris sa propre page de secours `index.php?v=d&p=database&rescue=1`) est injoignable. Teste l'accès à cette page web, et reproduit en CLI ses deux actions clés : désactiver tous les plugins, activer/désactiver le système cron. Actions journalisées dans `log/jeehelp_rescue.log` (visible depuis Jeedom une fois l'interface de nouveau accessible) en plus du journal d'audit |

### Mode CLI (non-interactif)

```bash
sudo jeehelp --backup            # Lancer une sauvegarde Jeedom
sudo jeehelp --repair-db         # REPAIR TABLE sur toutes les tables
sudo jeehelp --check             # Vérification rapide (watchdog + SSL)
sudo jeehelp --health            # Health check complet (équivalent au menu "Santé")
sudo jeehelp --report            # Rapport de diagnostic complet (code retour : 0 OK, 1 avertissement, 2 erreur)
sudo jeehelp --ask               # Analyse du rapport par IA (voir ci-dessous)
sudo jeehelp --fix-perms         # Rétablir les droits fichiers de /var/www/html
sudo jeehelp --upgrade-security  # Lancer unattended-upgrade immédiatement
```

Utile pour un cron ou un script d'automatisation externe à Jeedom (ex. `jeehelp --check` en
cron quotidien, ou `jeehelp --backup` avant une mise à jour manuelle).

## Mise à jour

Relancer la commande d'installation : elle télécharge la dernière version de `jeehelp.sh`
depuis la branche `beta` et remplace `/usr/local/bin/jeehelp`.

## Analyse par IA : configuration

Rien n'est requis si le plugin `ai_assistant` a au moins un fournisseur configuré. Fichier optionnel `/etc/jeehelp/ai.conf` (root, mode 600) :

```ini
AI_ALLOWED_CLOUD="2386 direct"   # fournisseurs cloud déjà autorisés (rempli par l'accord interactif)
AI_ORDER="2981 2386"             # ordre de préférence des fournisseurs cloud
AI_DIRECT_URL="https://api.openai.com/v1/chat/completions"   # canal direct (API compatible OpenAI)
AI_DIRECT_MODEL="gpt-4o-mini"
AI_DIRECT_KEY="..."              # facultatif (inutile pour un Ollama local)
```

Le script `plugins/ai_assistant/core/php/ai_assistant.cli.php` (`list`, `ask`) est fourni par le plugin ; il refuse les équipements en mode `jeeAssist` sans confirmation et ceux dont le repli entre fournisseurs est actif.

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
| 🏥 Santé générale & droits fichiers | Diagnostic complet (PHP, MySQL, services, daemon, disque, RAM, CPU, dernière sauvegarde, permissions, logs d'erreurs, SSL, mises à jour apt) + rétablissement des droits fichiers |
| 💾 Sauvegardes | Lister, créer, restaurer, supprimer, rotation (conserve les 7 dernières) |
| 🗄️ Base de données | ANALYZE / REPAIR / OPTIMIZE table par table, taille des tables, `mysqlcheck --auto-repair`, dump SQL complet, import d'un dump, vidage du cache Jeedom |
| ⚙️ Services & Jeedom | État des services, redémarrage Apache/Nginx, MySQL/MariaDB, daemon Jeedom (cron), relance complète de Jeedom, reboot serveur |
| 📋 Logs & audit | Lister/afficher/suivre (`tail -f`) les logs Jeedom, vider tous les logs, journalctl système, journal d'audit des actions jeehelp |
| 🌐 Réseau & SSL | Interfaces réseau, test de connectivité internet, ports en écoute, connexions actives, ping, vérification SSL d'un domaine |
| 🔄 Mises à jour & sécurité | Vérifier/appliquer les mises à jour Jeedom, `apt update && upgrade`, configuration `unattended-upgrades` (reboot nocturne auto si patch noyau), dry-run et statut |
| 🧹 Nettoyage | Purge des vieilles sauvegardes, nettoyage de `/tmp` (avec aperçu et confirmation), analyse de l'espace disque, vidage de l'OPcache PHP, `apt autoremove` |
| 🆘 Mode secours | Pour quand l'interface web de Jeedom (y compris sa propre page de secours `index.php?v=d&p=database&rescue=1`) est injoignable. Teste l'accès à cette page web, et reproduit en CLI ses deux actions clés : désactiver tous les plugins, activer/désactiver le système cron. Actions journalisées dans `log/jeehelp_rescue.log` (visible depuis Jeedom une fois l'interface de nouveau accessible) en plus du journal d'audit |

### Mode CLI (non-interactif)

```bash
sudo jeehelp --backup            # Lancer une sauvegarde Jeedom
sudo jeehelp --repair-db         # REPAIR TABLE sur toutes les tables
sudo jeehelp --check             # Vérification rapide (watchdog + SSL)
sudo jeehelp --health            # Health check complet (équivalent au menu "Santé")
sudo jeehelp --fix-perms         # Rétablir les droits fichiers de /var/www/html
sudo jeehelp --upgrade-security  # Lancer unattended-upgrade immédiatement
```

Utile pour un cron ou un script d'automatisation externe à Jeedom (ex. `jeehelp --check` en
cron quotidien, ou `jeehelp --backup` avant une mise à jour manuelle).

## Mise à jour

Relancer la commande d'installation : elle télécharge la dernière version de `jeehelp.sh`
depuis la branche `beta` et remplace `/usr/local/bin/jeehelp`.

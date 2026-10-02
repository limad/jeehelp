# jeehelp

Menu d'administration en ligne de commande pour une box Jeedom (Debian 11/12, Jeedom >= 4.4).

Navigation interactive : ↑↓ sélection, ENTRÉE valider, ÉCHAP retour, CTRL+C quitter.

## Installation

Sur la box Jeedom, en une commande :

```bash
curl -fsSL https://raw.githubusercontent.com/limad/jeehelp/beta/install.sh | sudo bash
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

Mode interactif par défaut, ou en ligne de commande :

```bash
sudo jeehelp --backup
sudo jeehelp --repair-db
sudo jeehelp --check
sudo jeehelp --upgrade-security
```

## Mise à jour

Relancer la commande d'installation : elle télécharge la dernière version de `jeehelp.sh`
depuis la branche `beta` et remplace `/usr/local/bin/jeehelp`.

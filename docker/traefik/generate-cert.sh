#!/bin/sh
set -eu

# Certificat local auto-signé pour les noms de domaine réels (voir /etc/hosts).
# Les routeurs Traefik et l'application ne connaissent que ces noms-là, en
# développement comme en production : seule la source du certificat change
# (ici, résolveur ACME sur le serveur). La clé reste locale et n'est pas
# versionnée.
CERT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/certs"
mkdir -p "$CERT_DIR"

# Git Bash convertit /CN=... en chemin Windows ; cygpath garde des chemins
# compatibles avec OpenSSL sous MSYS.
if command -v cygpath >/dev/null 2>&1; then
  CERT_DIR_OPENSSL="$(cygpath -w "$CERT_DIR")"
else
  CERT_DIR_OPENSSL="$CERT_DIR"
fi

MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -keyout "$CERT_DIR_OPENSSL/yabiladi.com.key" \
  -out "$CERT_DIR_OPENSSL/yabiladi.com.crt" \
  -subj "/CN=yabiladi.com" \
  -addext "subjectAltName=DNS:yabiladi.com,DNS:www.yabiladi.com,DNS:en.yabiladi.com,DNS:es.yabiladi.com,DNS:ar.yabiladi.com,DNS:it.yabiladi.com,DNS:m.yabiladi.com,DNS:rac.yabiladi.com,DNS:static.yabiladi.com,DNS:regional.yabiladi.com,DNS:tribunes.yabiladi.com,DNS:islam.yabiladi.com,DNS:communiques.yabiladi.com,DNS:dagu.yabiladi.com,DNS:navidrome.yabiladi.com,DNS:backups.yabiladi.com,DNS:grafana.yabiladi.com,DNS:traefik.yabiladi.com,DNS:ws.yabiladi.com,DNS:localhost,IP:127.0.0.1"

printf 'Certificat généré : %s\n' "$CERT_DIR/yabiladi.com.crt"

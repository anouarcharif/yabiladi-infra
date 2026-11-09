# Outil de chiffrement des secrets (SOPS + Age).
#
# Le serveur se déploie par « git pull » ; les secrets doivent donc voyager avec
# le dépôt. Ils y voyagent chiffrés, et ce conteneur est la seule chose capable
# de les relire. Embarquer l'outil dans une image plutôt que l'installer sur
# l'hôte tient à deux faits mesurés sur la cible (Debian 12 chez OVH) :
#   - « age » est dans le dépôt Debian (1.1.1-1), « sops » n'y est pas du tout ;
#   - exiger « apt install » au moment du déploiement, c'est rendre un déploiement
#     dépendant d'un miroir Debian disponible.
# Ici, le seul prérequis de la machine est Docker, déjà obligatoire pour le reste.
#
# Provenance : sops v3.13.3, empreinte sha256 relevée dans sops-v3.13.3.checksums.txt
# (e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b), vérifiée à la
# construction. Sans cette vérification, n'importe quelle interposition sur le
# téléchargement injecterait un binaire qui lit la clé privée avant tout le monde.
FROM debian:12-slim

ARG SOPS_VERSION=3.13.3
ARG SOPS_SHA256=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b

RUN apt-get update \
 && apt-get install -y --no-install-recommends age ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL --retry 3 -o /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
 && echo "${SOPS_SHA256}  /usr/local/bin/sops" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/sops

ENTRYPOINT ["/usr/local/bin/sops"]

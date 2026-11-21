# Installation de Yabiladi Docker Admin

## Pré-requis

Docker Compose v2 et Python 3.8 ou plus récent sont requis sur le nœud.

Déployer d'abord l'infrastructure avec `../deploy.sh`. Elle crée le réseau
`yabiladi_app`, démarre Traefik et matérialise les secrets Komodo depuis
`deploy/secrets/komodo.sops.bin` vers `docker/legacy/komodo.env`.

Le compte Basic Auth partagé doit aussi être matérialisé depuis le coffre. Le
Core Komodo le lit dans le middleware Traefik ; l'authentification Komodo reste
une seconde étape.

## Déploiement

Le script racine enchaîne automatiquement le déploiement docker-admin. Pour le
rejouer seul :

```bash
bash docker-admin/scripts/deploy.sh --dry-run
bash docker-admin/scripts/deploy.sh
bash docker-admin/scripts/validate.sh
```

Le déploiement sélectionne les services selon `YABILADI_NODE` :

| Profil | Services |
| --- | --- |
| `imouzzer` | Core, MongoDB et Periphery |
| `tarourt` | Periphery seule, connexion sortante vers le Core Imouzzer |
| `local` | Core, MongoDB et Periphery |

L'amorçage authentifie le compte admin Komodo depuis le secret SOPS et crée
automatiquement les clés d'onboarding nécessaires. Aucune étape manuelle dans
l'interface n'est requise. Chaque clé privée est persistée dans
`docker/legacy/komodo-onboarding-<nœud>.key`, séparément du secret SOPS, afin
qu'un `git pull` et les redéploiements la conservent. Le fichier est limité au
mode `0600` sur Linux et au compte courant par ACL sur Windows.

Tarourt n'héberge pas le Core ni MongoDB : `komodo-tarourt.yabiladi.com` ne
sert donc pas l'interface. Un basculement DNS vers Tarourt ne suffit pas en cas
de panne d'Imouzzer ; il faudrait aussi y démarrer/restaurer le Core, MongoDB et
les données persistantes Komodo.

Les volumes MongoDB, clés et sauvegardes sont nommés et externes. Le script
remplace les conteneurs sans supprimer ces volumes. Les anciens conteneurs
Komodo du projet `yabiladi-infra` sont retirés lors de leur migration vers
`yabiladi-docker-admin`.

## Poste local

Définir `YABILADI_NODE=local`, puis ajouter cette entrée au fichier hosts :

```text
127.0.0.1 komodo-imouzzer.yabiladi.com komodo.yabiladi.com
```

`docker-admin/compose.override.yaml` désactive le résolveur Let's Encrypt sur
ce poste. Traefik utilise alors le certificat local. L'URL est
`https://komodo.yabiladi.com` ; `https://komodo-imouzzer.yabiladi.com` reste
l'URL canonique de production et est également routé vers le même Core.

Le certificat doit couvrir ce nom et être approuvé par Chrome. Depuis Git Bash,
régénérer le certificat local (à refaire après toute régénération) :

```bash
bash docker/traefik/generate-cert.sh
```

Puis, depuis PowerShell à la racine du dépôt, ajouter uniquement le certificat
public au magasin racine de l'utilisateur Windows :

```powershell
certutil -user -f -addstore Root .\docker\traefik\certs\yabiladi.com.crt
docker compose restart traefik
```

Confirmer l’ajout de l’autorité racine si Windows le demande. Chrome utilise ce
magasin Windows ; le redémarrer s'il était déjà ouvert. Ne jamais importer ni
distribuer `yabiladi.com.key`.

## Comptes Komodo

Sur une base MongoDB neuve, le premier compte créé devient administrateur et
est activé automatiquement. Les comptes créés ensuite sont désactivés par
défaut : un administrateur doit ouvrir la gestion des utilisateurs et choisir
**Enable User** pour le compte concerné. Ne pas activer l’auto-activation de
tous les nouveaux comptes en production sans décision explicite.

Les comptes et leurs rôles persistent dans `yabiladi_komodo_mongo_data`.
Redéployer ou recréer les conteneurs ne réinitialise donc pas le premier
administrateur. Sur un serveur déjà initialisé, conserver l’accès au compte
administrateur existant ; la création d’un compte supplémentaire ne le remplace
pas.

## Supervision

Les journaux des conteneurs et leurs mesures d'utilisation sont consultables
dans Komodo. Periphery collecte les statistiques des conteneurs toutes les
cinq secondes. MongoDB stocke l'état Core dans `yabiladi_komodo_mongo_data` et
les clés générées dans `yabiladi_komodo_keys`; ne supprimer aucun de ces volumes
lors d'une réinstallation.

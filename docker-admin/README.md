# Yabiladi Docker Admin — Komodo

Komodo est la console d'administration des conteneurs Docker. Son Core, sa base
MongoDB et le Periphery local sont déployés ici, dans le projet Compose
`yabiladi-docker-admin`. Le Periphery de Tarourt utilise le même projet et se
connecte au Core d'Imouzzer en mode sortant.

Komodo remplace Dozzle pour les deux besoins de supervision de cette pile :
journaux des conteneurs et mesures CPU/mémoire. Periphery collecte les mesures
des conteneurs toutes les cinq secondes (`PERIPHERY_CONTAINER_STATS_POLLING_RATE`).

## Accès et sécurité

Le Core est servi sur `https://komodo-imouzzer.yabiladi.com` et l'alias
`https://komodo.yabiladi.com`, derrière Traefik et le Basic Auth bcrypt partagé,
puis l'authentification Komodo. Son port 9120 n'est publié que sur le loopback.
Le Periphery n'expose aucun port et se connecte au Core en sortie.

Periphery monte le socket Docker pour administrer l'hôte ; ce droit équivaut à
un contrôle complet du moteur Docker. Les API terminal et exec de Periphery
restent désactivées. Dozzle et son `docker-socket-proxy` ont été retirés : ils
ne sont pas nécessaires pour consulter les journaux et mesures dans Komodo.
Voir [docs/security.md](docs/security.md).

## Déploiement

```bash
bash docker-admin/scripts/deploy.sh --dry-run
bash docker-admin/scripts/deploy.sh
bash docker-admin/scripts/validate.sh
```

Le déploiement complet `../deploy.sh` matérialise d'abord les secrets du coffre
puis enchaîne ce script. Le déploiement autonome suppose donc que
`docker/legacy/komodo.env` a déjà été matérialisé sur le nœud serveur.

Le script amorce aussi automatiquement l'appairage des Periphery avec Core à
partir du compte admin Komodo contenu dans le secret. Les clés privées sont
persistées localement, hors SOPS et hors Git ; aucune création ni acceptation
manuelle dans l'interface n'est nécessaire.

Le profil `local` sert Komodo sur `komodo.yabiladi.com`; sur le poste, ajouter
`127.0.0.1 komodo.yabiladi.com` au fichier hosts. En production, l'URL canonique
est `komodo-imouzzer.yabiladi.com`. Le profil de production choisit
Core/MongoDB/Periphery sur Imouzzer et Periphery seul sur Tarourt.

Les volumes MongoDB, clés Komodo et sauvegardes sont nommés et externes ; le
déploiement remplace les conteneurs sans supprimer ces volumes. `komodo_backups`
est partagé en lecture seule avec DBackup.

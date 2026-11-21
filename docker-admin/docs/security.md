# Sécurité de Yabiladi Docker Admin

## Accès au Core

Le routeur Komodo de Traefik utilise le fichier bcrypt partagé
`docker/traefik/htpasswd/user_yabiladi`. Après ce Basic Auth, Komodo impose sa
propre authentification. Le port 9120 du Core est publié uniquement sur
`127.0.0.1`; l'accès public passe par Traefik en HTTPS. MongoDB et Periphery
n'ont aucun port publié sur l'hôte.

Traefik conserve le Basic Auth sur l'interface. Seuls `/auth`,
`/read/ListOnboardingKeys`, `/write/CreateOnboardingKey`,
`/write/UpdateOnboardingKey` et `/ws/periphery` sont routés sans ce middleware :
Komodo protège les appels de gestion de clé par un JWT admin, et le WebSocket
Periphery par le handshake cryptographique d'onboarding. Ces routes permettent
l'amorçage et la connexion sortante de Tarourt sans identifiants Basic Auth
supplémentaires.

Le compte Komodo doit recevoir les permissions minimales nécessaires. Komodo
permet notamment de limiter séparément la lecture des journaux, l'inspection et
les actions sur les ressources : [documentation des permissions Komodo](https://komo.do/docs/configuration/permissioning).

## Autorité Docker de Periphery

Periphery monte `/var/run/docker.sock` pour gérer les conteneurs de l'hôte.
Cette socket équivaut à un accès administrateur au moteur Docker et donc à
l'hôte ; ce n'est pas une connexion en lecture seule. La désactivation de ses
API terminal et exec réduit les fonctions exposées, mais ne retire pas cette
autorité Docker.

Le montage est conservé parce que l'objectif est de centraliser
l'administration, les journaux et les mesures dans Komodo. Le socket proxy et
Dozzle ont été supprimés : Dozzle n'apportait plus de fonction requise que
Komodo ne fournisse déjà.

Periphery communique avec Core en mode sortant depuis Tarourt. Core et Periphery
se trouvent sur `yabiladi_app` à Imouzzer ; Core est le seul service Komodo
publié par Traefik. MongoDB n'est pas publié, mais partage ce réseau Docker pour
la connexion du Core.

Les clés privées d'onboarding sont créées par l'API Core et persistées par nœud
dans `docker/legacy/komodo-onboarding-<nœud>.key` (mode `0600`, exclu de Git et
du coffre SOPS). Le script vérifie et réactive leur enregistrement privilégié
à chaque déploiement. Une clé privilégiée peut mettre à jour la clé publique
d'un serveur existant ; ces fichiers doivent rester accessibles uniquement au
déploiement et au conteneur Periphery du même nœud.

## Journaux et mesures

Les journaux sont consultés dans l'interface Komodo via Periphery. Les mesures
CPU/mémoire des conteneurs sont interrogées toutes les cinq secondes par
`PERIPHERY_CONTAINER_STATS_POLLING_RATE`. Cela fournit une actualisation proche
du temps réel sans ajouter un second service ayant accès au moteur Docker.

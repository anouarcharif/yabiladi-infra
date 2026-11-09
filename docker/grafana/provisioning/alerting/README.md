# Alerting Grafana provisionné par fichiers.

Grafana relit ce répertoire au démarrage et sur `POST
/api/admin/provisioning/alerting/reload`. Trois rôles, cinq fichiers :

| Fichier | Ce qu'il décrète |
| --- | --- |
| `contact_points.yaml` | OÙ le message part (destinataire et canal). |
| `notification_policies.yaml` | QUAND il part, combien de fois, et à qui va chaque règle. |
| `alert_rules_radio.yaml` | CE QUI EST surveillé (les requêtes Loki et les seuils). |
| `alert_rules_email.yaml` | Rebonds du relais Postfix, dossier « Applications ». |
| `alert_rules_containers.yaml` | Arrêt d'un conteneur critique, dossier « Infrastructure ». |

Le dashboard qui montre les mêmes signaux est en face,
`docker/grafana/dashboards/radio/yabiladi-radio-sante.json` : les règles disent
« ça casse », la page dit « où ».

Les règles « Emails sortants » portent `team: email` et ont leur route dans
`notification_policies.yaml`, placée avant celles de `severity` : leur cadence
de rappel (4 h) est celle d'une rafale de rebonds liée à un lot, pas celle
d'une antenne muette. Le récepteur reste `yabiladi-radio-alertes` — c'est la
seule adresse configurée ; le jour où un contact point dédié existe, seule la
ligne `receiver:` de cette route change.

# Le contact point mail ne vaut rien sans GF_SMTP_ENABLED

Réglé dans `compose.yaml` (bloc `grafana.environment`). Sans lui, Grafana
enregistre la notification, l'affiche dans son interface et n'envoie rien : le
provisioning réussit, aucune erreur nulle part. Le transport est Resend via son
relais SMTP authentifié (`smtp.resend.com:587`), sur le serveur comme sur un
poste de développement : une alerte testée ici part donc réellement. Le mot de
passe est dérivé par `deploy.sh` depuis `BOT_MONITOR_MAILER_DSN` (coffre SOPS)
et monté en secret Docker (`/run/secrets/grafana_smtp_password`). Pour rendre
une notification muette le temps d'un essai, couper `GF_SMTP_ENABLED` plutôt
que de changer d'hôte.

# Une clef mal nommée = règle silencieusement inactive

Contrairement aux tableaux de bord, un fichier d'alerting mal formé n'est pas
signalé dans l'interface. Pire, au démarrage, l'échec du module `provisioning`
entraîne celui de `*ngalert.AlertNG` et le conteneur repart en boucle avec,
seul, `rule group has no folder set` dans les journaux. Choses mesurées sur
grafana/grafana:13.3.0, dans cet ordre :

- contact points : la clef `notifiers:` (celle des versions 10 et 11, encore
  recopiée dans beaucoup d'exemples) n'est plus lue du tout — pas d'erreur, rien
  n'est provisionné, et la politique répond alors « receiver … does not exist ».
  La forme est `contactPoints: [{orgId, name, receivers: [{uid, type,
  settings}]}]`, et c'est le `name` de l'entrée que citent les `receiver:` des
  politiques.
- groupes de règles : `folder:` (le NOM du dossier) est obligatoire au niveau du
  groupe ; `folderUid:` y est ignoré.
- requêtes : `relativeTimeRange` non nul (`{ from: 60, to: 0 }`), sinon
  « invalid relative time range [From: 0s, To: 0s] ».
- `settings` : renvoyés au modèle Go du canal, les types comptent — `singleEmail:
  "false"` (chaîne) fait échouer le rechargement avec HTTP 500 et le message
  « cannot unmarshal string into Go struct field Config.singleEmail of type
  bool ».
- le texte des règles peut être accentué sans échappement : titres, résumés et
  descriptions avec accents et tirets demi-cadrins sont acceptés par le
  rechargement (vérifié par reload, pas supposé).

# Une variable de tableau de bord ne traverse pas l'alerting

Constaté le 2026-11-09 : les dix règles « conteneur arrêté » étaient toutes en
`Alerting` alors que la pile tournait, et le mail annonçait chaque conteneur
down. La requête des règles recopiait `instance="$serveur"` du tableau
« État des conteneurs ». `$serveur` est une variable `templating` : le
frontend la résout pour un panneau, jamais pour une règle évaluée côté
serveur. La chaîne part donc littéralement chez Prometheus,
`instance="$serveur"` ne matche aucune série, et la règle conclut à l'arrêt.
Preuve mesurée à la main : la même requête renvoie `0` avec
`instance="$serveur"` et `1` avec `job="docker"` quand le conteneur tourne.

Dans une règle d'alerte, on filtre donc par `job="docker"` (l'étiquette posée
par le scrape de `docker/prometheus.yml`), jamais par une variable de tableau
de bord, et jamais par `instance="yabiladi"` recopié : ce nom est déjà écrit
en dur dans `prometheus.yml` et le dupliquer ici créerait un troisième endroit
à changer avec `LOG_HOSTNAME`.

# Retirer un fichier ne retire pas ses règles

Mesuré ici : une règle déclarée dans un fichier, puis le fichier supprimé,
reste dans l'instance avec `provenance: file` après rechargement ET après
redémarrage du conteneur, et l'API refuse de la supprimer (`409
alerting.provenanceMismatch`). Le provisioning d'alerting est donc un
`upsert`, pas une synthèse. Conséquence pratique : renommer un `uid:` ou
supprimer un groupe se fait sur une instance neuve, pas en cours d'exploitation
— sinon la règle fantôme reste listing.

Pour la retirer quand même, la nommer dans le bloc `deleteRules:` du fichier
(niveau racine, à côté de `groups:`). Vérifié le 2026-11-09 sur
grafana/grafana:13.3.0 : les UID `container-down` et `container-mass-down`,
absents des fichiers depuis le découpage par conteneur, ont disparu après le
redémarrage de Grafana, sans intervention sur la base SQLite.

# Contrôles

```
# relecture des fichiers (le 500 et son message ne sortent que dans les journaux)
curl -s -X POST -u "$usager:$motdepasse" http://127.0.0.1:8088/api/admin/provisioning/alerting/reload
# ce qui est réellement provisionné
… /api/v1/provisioning/contact-points | … /api/v1/provisioning/policies | … /api/v1/provisioning/alert-rules
# états et santé de chaque évaluation (le seul endroit où l'on voit Error/NoData)
… /api/ruler/grafana/api/v1/rules
# ce que l'alertmanager retient comme en cours
… /api/alertmanager/grafana/api/v2/alerts
# les transitions d'état, dans l'ordre
… '/api/annotations?limit=25&type=alert'
```

Côté courriel, sur le poste de développement comme sur le serveur : `docker
compose logs --tail=100 postfix` doit montrer la remise (`status=sent`) du
message parti de `webmaster@yabiladi.com` vers le destinataire du contact point,
et `docker compose exec postfix postqueue -p` doit répondre vide.

Une notification n'arrive pas dans la seconde : `group_wait` attend
30 s (critique) ou 1 min (avertissement) après le passage en `Alerting`, et le
retard propre de la règle s'ajoute — les règles de battement prennent
15 min sans ligne plus 5 min de `for:` avant d'écrire quoi que ce soit.

# Ce répertoire n'est pas le seul endroit où l'alerting vit

L'état courant des règles, leur historique et les silenceurs ne se mettent
JAMAIS par fichier : un fichier provisionné écrase l'interface à chaque
rechargement. Toute règle créée à la main dans l'UI d'un autre dossier survit,
mais hérite de la politique racine de `notification_policies.yaml` — relire ce
que cela veut dire avant d'ajouter une deuxième pile d'alertes ici.

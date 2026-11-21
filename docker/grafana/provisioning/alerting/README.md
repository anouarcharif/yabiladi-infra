# Alerting Grafana provisionné par fichiers.

Le contact point email inclut l'URL publique de l'instance Grafana dans le sujet
et le corps. Avec `grafana-tarourt.yabiladi.com` ou
`grafana-imouzzer.yabiladi.com`, chaque notification identifie donc le nœud qui
a déclenché l'alerte, sans dupliquer les règles provisionnées.

Grafana relit ce répertoire au démarrage et sur `POST
/api/admin/provisioning/alerting/reload` — ce POST est désormais la dernière
étape du déploiement (`reload_grafana_alerting()` dans `deploy.sh`) : les
fichiers étant montés, un `git pull` qui ajoute une règle ne provisionne rien
tant que le conteneur tourne déjà. Trois rôles, six fichiers :

| Fichier | Ce qu'il décrète |
| --- | --- |
| `contact_points.yaml` | OÙ le message part (destinataire et canal). |
| `notification_policies.yaml` | QUAND il part, combien de fois, et à qui va chaque règle. |
| `alert_rules_radio.yaml` | CE QUI EST surveillé (les requêtes Loki et les seuils). |
| `alert_rules_email.yaml` | Envois et rebonds du relai Stalwart (dépôt `Yabiladi-Mailer` depuis le 2026-11-19), dossier « Applications ». |
| `alert_rules_containers.yaml` | Arrêt d'un conteneur critique, dossier « Infrastructure ». |
| `alert_rules_crash.yaml` | Crash d'un processus À L'INTÉRIEUR d'un conteneur qui reste Up, dossier « Infrastructure ». |

# Un conteneur vert peut porter un composant mort

Constaté le 2026-11-15 : le worker Buddy du conteneur manticore meurt en boucle
(`abnormal exit, status=255`) pendant que le conteneur est Up, que searchd
répond sur `/sql` et que `container-manticore-down` reste inactive. Ses règles
lisent `container_last_seen` : tant que le conteneur vit, la série vit, et le
crash d'un composant interne ne change AUCUNE métrique. La couverture de ces
morts-là ne peut donc être qu'une ligne de log — c'est `alert_rules_crash.yaml`.

Deux pièges mesurés avant d'écrire la moindre expression :

- **L'écho de Loki.** Loki journalise chaque requête reçue, texte compris. Une
  règle dont le motif est `fatal error` alimente donc son propre compteur quand
  elle cible `service="loki"` : relevé 996 lignes en sept jours pour le seul
  motif retenu, 4 629 pour `panic:`. D'où zéro règle de crash pour loki, grafana,
  alloy, prometheus, node-exporter et cadvisor — ils restent couverts par leurs
  règles « … arrêté ».
- **Les marqueurs qui ne sont pas des crashs.** `exited on signal` : 57 lignes
  sur sept jours dans php, toutes en signal 15 (SIGTERM), la fermeture normale
  d'un worker au chômage. `exit status 1` : les arrêts demandés par le
  superviseur des quatre antennes. `level=error` : 304 lignes/jour pour Loki, 53
  pour Alloy. `Uncaught PHP Exception` : 522 réponses 500 du site en sept jours.
  Les motifs retenus sont listés avec leur compte de sept jours dans l'en-tête du
  fichier ; `noDataState: y est OK` (ici, le silence est l'état souhaité),
  contraire des règles « … arrêté » où l'absence de série EST l'alarme. Ce
  n'est pas qu'une question de bruit : `sum(count_over_time(…))` sur une fenêtre
  vide ne renvoie **aucune série**, pas `0` — une règle `noDataState: Alerting`
  hurlerait donc en permanence sur une pile saine, et `noDataState: OK` est aussi
  ce qui lui permet de s'éteindre (voir l'essai ci-dessous).

Une règle a été jouée de bout en bout le 2026-11-15 : une ligne de crash
injectée sur le flux stderr du conteneur php (`/proc/1/fd/2`, son stdout étant
`/dev/null`) fait passer `container-php-crash` de `inactive` à `firing` à
l'évaluation suivante, avec le titre et le label `container` attendus chez
l'Alertmanager. La fin d'alerte a été vérifiée pareil : dix minutes plus tard,
quand la ligne est sortie de la fenêtre `[10m]`, les annotations d'état sont
passées de `A=B=C=1` (20:53:10) à `A=B=C=-1` (21:03:10) — le `-1` est la valeur
Grafana de NoData, donc l'extinction passe bien par l'absence de ligne dans la
fenêtre, jamais par un `0`. Alertmanager ne tenait alors plus aucune alerte
active, et les douze règles du groupe étaient récapitulées
`state=inactive health=ok`. La livraison du message lui-même n'a
pas été revérifiée ici ; le transport est documenté plus haut.

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
poste de développement : une alerte testée ici part donc réellement — à
condition que la connexion aboutisse, voir la section suivante. Le mot de
passe est dérivé par `deploy.sh` depuis `BOT_MONITOR_MAILER_DSN` (coffre SOPS)
et monté en secret Docker (`/run/secrets/grafana_smtp_password`). Pour rendre
une notification muette le temps d'un essai, couper `GF_SMTP_ENABLED` plutôt
que de changer d'hôte.

# Une notification dont le transport échoue n'est pas rejouée

Mesuré le 2026-11-17 sur le poste de développement, à propos d'une alerte
d'antenne passée en `firing` à 16:58:40 :

```
logger=ngalert.notifier level=warn component=alertmanager
msg="Notify for alerts failed" num_alerts=1
err="yabiladi-radio-alertes/email[0]: notify retry canceled due to
     unrecoverable error after 1 attempts: failed to send email:
     dial tcp: lookup smtp.resend.com on 127.0.0.11:53: server misbehaving"
```

Ce que ce relevé veut dire, dans l'ordre :

- la résolution DNS de Docker (127.0.0.11) peut répondre SERVFAIL une fois sur
  deux ; la même requête rejouée trente secondes plus tard rendait les adresses
  publiques et `nc -zv smtp.resend.com 587` passait. La panne est l'instant,
  pas la configuration.
- Grafana classe l'échec de connexion en « unrecoverable » et **n'essaie
  qu'une fois** : ni reprise au cycle suivant, ni dans les quatre heures du
  `repeat_interval`. L'alerte reste active chez Alertmanager et visible dans
  l'interface, mais le courriel, lui, n'existe plus.
- Donc l'absence de courriel ne prouve pas l'absence d'alerte. Pour savoir si
  une alerte a bien eu lieu, la lecture authoritative est l'API, pas la boîte
  de réception : `/api/prometheus/grafana/api/v1/rules` (état et santé de
  chaque évaluation) et `/api/annotations?limit=25&type=alert` (les transitions
  horodatées). Les journaux de `grafana` ne disent rien quand tout va bien, et
  disent ce qui ci-dessus quand le transport casse.

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

Rejoué le 2026-11-19 sur le même 13.3.0, cette fois sans redémarrer le
conteneur : `POST /api/admin/provisioning/alerting/reload` (200,
`Alerting config reloaded`) fait partir les cinq UID nommées dans les quatre
`deleteRules:` — `container-postfix-down`, `container-postfix-crash`,
`email-defere-age`, `email-defere-volume` et la sonde `sonde-accents-provisioning`
— et atterrir les cinq qui les remplacent (`container-stalwart-down`,
`container-stalwart-crash`, `email-double-bounce`, `email-temp-fail-volume`,
`email-dkim-signature`) : 39 règles avant, 39 après. `/api/v1/provisioning/alert-rules`
ne rend plus aucun UID contenant « postfix » ni « defere », et
`/api/prometheus/grafana/api/v1/rules` déclare les 39 en `health: ok`,
`state: inactive`. Le rechargement se joue donc à chaud ; un redéploiement
normal le fait aussi (le provisioning se relit au démarrage).

# Contrôles

```
# relecture des fichiers (le 500 et son message ne sortent que dans les journaux)
curl -s -X POST -u "$usager:$motdepasse" http://127.0.0.1:8088/api/admin/provisioning/alerting/reload
# ce qui est réellement provisionné
… /api/v1/provisioning/contact-points | … /api/v1/provisioning/policies | … /api/v1/provisioning/alert-rules
# états et santé de chaque évaluation : SEUL endroit où l'on voit Error/NoData
… /api/prometheus/grafana/api/v1/rules
# la déclaration provisionnée (expr, seuils, no_data_state) — sans AUCUN état
… /api/ruler/grafana/api/v1/rules
# ce que l'alertmanager retient comme en cours
… /api/alertmanager/grafana/api/v2/alerts
# les transitions d'état, dans l'ordre
… '/api/annotations?limit=25&type=alert'
```

Mesuré le 2026-11-17 sur grafana/grafana:13.3.0, parce que les deux URL se
ressemblent et ne rendent pas la même chose :

- `/api/ruler/grafana/api/v1/rules` répond 200 mais ne contient que la
  DÉCLARATION (`expr`, `for`, `labels`, `grafana_alert.condition`,
  `no_data_state`, `provenance`). Les clefs d'une règle sont
  `expr,for,keep_firing_for,labels,annotations,grafana_alert` : ni `state`, ni
  `health`, ni `currentValue`. On ne peut donc pas y lire si une règle sonne.
- La variante par dossier, `/api/ruler/grafana/api/v1/rules/Applications`,
  répond `403 {"message":"Access denied"}` avec les mêmes droits que la liste
  non filtrée — ce n'est pas un problème de rôle, ne pas perdre de temps à
  changer d'usager.
- `/api/prometheus/grafana/api/v1/rules` est celui qui rend `state`
  (`inactive`, `pending`, `firing`), `health`, `lastEvaluation`,
  `evaluationTime` et `alerts[]` par règle. C'est la lecture à câbler dans une
  sonde.
- Une règle provisionnée par fichier mais absente de ces deux dernières URL est
  une règle que Grafana n'évalue pas : le provisioning a pu accepter le
  fichier, l'évaluation est un autre étage.
- Rejouer l'EXPRESSION d'une règle par `POST /api/ds/query` (le chemin de
  `tools/logging/validate-dashboards.js`) reste nécessaire : un `inactive` ne
  dit pas si la requête rend une valeur sous le seuil ou AUCUNE série. Les deux
  concluent « rien à signaler », seul le second est faux. En Arrow, une frame
  porte `values[0]` = horodatages en millisecondes et `values[1]` = la mesure ;
  lire le premier fait afficher `1794934364879` au lieu de `599` (mesuré ici le
  2026-11-17 sur la règle d'âge de la file).

Côté courriel, sur le poste de développement comme sur le serveur : les alertes
partent par Resend (`smtp.resend.com:587`, `GF_SMTP_*` de `compose.yaml`) et non
par le relai de la machine — couper `stalwart` ne coupe donc pas les alertes. Le
relai, lui, se regarde dans son dépôt : `docker compose logs --tail=100 stalwart`
dans `/opt/yabiladi-mailer` doit montrer la remise (`delivery.delivered`) du
message parti de `webmaster@yabiladi.com` vers le destinataire du contact point.

Une notification n'arrive pas dans la seconde : `group_wait` attend
30 s (critique) ou 1 min (avertissement) après le passage en `Alerting`, et le
retard propre de la règle s'ajoute — les règles de battement prennent
15 min sans ligne plus 5 min de `for:` avant d'écrire quoi que ce soit.

# Les règles « file différée » de l'ère Postfix, et ce qui en survient

Jouées le 2026-11-17 avec 33 messages volontairement bloqués derrière un
`relayhost` inexistant, ces deux règles ont laissé trois leçons qui comptent
toujours, et une quantité qui a disparu avec le conteneur.

- La règle de volume (`email-defere-volume`, seuil 30 en 15 min) est passée
  `firing` de 16:39 à ~17:00, puis **s'est éteinte sur un bourbier intact** : le
  nombre de messages ne changeait pas, mais le nombre de LIGNES par quart
  d'heure fondait à mesure que le backoff s'étirait (`delay=` 599, 1199, 2399
  puis 5066 — écarts de 600, 1200 et 2667 s). Un compteur de lignes est un
  **détecteur de rafale**, pas un thermomètre.
- La règle d'âge (`email-defere-age`) ne pouvait pas être simulée : elle compare
  du temps vécu. Jouée à l'horloge réelle, franchissement mesuré — ligne
  `delay=5066` à 17:55:04, règle `firing` à 17:55:30Z — et sa fenêtre de 75 min
  venait de là : plus longue que le plus grand écart entre deux lignes d'un même
  message, pour qu'une file muette ne se déclare pas saine entre deux tentatives.
  **Le dosage « la fenêtre dépasse le plus grand intervalle » reste la règle d'or
  de toute alerte lue dans des journaux.**
- Vider la file ne l'a pas éteinte : le nettoyage de 17:56:20 (`postsuper -d ALL
  deferred`) a laissé les lignes `delay=5066` dans la fenêtre jusqu'à ~19:10Z.
  C'est le comportement voulu — une alerte qui s'efface au premier geste cache
  l'incident — mais il faut le savoir avant de conclure « le nettoyage n'a rien
  donné ».

Ce qui n'existe plus côté Stalwart (mesuré le 2026-11-19, et non pas supposé) :
aucune jauge de file (aucun nom Prometheus contenant `queue`, `out` ou
`message`), aucune profondeur lisible (`postqueue` n'existe pas), et aucun âge
cumulé : les lignes de la famille `queue.` portent des **échéances**
(`nextRetry`, `nextDsn`, `expires`), jamais un temps écoulé. La règle d'âge a
donc été **retirée** plutôt que réécrite sur du vent, et remplacée par
`email-double-bounce` (le message est perdu et son avis de retour aussi), tandis
que `email-temp-fail-volume` garde le rôle de détecteur de rafale sur
`delivery.dsn-temp-fail` / `delivery.connect-error`. Le troisième signal — la
profondeur brute — reste hors de portée : il faudrait lire la file du serveur
lui-même, et rien dans l'édition gratuite ne l'expose.

# Une ligne d'erreur de n'importe qui faisait sonner la règle de crash

`container-postfix-crash` cherchait `(fatal:|panic:|abnormal exit|core dumped)`
dans tout le flux `service="postfix"`, sans distinguer qui écrit. Mesuré le
2026-11-17 à 17:53:10Z : la règle est passée `active` sur une ligne écrite par
mon propre `postsuper -d <id> <id>` mal formé —
`postfix/postsuper[…]: postsuper: fatal: invalid directory name: 8C223AD06` —
tandis que le conteneur restait `healthy` et que le démon ne s'était jamais tu.
L'alerte s'éteint seule quand la ligne sort de la fenêtre de 10 min : `endsAt`
18:01:10Z mesuré pour un `startsAt` de 17:53:10Z, aucune intervention.

La leçon a été retenue à l'envers pour Stalwart : la nouvelle règle
`container-stalwart-crash` ne cherche AUCUN mot. Elle filtre sur
`detected_level=~"error|critical|fatal"`, le niveau que Loki dérive du jeton en
tête de ligne — parce que mesuré le 2026-11-19, une remise en échec normale
s'écrit en `INFO` avec « failed » dans son texte, et qu'un motif lexical aurait
donc sonné sur chaque rebond (les 21 lignes du relai contenant « error »
derivent toutes `info`). Ce qui reste non couvert : un panic écrit hors traceur
n'aurait pas de niveau ; il tue le processus, et `container-stalwart-down` le
dit dans les deux minutes.

## Une règle morte ne dit rien

La première version de cette même règle écrivait son filtre **dans le
sélecteur** : `{job="docker", service="stalwart", detected_level=~"error|critical"}`.
Jouée contre Loki le 2026-11-19, elle rend **0 série sur un poste qui contient
3 811 lignes du relai**. La cause n'est pas Stalwart : `docker/alloy/config.alloy`
termine sa chaîne par un `stage.label_keep` qui ne retient que `app`, `service`,
`container`, `job` et `host`. Un niveau détecté n'est donc jamais indexé — il
n'existe que ligne par ligne, et seule l'écriture en pipe fonctionne :

```
{job="docker", service="stalwart"} | detected_level=~"error|critical|fatal"
```

| écriture | rendu mesuré sur ce poste (3 j) |
| --- | --- |
| niveau dans les accolades du sélecteur | 0 série |
| `… } \| detected_level="info"` | 3 811 lignes |
| `… } \| detected_level=~"warn"` | 154 lignes |
| `… } \| detected_level=~"error\|critical\|fatal"` (la règle) | 0 — le relai n'a rien écrit de ce niveau |
| la même écriture sur `service="php"` / `service="nginx"` | 598 / 2 342 lignes |

La dernière ligne est la seule qui prouve la règle : « 0 série » veut dire ici
« rien à signaler », pas « le filtre est sourd », et c'est le même chiffre. Un
`noDataState: OK` ne fait pas la différence — il l'efface. Le contrôle est donc
à jouer **à chaque retouche d'une règle sur niveau** : relancer l'expression en
remplaçant l'alternance par un niveau qui a des lignes (`warn`, ou un autre
conteneur) et exiger un nombre.

Le même piège guette l'extraction : `| regexp "(?P<x>…)"` n'est **pas** un
filtre. Mesuré, `{service="stalwart"} | regexp "(?P<evenement>delivery.[a-z-]+)"`
rend 3 110 lignes alors que 62 seulement portent un événement `delivery.` ; le
reste tombe dans un groupe sans étiquette, qui pollue un `sum by` et peut
franchir un seuil tout seul. D'où le garde `| domain=~".+"` sur
`email-rebond-domaine` et le même garde dans les panneaux qui extraient.

## Le point d'un `regexp` est un joker

Toujours dans l'extraction, mais par un autre bout : en RE2, `.` ne vaut pas
« le point ». Écrit `queue.[a-z-]+`, le motif attrape aussi ce qui n'est pas un
événement — mesuré sur 3 jours de ce poste, le panneau « File du relai » rendait
`queueId` avec **62 lignes** (c'est le nom du champ `queueId = 341500334071355904`
présent sur presque toutes les lignes) et `queue started` (de la prose, pas un
nom). Écrit `queue[.][a-z-]+`, il rend trois vrais noms : `queue.dsn-queued` 10,
`queue.message-queued` 10, `queue.started` 15. Le crochet de protection
s'écrit `[.]` et non `\.` : LogQL refuse `\(`, et un seul caractère à changer
vaut mieux qu'une échappatoire à retenir.

Ce n'est pas qu'une histoire de tableaux de bord. Les filtres `|~` des règles
portent les mêmes points, et le `dkim.` de la règle de signature est passé de
`(dkim|dkim2).` à `dkim2?[.]` le 2026-11-20 — la forme courte en profite pour
nommer `signer-not-found`, que l'ancienne alternance oubliait : un objet `Dkim`
disparu du plan rend exactement cet événement, et la règle serait restée muette
devant le défaut qu'elle est là pour annoncer.

## Un état d'alerte lu dans l'API n'est pas une mesure

Contrôlé le 2026-11-20 au matin sur le poste de dev : `/api/prometheus/grafana/api/v1/rules`
annonçait 39 règles en bonne santé dont **15 en `firing`** — onze « conteneur
arrêté », dont `container-stalwart-down` sur un relai `Up (healthy)`. La valeur
courante de l'expression, jouée en direct sur Prometheus, rend `1` (le conteneur
est vu depuis 13 s), et `count by (service) (container_last_seen{job="docker"} > (time()-60))`
rend les 30 services, y compris les projets qui ne tournent pas ici. Les règles
ne sont pas en cause : le planificateur ngalert avait **4 h de retard**
(`lastEvaluation` à 02:07Z pour 08:51Z d'horloge) et recrachait son arrière
(`level=warn msg="Tick dropped because alert rule evaluation is too slow"`),
Windows ayant endormi Docker Desktop pendant la nuit. Le retard se résorbe tout
seul (02:07 → 04:49 en 40 s), mais pendant ce temps l'`state` raconte le passé.

Conséquence pour la vérification d'un lot d'alertes : `state` ne prouve rien sur
ce poste, `health` oui (une requête invalide passe la santé en `error`). Pour
prouver une règle, jouer son expression à la source (`/api/datasources/proxy/uid/…`
 côté Grafana, ou Prometheus/Loki directement) et vérifier le seuil à la main ;
pour prouver un lot provisionné, compter les UID et la santé, comme ci-dessus.

# Ce répertoire n'est pas le seul endroit où l'alerting vit

L'état courant des règles, leur historique et les silenceurs ne se mettent
JAMAIS par fichier : un fichier provisionné écrase l'interface à chaque
rechargement. Toute règle créée à la main dans l'UI d'un autre dossier survit,
mais hérite de la politique racine de `notification_policies.yaml` — relire ce
que cela veut dire avant d'ajouter une deuxième pile d'alertes ici.

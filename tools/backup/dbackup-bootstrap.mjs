#!/usr/bin/env node
/**
 * Amorçage de la console de sauvegarde DBackup : compte administrateur,
 * adaptateurs de stockage, connexion à la base de production et un job de
 * fichiers par dossier sauvegardé, plus le job de la base. Idempotent — relancé,
 * il ne change rien à ce qui existe déjà.
 *
 *   docker compose exec -T dbackup node /opt/backup-tools/dbackup-bootstrap.mjs
 *
 * Il est appelé par deploy.sh après « up -d » ; c'est ce qui permet à un
 * « git pull && ./deploy.sh » de donner une console déjà réglée, sans passer par
 * l'interface. Tout ce dont il a besoin vient de l'environnement du conteneur
 * (docker/legacy/dbackup.env pour le compte, .env / .env.local pour la base) :
 * aucune valeur n'est écrite ici, et aucune n'est jamais affichée.
 *
 * Trois comportements de DBackup 4.0.2 sont mesurés plutôt que devinés, et
 * l'outil les reproduit dans l'ordre :
 *
 *  1. Le tout premier compte se crée par « POST /api/auth/sign-up/email », et il
 *     n'hérite d'aucun groupe : toutes les routes /api* répondent alors 401 avec
 *     un cookie pourtant valide. C'est la lecture de « /dashboard » — un rendu
 *     serveur — qui promeut l'unique utilisateur SuperAdmin (« Auto-promoting
 *     first user to SuperAdmin »). Sans cette visite, l'amorçage se croirait
 *     rejeté par l'authentification.
 *
 *  2. Les routes d'écriture acceptent le nommage exact de l'interface, mais
 *     aucune ne fait d'"upsert" : créer deux fois le même adaptateur donne deux
 *     adaptateurs. D'où la recherche par nom avant chaque création. Pour les
 *     jobs, le « PUT /api/jobs/{id} » existe (mesuré : 200) mais écrase la
 *     planification et l'activation : le périmètre des jobs de fichiers est donc
 *     resynchronisé, schedule et activation relus tels qu'ils sont en base, et le
 *     job de base — que l'utilisateur active lui-même — n'est jamais touché. Un
 *     PUT qui n'envoie que six champs laisse les autres intacts (mesuré :
 *     compression, notificationEvents, fullEveryDays et verifyByHash survivent à
 *     un PUT partiel) — c'est ce qui rend le chiffrement décidé dans l'interface
 *     insensible aux redéploiements.
 *
 *  3. « POST /api/jobs » n'applique AUCUN des réglages que l'interface pose par
 *     défaut : un job créé par l'API part en FULL, sans compression, notifié
 *     « ALWAYS » (mesuré), là où le job en place sur les machines était
 *     INCREMENTAL/GZIP. Les valeurs sont donc déclarées, voir « JOB_DEFAULTS ».
 *
 * Les limites de débit sont réelles (mesuré : authentification 5 requêtes par
 * minute) : une seule tentative de connexion, puis une de création, et le 429
 * est relu après attente.
 *
 * Restaurer suppose un adaptateur inscriptible, et le picker de l'interface ne
 * propose que les rôles SOURCE : les sources de sauvegarde, montées en lecture
 * seule, y figurent et sont même présélectionnées. L'outil déclare donc un
 * second adaptateur SOURCE sur /restore, le dossier de travail (voir
 * « NAMES.restore »).
 *
 * Le périmètre — la liste des jobs — ne vit plus ici : il est dans
 * « tools/backup/jobs.json », un fichier de données versionné, une ligne par
 * job. Deux raisons à ce déménagement, toutes deux mesurées sur 4.0.2 :
 *
 *  - ce que l'interface change sur un job (son horaire, son activation) ne
 *    peut pas revenir dans git tant que la déclaration est une ligne de
 *    JavaScript : personne ne veut d'un robot qui réécrit du code source à
 *    chaque retouche d'horaire. Le fichier de données, lui, se relit
 *    exactement comme il a été écrit ;
 *  - « --export » régénère « jobs.json » depuis l'instance en place (lecture
 *    seule, aucune écriture dans la console), et le DAG « synchro_ihm_git »
 *    commite le résultat : un horaire déplacé à la souris dans « Jobs » devient
 *    un commit, et une machine neuve repart de ce commit.
 *
 * Usage :
 *   docker compose exec -T dbackup node /opt/backup-tools/dbackup-bootstrap.mjs
 *   docker compose exec -T dbackup node /opt/backup-tools/dbackup-bootstrap.mjs --export \
 *       --out /opt/backup-tools/jobs.json      # même commande, mode export
 *   node tools/backup/dbackup-bootstrap.mjs --export --out tools/backup/jobs.json
 *       # depuis n'importe où, avec DBACKUP_URL + les deux variables du compte
 */

import { readFileSync, writeFileSync } from "node:fs";

// L'API de la console. En interne (le conteneur lui-même) le défaut suffit ;
// l'export piloté depuis un autre conteneur passe par « DBACKUP_URL ».
const BASE = (process.env.DBACKUP_URL || `http://127.0.0.1:${process.env.PORT || 3000}`).replace(/\/+$/, "");
const ADMIN_EMAIL = process.env.DBACKUP_ADMIN_EMAIL;
const ADMIN_PASSWORD = process.env.DBACKUP_ADMIN_PASSWORD;

// better-auth refuse toute tentative de connexion dont l'origine n'est pas la
// sienne (mesuré sur 4.0.2, en interne comme par curl : « MISSING_OR_NULL_ORIGIN »
// sans l'en-tête, « INVALID_ORIGIN » avec une origine qui n'est pas celle
// déclarée). L'appel part donc du conteneur lui-même et se déclare avec
// BETTER_AUTH_URL — la seule origine que l'instance reconnaît, et la valeur
// exacte que compose.yaml pose pour le nom public.
const AUTH_ORIGIN = process.env.BETTER_AUTH_URL || BASE;

// Les trois racines vues depuis le conteneur, telles que les monte compose.yaml.
const SOURCE_BASE = "/backup";
const DEST_BASE = "/backups";
const RESTORE_BASE = "/restore";

const NAMES = {
  source: "Données de l'application (lecture seule)",
  destination: "Archives sur le NFS de sauvegarde",
  // Cible des restaurations. Le picker « Restore target » de l'interface ne
  // liste que les adaptateurs de rôle SOURCE (mesuré : il appelle
  // « GET /api/adapters?type=storage&role=SOURCE »), et il présélectionne
  // l'origine de l'archive — donc l'adaptateur de sauvegarde, en lecture seule.
  // C'est ce qui rendait la restauration impossible : mesuré le 2026-11-02,
  // « Restore target 'Données de l'application (lecture seule)' is not writable:
  // Access failed: EACCES: permission denied, mkdir '/backup/.dbackup' ». Ce
  // second adaptateur SOURCE désigne le seul dossier inscriptible ; il sert
  // d'atelier, pas de destination finale.
  restore: "Restauration (dossier de travail)",
  // Le job agrégé que la console avait en place depuis l'origine, remplacé le
  // 2026-11-02 par un job par dossier. Sert uniquement à le signaler : voir
  // « signalerEtatDesJobs ».
  legacyFilesJob: "Données de l'application et volumes Docker",
};

// Un job par dossier sauvegardé : une ligne dans « Jobs », une exécution, un
// statut et un dossier d'archives par dossier. Ce que rapporte le job agrégé
// (« Partial ») ne disait pas lequel ; ici le nom du job est le dossier en échec.
// Les dossiers sauvegardés sont ceux que compose.yaml monte en lecture seule
// sous /backup (chacun y est commenté) : un montage sans job ici est un trou de
// sauvegarde, pas un choix. Quatre absences sont délibérées. Celles de la console
// précédente : le volume « dagu_data » — Dagu y écrit en www-data des
// répertoires 0750 et un « data/auth/encryption_key » en 0600, ni lisibles par
// l'uid 1001 de la console, ni souhaitables dans une archive non chiffrée, alors
// que les DAGs sont versionnés et l'historique d'exécution aussi dans Loki — et
// « db-dumps », le dossier où le DAG « db_dump » écrivait ses dumps SQL, supprimé
// le 2026-11-01 : la base physique se sauvegarde depuis par le DAG
// « mariadb_fetch » (mariabackup sur le serveur) et le job
// « Fichiers - mariadb-physical » qui archive le résultat sur le dépôt. Et deux
// retirées le 2026-11-09, mesurées avant de l'être : « scripts » (748 fichiers
// suivis dans git, dont les CSV du scraping — ce qui dépasse le dépôt n'est que
// ses 38 « .log », ses caches que les DAGs réécrivent et ses vendor/), et
// « prayer-pdfs » (420 PDF que le DAG « prayer_pdfs » refait chaque nuit à
// 00:10). L'un et l'autre se relèvent hors sauvegarde.
//
// Le nom est une valeur stable, pas une étiquette : mesuré sur 4.0.2, le dossier
// de destination porte le nom du job — puis, en mode incrémental, un
// sous-dossier « chain-<horodatage> » avec un « _full-000.tar » et des
// « _inc-00N.tar » — et supprimer le job laisse ses archives sur le disque sans
// plus personne pour les purger, la rétention étant attachée au job. Renommer un
// job orpheline donc ses archives aussi sûrement que le supprimer.
//
// « schedule » : quatre minutes d'écart, du plus lourd au plus léger, de 04:00
// à 04:32. Les deux créneaux laissés libres le 2026-11-09 par le retrait des
// jobs « scripts » et « prayer-pdfs » ont été reboutés, et l'instance en place a
// été réalignée dans la foulée — l'amorçage, lui, ne touche jamais une
// planification déjà créée (elle appartient à l'interface). Le créneau de 04:04,
// laissé libre le 2026-11-09 quand « var/log » est sorti du périmètre (les
// journaux Symfony ne sont pas une donnée à restaurer), est repris le 2026-11-12
// par « Fichiers - grafana ». La ligne « Fichiers - logs » sort de ce fait de la
// déclaration : elle n'avait plus de montage depuis ce retrait. Mais l'amorçage
// ne supprime jamais un job (voir « signalerEtatDesJobs ») — sur une machine déjà
// amorcée, « Fichiers - logs » reste donc une ligne à effacer à la main dans
// « Jobs », puis son dossier d'archives à enlever sur le dépôt. Vérifié ici le
// 2026-11-12 avant le geste : le manifeste de l'archive du 2026-11-10 porte
// « files: 0 » et « logicalSize: 0 » — rien à quoi une restauration pourrait
// revenir. Sur une instance déjà amorcée, ces minutes restent celles de
// l'interface : le décalage se décide dans « Jobs », job par job. Un écartement
// ne sérialise rien — « media » court encore quand le suivant démarre —, il
// baisse seulement le pic de lectures simultanées sur le NFS de destination. Le
// « créneau du dump SQL » invoqué ici jusqu'au 2026-11-09 n'existe plus : la
// base part à 02:00 par le DAG « mariadb_fetch », avant toute la série, et son
// archivage la ferme. Mesuré sur le poste de développement, donc sans valeur de
// débit : la cible a 16 cœurs et lit la MariaDB à distance, les durées réelles
// se liront sur le serveur.
// Le périmètre lui-même est dans « tools/backup/jobs.json » : une ligne par
// job, les mêmes quatre champs (name, path, label, schedule) et « enabled »
// seulement quand il vaut false. Ce fichier est la déclaration, pas un
// enregistrement : « --export » le régénère depuis l'instance en place, et le
// DAG de synchro le commite. Les commentaires d'à côté restent valables
// puisqu'ils décrivent ces lignes.
const FILE_JOBS = JSON.parse(readFileSync(new URL("./jobs.json", import.meta.url), "utf8"));

// Quatre notes attachées à des lignes précises de « jobs.json », gardées ici
// parce qu'un JSON ne commente pas :
//   - « traefik-acme » : le montage du volume est « docker/traefik-acme », mais
//     le nom du job ne prend pas de barre oblique — ce serait un sous-dossier
//     sur le dépôt, donc une seconde arborescence d'archives ;
//   - les quatre jobs marqués « enabled: false » (mediakit-img,
//     facturation-uploads, facturation-bc, mariadb-physical) naissent éteints :
//     les trois applications voisines ne sont pas encore servies et la MariaDB
//     n'a pas encore son mariabackup. Le job existe pour que la bascule ne soit
//     qu'un bouton — le jour J, on l'active depuis « Jobs » après y avoir
//     associé un profil de chiffrement (l'API ne sait pas créer la clé).
//     L'amorçage, lui, ne rallume jamais un job existant : c'est pour cela que
//     l'état de départ est déclaré ici plutôt qu'obtenu par une action manuelle,
//     et depuis l'export c'est l'interface qui tient le drapeau ;
//   - « facturation-uploads » et « facturation-bc » sont deux jobs et non un :
//     « public/uploads » couvre les documents de projets et les images des
//     incidents, « var/bc_files » porte les bons de commande téléversés. Deux
//     archives, deux lignes de statut : un bon de commande manquant ne doit pas
//     se lire comme une pièce jointe manquante. Le second suit le défaut de
//     BC_PATH (%kernel.project_dir%/var/bc_files) ; un chemin absolu sur le
//     serveur demanderait son propre montage ;
//   - « radio-content » est activé d'emblée, contrairement aux quatre jobs en
//     attente d'à côté : 9 Go mesurés sur le poste de développement, et c'est
//     du contenu qui ne se régénère pas — ni dans git, ni dans les bases. GZIP
//     sur des MP3 ne gagne presque rien, mais c'est le défaut de la maison et le
//     job « media » le partage ; un réglage job par job se décide dans l'interface.

// Les réglages que l'interface applique d'elle-même et que « POST /api/jobs »
// ignore (mesuré : un job créé par l'API sans ces champs sort en FULL,
// compression NONE, notification ALWAYS, alors que le job en place était
// INCREMENTAL/GZIP). Déclarés pour que deux machines parties du même dépôt
// donnent le même job.
//
// « INCREMENTAL » n'est pas un confort : la rétention garde jusqu'à 25 archives
// par job, et un « Fichiers - media » complet chaque nuit multiplierait d'autant
// le poids sur le dépôt. « notificationEvents » est la valeur du job agrégé,
// reproduite telle quelle — mais elle se multiplie depuis le découpage par le
// nombre de « Fichiers - … » : si un canal de notification est un jour branché,
// c'est un courriel par job et par nuit, et c'est là qu'il faudra trancher, pas
// ici.
const JOB_DEFAULTS = {
  backupMode: "INCREMENTAL",
  fullEveryDays: 7,
  compression: "GZIP",
  verifyByHash: false,
  skipVerification: false,
  notificationEvents: "SUCCESS|PARTIAL|FAILED",
};

// Ce que la sauvegarde écarte partout : du volumineux et rejouable, jamais une
// donnée. Liste reprise de la console précédente (restic lisait un fichier de
// motifs ; DBackup prend une liste par source, et c'est ici qu'elle vit).
//
// La forme compte, mesuré sur 4.0.2 : « **/dagu-data/** » écarte le contenu du
// dossier, alors que « **/dagu-data » seul ne l'écarte pas — DBackup compare des
// chemins de fichiers, pas des répertoires. D'où la suffixation « /** » de tout
// ce qui désigne un arbre.
const EXCLUDES = [
  // Dépendances et binaires : scripts/map_puppeeter pèse 634 Mo dont un Chromium
  // de 558 Mo, tout se re-télécharge. Le dossier « scripts » est sorti du
  // périmètre le 2026-11-09, ces motifs restent comme garde globale.
  "**/node_modules/**",
  "**/vendor/**",
  "**/chromium/**",
  // Extensions Grafana installées depuis l'interface : du code, pas une donnée.
  // 573,8 Mo mesurés le 2026-11-12 sur les 579,7 Mo du dossier sauvegardé — le
  // « grafana.db » de 5,2 Mo est tout ce que l'archive doit rapporter. Le motif
  // est global, et il ne peut mordre aujourd'hui que sur celui-là : les huit
  // arbres déjà montés sous « /backup » (médias, images de l'éditeur, traefik,
  // acme, mediakit, facturation, mariabackup, discothèque radio) ont été fouillés
  // le même jour, aucun ne contient de dossier « plugins ».
  "**/plugins/**",
  // Index de recherche unifiée que Grafana construit lui-même (bleve) : 4 fichiers
  // mesurés le 2026-11-13, tous en « 472:472 » mode « 0600 ». Le PGID 33 du
  // conteneur n'y change rien — le mode refuse la lecture au groupe comme aux
  // autres uid — et Grafana recrée l'arbre à chaque démarrage : rien à archiver.
  // Sans ce motif, le job rendait « Partial » chaque nuit sur ces 4 fichiers.
  "**/unified-search/**",
  // Journaux legacy gonflés par des cron V1 toujours actifs. Pas de « *.log » en
  // bloc : ces six motifs sont nommés un par un, et une règle globale écarterait
  // sans le dire n'importe quel journal tombé dans un dossier média. (« var/log »
  // du site est sorti du périmètre le 2026-11-09 — il n'est plus monté sous
  // /backup, donc rien ici n'a plus à protéger des journaux Symfony.)
  "**/pages_cache.log",
  "**/generate.log",
  "**/radio_footer.log",
  "**/payer_times.log",
  "**/videos_footer.log",
  "**/script.log",
  // Artefacts d'édition ou de validation, sans valeur de restauration.
  "**/*.swo",
  "**/*.swp",
  "**/.phpunit.cache/**",
  "**/.php-cs-fixer.cache/**",
  // Export figé importé du V1, déjà disponible dans ../Yabiladi-V1-Cakephp.
  "**/cake.txt",
  // Comptes basicauth Traefik : 0600 root:root hors de portée de l'utilisateur
  // 1001 de la console, et surtout leur source de vérité est le coffre
  // (deploy/secrets/htpasswd_*.sops.bin), qui les redéploie. Les recopier dans
  // une archive non chiffrée serait un second endroit où les hashes vivent.
  "**/htpasswd/**",
];

// Rétention « Smart GFS (7/4/12/2) » : 7 jours, 4 semaines, 12 mois, 2 années.
// Identifiant livré par l'image, vérifié via GET /api/templates ; l'interface
// permet de le changer job par job.
const RETENTION = "retention-gvs-default";

let cookie = "";
// Les deux modes du programme : l'amorçage (écrit dans la console) et l'export
// (lit la console, écrit un fichier). L'export ne doit rien laisser derrière
// lui dans la console, pas même le compte administrateur s'il manque — ses
// journaux partent donc sur stderr et son flux JSON reste seul sur stdout.
const ARGS = process.argv.slice(2);
const MODE_EXPORT = ARGS.includes("--export");
const outIndex = ARGS.indexOf("--out");
const OUT_FILE = outIndex >= 0 ? ARGS[outIndex + 1] : null;

// Un seul flux pour les journaux : stderr en mode export, pour que le JSON
// écrit sur stdout reste le seul contenu du tuyau.
const log = (m) => (MODE_EXPORT ? process.stderr : process.stdout).write(`${m}\n`);
const die = (m) => {
  process.stderr.write(`ERREUR: ${m}\n`);
  process.exit(1);
};

async function call(method, path, body, { auth = true, origin = false } = {}) {
  const headers = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (origin) headers.origin = AUTH_ORIGIN;
  if (auth && cookie) headers.cookie = cookie;
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  // « Headers.getSetCookie() » n'existe pas partout : mesuré le 2026-11-11, le
  // Node 18.20.4 de l'image dagu ne l'a pas, alors que le Node du poste et celui
  // du conteneur dbackup l'ont. Sans repli, la timbre reste VIDE, aucune requête
  // suivante ne porte le cookie de session, et l'API répond 401 après une
  // ouverture de session pourtant passée à 200 — le symptôme est exactement
  // celui de la synchro lancée depuis Dagu. Le repli découpe l'en-tête unique
  // « set-cookie » sur les virgules qui précèdent un « nom= », pour ne pas
  // couper une date « Expires=Wed, 09 Jun… » en deux.
  const setCookies = typeof res.headers.getSetCookie === "function"
    ? res.headers.getSetCookie()
    : (res.headers.get("set-cookie") ?? "").split(/,(?=\s*[A-Za-z0-9_.-]+=)/).map((c) => c.trim()).filter((c) => c.length);
  for (const c of setCookies) {
    const pair = c.split(";")[0].trim();
    cookie = cookie ? `${cookie}; ${pair}` : pair;
  }
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* les pages rendues (dashboard, liste HTML) ne sont pas du JSON */
  }
  return { status: res.status, json, text };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Le conteneur peut être démarré depuis trente secondes ou depuis trente secondes
// seulement : au premier déploiement, l'image applique ses migrations Prisma avant
// d'écouter, et « fetch failed » est alors la réponse normale. Attendre sans
// s'émouvoir fait partie du contrat de « git pull && ./deploy.sh ».
async function waitForApi(maxSeconds = 180) {
  for (let waited = 0; waited < maxSeconds; waited += 3) {
    try {
      const r = await call("GET", "/api/health", undefined, { auth: false });
      if (r.status === 200 && r.json?.status === "healthy" && r.json?.database === "connected") return;
    } catch {
      /* pas encore d'écouteur sur le port : ce n'est pas une erreur */
    }
    await sleep(3000);
  }
  die("la console ne répond pas sur /api/health — vérifier « docker compose logs dbackup »");
}

// Le compte, puis l'élévation SuperAdmin que seule la lecture de /dashboard fait.
async function signIn() {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await call("POST", "/api/auth/sign-in/email", { email: ADMIN_EMAIL, password: ADMIN_PASSWORD }, { auth: false, origin: true });
    if (r.status === 200) return "existant";
    if (r.status === 429) {
      log(`   (limite de débit de l'authentification, nouvelle tentative dans 60 s)`);
      await sleep(60000);
      continue;
    }
    if (r.json?.code === "INVALID_ORIGIN") {
      die(`origine refusée : BETTER_AUTH_URL (${AUTH_ORIGIN}) n'est pas celle que la console reconnaît`);
    }
    break; // compte inconnu, ou mot de passe différent de celui du coffre
  }

  if (MODE_EXPORT) {
    die("export interrompu : le compte du coffre n'ouvre pas la console. L'export ne crée aucun compte — lancer d'abord l'amorçage.");
  }

  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await call("POST", "/api/auth/sign-up/email", { name: "admin", email: ADMIN_EMAIL, password: ADMIN_PASSWORD }, { auth: false, origin: true });
    if (r.status === 200 || r.status === 201) {
      // Promotion SuperAdmin : voir l'en-tête du fichier, elle n'a pas d'équivalent
      // en API. Le cookie de session est déjà dans la timbre.
      await call("GET", "/dashboard", undefined);
      return "créé";
    }
    if (r.status === 429) {
      log(`   (limite de débit de l'authentification, nouvelle tentative dans 60 s)`);
      await sleep(60000);
      continue;
    }
    if (r.json?.code === "SIGN_UP_CLOSED") {
      die(`un compte administrateur existe déjà mais le mot de passe du coffre ne l'ouvre pas : « ${ADMIN_EMAIL} » n'est pas le compte en place, ou son mot de passe a été changé dans l'interface`);
    }
    die(`création du compte administrateur impossible (${r.status}) : ${r.text.slice(0, 200)}`);
  }
  die("authentification impossible : limite de débit de l'API atteinte");
}

async function assertApiWorks() {
  const r = await call("GET", "/api/adapters?type=storage");
  if (r.status === 200) return;
  // Le compte a été créé mais n'a pas de groupe : la promotion passe par le
  // rendu de /dashboard, pas par une route d'API (mesuré sur 4.0.2).
  await call("GET", "/dashboard", undefined);
  const again = await call("GET", "/api/adapters?type=storage");
  if (again.status !== 200) die(`API refusée (${again.status}) après promotion — état inconnu, à vérifier dans l'interface`);
}

async function listAdapters(type) {
  const r = await call("GET", `/api/adapters?type=${type}`);
  if (r.status !== 200) die(`lecture des adaptateurs ${type} (${r.status}) : ${r.text.slice(0, 200)}`);
  return Array.isArray(r.json) ? r.json : [];
}

async function ensureStorageAdapter(name, role, config) {
  const found = (await listAdapters("storage")).find((a) => a.name === name && a.storageRole === role);
  if (found) {
    // « déjà en place » ne dit pas « à la bonne racine ». Mesuré le 2026-11-12 :
    // l'adaptateur SOURCE « Données de l'application (lecture seule) » portait
    // « basePath: /backups » — la racine des ARCHIVES, créée ainsi le 2026-11-01 —
    // et le job lisait donc « /backups/media », « /backups/traefik-config »… donc
    // rien. Chacune des dix archives produites sur le poste depuis ce jour porte
    // « files: 0 », « logicalSize: 0 » et un statut « Success » : la console ne
    // signale pas une source vide, elle la déclare archivée. D'où le contrôle, et
    // sa réparation.
    //
    // Le PUT est partiel (mesuré ici : il rend 200 et conserve le nom, le rôle et
    // les métadonnées) — il ne touche donc pas ce que l'interface seule sait poser.
    const courant = basePathAdaptateur(found.config);
    if (courant !== config.basePath) {
      const corrige = await call("PUT", `/api/adapters/${found.id}`, { config });
      if (corrige.status !== 200) {
        die(`adaptateur « ${name} » : basePath « ${courant} » ≠ « ${config.basePath} » et le PUT a été refusé (${corrige.status}) — sans correction, chaque job archive un chemin qui n'existe pas et se dit « réussi »`);
      }
      log(`  · adaptateur ${role.toLowerCase()} « ${name} » : basePath corrigé « ${courant} » → « ${config.basePath} » (les jobs lisaient la racine des archives, pas les données)`);
    } else {
      log(`  · adaptateur ${role.toLowerCase()} « ${name} » : déjà en place (${config.basePath})`);
    }
    return found.id;
  }
  const r = await call("POST", "/api/adapters", { name, type: "storage", adapterId: "local-filesystem", config, storageRole: role });
  if (r.status !== 201) die(`création de l'adaptateur « ${name} » (${r.status}) : ${r.text.slice(0, 200)}`);
  log(`  · adaptateur ${role.toLowerCase()} « ${name} » : créé (${config.basePath})`);
  return r.json.id;
}

// « GET /api/adapters » rend le config en chaîne JSON, « POST » en objet : les
// deux formes se lisent ici, sinon la comparaison ci-dessus échouerait pour la
// moitié des instances et corrigerait en boucle un basePath déjà juste.
function basePathAdaptateur(config) {
  if (!config) return null;
  if (typeof config === "object") return config.basePath ?? null;
  try { return JSON.parse(config).basePath ?? null; } catch { return null; }
}

async function listJobs() {
  const r = await call("GET", "/api/jobs");
  if (r.status !== 200) die(`lecture des jobs (${r.status}) : ${r.text.slice(0, 200)}`);
  return Array.isArray(r.json) ? r.json : [];
}

async function createJob(payload, enabledNote, { resyncSources = false } = {}) {
  const existing = (await listJobs()).find((j) => j.name === payload.name);
  if (existing) {
    const signe = resyncSources ? await syncFileSources(existing, payload.sources) : false;
    log(`  · job « ${payload.name} » : ${signe ? "périmètre mis à jour" : "déjà en place"} (${existing.enabled ? "activé" : "désactivé"}, ${existing.schedule ?? existing.cronExpression})`);
    return existing.id;
  }
  const r = await call("POST", "/api/jobs", payload);
  if (r.status !== 201) die(`création du job « ${payload.name} » (${r.status}) : ${r.text.slice(0, 200)}`);
  log(`  · job « ${payload.name} » : créé (${payload.schedule}, ${enabledNote})`);
  return r.json.id;
}

// Le périmètre se déclare ici, donc un « git pull » qui ajoute ou retire un
// dossier le propage au job de ce dossier. La planification et l'activation,
// elles, appartiennent à l'interface : l'utilisateur a pu décaler l'heure ou
// laisser un job éteint. Le PUT renvoie donc le schedule et l'enabled tels qu'ils
// sont en base et ne remplace que « sources ». Mesuré sur 4.0.2 : PUT répond 200,
// conserve les deux, et ne réinitialise aucun des champs qu'on ne lui envoie pas
// — d'où le « description » qu'on ne met pas dans le corps : la liste des jobs ne
// le rend pas, on ne peut donc pas le relire, et l'écrire à vide écraserait ce
// que quelqu'un aurait tapé. C'est aussi ce qui protège le profil de chiffrement,
// que seule l'interface sait poser.
async function syncFileSources(existing, sources) {
  const marque = (l) => l.map((s) => `${s.path}|${s.stopContainers}|${(s.excludePatterns ?? []).join(",")}`).sort().join("\n");
  if (marque(existing.sources ?? []) === marque(sources)) return false;
  const r = await call("PUT", `/api/jobs/${existing.id}`, {
    name: existing.name,
    schedule: existing.schedule ?? existing.cronExpression,
    enabled: existing.enabled,
    destinations: (existing.destinations ?? []).map((d) => ({ configId: d.configId, priority: d.priority, retentionPolicyId: d.retentionPolicyId })),
    sources,
  });
  if (r.status !== 200) die(`mise à jour du périmètre du job « ${existing.name} » (${r.status}) : ${r.text.slice(0, 200)}`);
  return true;
}

function requireEnv(...keys) {
  const missing = keys.filter((k) => !process.env[k]);
  if (missing.length) die(`variable(s) d'environnement absente(s) : ${missing.join(", ")} — le coffre n'a pas été matérialisé (${missing.length} clé(s) attendues dans docker/legacy/dbackup.env)`);
}

// Ce que la console tait et qu'il faut dire à chaque déploiement. Une ligne par
// situation, pas une ligne par job : des jobs éteints doivent se lire comme un
// seul problème, pas comme un par job.
async function signalerEtatDesJobs() {
  const jobs = await listJobs();
  const declares = FILE_JOBS.map((definition) => jobs.find((j) => j.name === definition.name)).filter(Boolean);

  // Un job déclaré « enabled: false » par ce fichier n'est pas un arrêt subi :
  // il attend la bascule (mediakit). Le ranger avec les désactivés ferait crier
  // l'amorçage chaque nuit pour une situation voulue, et ce bruit finirait par
  // couvrir un vrai job éteint par accident.
  const attente = new Set(FILE_JOBS.filter((d) => d.enabled === false).map((d) => d.name));
  const enAttente = declares.filter((j) => attente.has(j.name) && j.enabled === false);
  const nomsEnAttente = new Set(enAttente.map((j) => j.name));
  // Un job déclaré « en pause » repasse par les contrôles ordinaires dès qu'il
  // est activé (le jour J) : c'est là que l'absence de profil de chiffrement
  // doit se voir, comme pour les autres.
  const horsAttente = declares.filter((j) => !nomsEnAttente.has(j.name));

  const eteints = horsAttente.filter((j) => j.enabled === false);
  if (eteints.length) {
    // Création activée, puis l'interface seule décide. Éteint, un job ne produit
    // plus rien et la console reste muette là-dessus : mesuré le 2026-11-01 sur ce
    // poste, « enabled=false » alors que le README annonce un départ à 04:00.
    // L'amorçage ne rallume pas — un bouton laissé par la main de quelqu'un n'est
    // pas une valeur à écraser à chaque déploiement.
    log(`  · ATTENTION : ${eteints.length} job(s) de fichiers désactivé(s) — aucune archive pour : ${eteints.map((j) => j.name).join(", ")}.`);
    log("     Les rallumer : ouvrir le job depuis « Jobs » et l'activer.");
  }

  if (enAttente.length) {
    // Volontairement en pause : rien n'est encore produit, donc pas d'alerte de
    // « job éteint ». La consigne reste utile, car c'est le seul geste que la
    // bascule demandera à la main — l'amorçage ne peut pas poser de clé (voir
    // ci-dessous) et n'active jamais un job existant.
    log(`  · en attente de bascule : ${enAttente.map((j) => j.name).join(", ")} — désactivé(s) par tools/backup/dbackup-bootstrap.mjs, aucune archive produite tant que les applications ne sont pas servies.`);
    log("     Le jour J : Job → l'activer, après y avoir associé un profil de chiffrement (l'API ne permet pas de créer la clé).");
  }

  const sansClef = horsAttente.filter((j) => !j.encryptionProfileId);
  if (sansClef.length) {
    // Mesuré : « POST /api/vault/keys » répond 405 — une clé ne se crée que depuis
    // l'interface. L'amorçage ne peut donc pas l'imposer, et le silence serait un
    // mauvais service : les archives contiennent acme.json, les clés TLS de
    // docker/traefik/certs et les « .env » des scripts legacy, en clair.
    log(`  · ATTENTION : ${sansClef.length} job(s) de fichiers sur ${horsAttente.length} sans profil de chiffrement — les archives TAR sont en clair sur le dépôt.`);
    log(`     Concerne : ${sansClef.map((j) => j.name).join(", ")}.`);
    log("     Une fois par machine : Job → Encryption, créer la clé puis l'associer à chaque job (l'API ne le permet pas).");
    log("     Un PUT partiel ne l'écrase pas (mesuré) : ce choix survit aux déploiements suivants.");
  } else if (horsAttente.length) {
    log(`  · chiffrement : les ${horsAttente.length} jobs de fichiers actifs ont un profil.`);
  }

  // Le découpage du 2026-11-02 laisse derrière lui le job agrégé. L'amorçage ne le
  // supprime pas : « DELETE /api/jobs/{id} » répond 200 et laisse ses archives sur
  // le dépôt sans plus aucun job pour les purger (mesuré le 2026-11-02 — le dossier
  // survit à la suppression, et les exécutions restent avec « jobId: null »). La
  // suppression relève donc de la main, une fois les nouveaux jobs vus produire.
  const herite = jobs.find((j) => j.name === NAMES.legacyFilesJob);
  if (herite) {
    log(`  · ATTENTION : le job agrégé « ${NAMES.legacyFilesJob} » est encore là (${herite.enabled ? "activé — il archive une seconde fois chaque nuit" : "désactivé"}) ; un job par dossier le remplace.`);
    log("     Quand les « Fichiers - … » auront produit leur première archive : le supprimer depuis « Jobs »,");
    log(`     puis enlever sur le dépôt le dossier que plus aucune rétention ne purge (chemin vu du conteneur) :`);
    log(`       rm -rf "${DEST_BASE}/${NAMES.legacyFilesJob}"`);
  }

  // Un job de fichiers que ce fichier ne déclare pas : soit une expérience faite
  // dans l'interface, soit un reliquat. Ni supprimé ni corrigé — seulement compté,
  // pour qu'aucune archive ne parte d'un job dont personne ne sait qui l'a créé.
  const connus = new Set([...FILE_JOBS.map((j) => j.name), NAMES.legacyFilesJob]);
  const horsPerimetre = jobs.filter((j) => !connus.has(j.name) && (j.sources ?? []).length > 0);
  if (horsPerimetre.length) {
    log(`  · ${horsPerimetre.length} job(s) de fichiers hors périmètre de l'amorçage : ${horsPerimetre.map((j) => `${j.name} (${j.enabled ? "activé" : "désactivé"}, ${j.sources.length} source(s))`).join(", ")}`);
    log("     Non déclarés dans tools/backup/dbackup-bootstrap.mjs — l'amorçage ne les touche pas.");
  }
}

// --- mode export -----------------------------------------------------------
// « --export » régénère « jobs.json » depuis l'instance en place, sans rien
// écrire dans la console. Une ligne par job, dans l'ordre du fichier quand le
// job y figure déjà : un horaire déplacé à la souris doit produire un diff
// d'une ligne, pas un réordonnancement des neuf.
//
// Trois champs reviennent de l'interface, ce sont les trois que « Jobs » sait
// modifier sans reprendre le job entier : « schedule », « enabled » et le
// périmètre (« path », la source du job). Le nom reste la clé — c'est lui qui
// attache le dossier d'archives et sa rétention (voir l'en-tête du fichier).
// « label » n'existe pas dans la console : il est relu dans la description
// quand elle a la forme posée par l'amorçage, sinon l'étiquette déjà versionnée
// est gardée.
const FORME_DESCRIPTION = /^Sauvegarde du dossier \S+ — (.+)\.$/;
const NOM_JOB_FICHIERS = /^Fichiers - /;

const etiquette = (job, defaut) => {
  const m = FORME_DESCRIPTION.exec((job.description ?? "").trim());
  return m ? m[1] : defaut;
};

// Une source, un chemin relatif : c'est la seule forme que le fichier sait
// décrire. Tout le reste (job sans source, sources multiples, adaptateur de
// volume) se signale au lieu de se réduire de force à une ligne.
function cheminSource(job) {
  const sources = (job.sources ?? []).filter((s) => s && typeof s.path === "string" && s.path.length);
  if (sources.length !== 1) return null;
  return sources[0].path.replace(/^\/+/, "");
}

function ligne(job) {
  const champs = { name: job.name, path: job.path, label: job.label, schedule: job.schedule };
  if (job.enabled === false) champs.enabled = false;
  return `  ${JSON.stringify(champs)}`;
}

function comparaison(avant, apres) {
  const ecarts = [];
  for (const cle of ["schedule", "path"]) {
    if (avant[cle] !== apres[cle]) ecarts.push(`${cle}: « ${avant[cle]} » → « ${apres[cle]} »`);
  }
  const actifAvant = avant.enabled !== false;
  const actifApres = apres.enabled !== false;
  if (actifAvant !== actifApres) ecarts.push(actifApres ? "activé dans l'interface" : "désactivé dans l'interface");
  return ecarts;
}

// Les montages réels sous « /backup », lus dans compose.yaml (le dépôt les
// versionne, l'instance en place ne les connaît pas). Un job dont le chemin
// n'est couvert par aucun montage archive « rien » : la console le signale
// chaque nuit, et l'export doit le dire aussi plutôt que de le faire passer
// pour une donnée versionnée. C'est ainsi que « Fichiers - logs » se voit
// encore déclaré dans la console alors que « /backup/logs » est sorti du
// périmètre le 2026-11-09 avec le montage de « var/log ».
function montagesBackup() {
  const chemins = [];
  try {
    const texte = readFileSync(new URL("../../compose.yaml", import.meta.url), "utf8");
    for (const m of texte.matchAll(/^\s*-\s+\S+:(\/backup\/[^\s:]+)/gm)) chemins.push(m[1]);
  } catch {
    return null; // hors dépôt (conteneur « /opt/backup-tools ») : rien à croiser
  }
  return chemins;
}

const couvreMontage = (montages, chemin) =>
  !montages || montages.some((m) => {
    const relatif = m.slice("/backup/".length);
    return chemin === relatif || chemin.startsWith(`${relatif}/`);
  });

async function exporterJobs() {
  const fichier = JSON.parse(readFileSync(new URL("./jobs.json", import.meta.url), "utf8"));
  const live = await listJobs();
  const montages = montagesBackup();
  const parNom = new Map(live.map((j) => [j.name, j]));

  const resultat = [];
  const signales = [];
  let changes = 0;

  for (const declare of fichier) {
    const job = parNom.get(declare.name);
    if (!job) {
      // L'amorçage le recréera à la prochaine passe : l'export ne supprime
      // jamais une déclaration parce que l'instance ne la montre plus.
      resultat.push(declare);
      signales.push(`« ${declare.name} » absent de la console — déclaration gardée telle quelle`);
      continue;
    }
    const perimetre = cheminSource(job);
    const apres = {
      ...declare,
      schedule: job.schedule ?? job.cronExpression ?? declare.schedule,
      enabled: job.enabled,
      label: etiquette(job, declare.label),
    };
    if (perimetre) apres.path = perimetre;
    else signales.push(`« ${declare.name} » : ${job.sources?.length ?? 0} source(s) — périmètre non relisible, chemin versionné gardé`);
    const ecarts = comparaison(declare, apres);
    if (ecarts.length) {
      changes++;
      signales.push(`« ${declare.name} » : ${ecarts.join(", ")}`);
    }
    resultat.push(apres);
  }

  const connus = new Set(fichier.map((j) => j.name));
  for (const job of live) {
    if (connus.has(job.name) || !NOM_JOB_FICHIERS.test(job.name)) continue;
    const perimetre = cheminSource(job);
    if (!perimetre) {
      signales.push(`« ${job.name} » créé dans l'interface sans source unique — non exporté`);
      continue;
    }
    resultat.push({ name: job.name, path: perimetre, label: etiquette(job, "créé depuis l'interface"), schedule: job.schedule ?? job.cronExpression, enabled: job.enabled });
    changes++;
    signales.push(`« ${job.name} » : nouveau job déclaré depuis l'interface (${perimetre})`);
  }

  // Un chemin sans montage se signale, il ne disparaît pas du fichier : c'est
  // une décision de périmètre, donc une ligne à lire dans « git diff », pas un
  // nettoyage à décider ici.
  for (const j of resultat) {
    if (!couvreMontage(montages, j.path)) {
      signales.push(`« ${j.name} » : rien n'est monté sous « /backup/${j.path} » dans compose.yaml — le job n'a rien à archiver`);
    }
  }

  const texte = `[\n${resultat.map(ligne).join(",\n")}\n]\n`;
  if (OUT_FILE && OUT_FILE !== "-") {
    writeFileSync(OUT_FILE, texte);
  } else {
    process.stdout.write(texte);
  }

  const horsPerimetre = live.filter((j) => !NOM_JOB_FICHIERS.test(j.name)).map((j) => j.name);
  log(`jobs exportés : ${resultat.length} (${changes} écart(s) avec la déclaration versionnée)`);
  for (const s of signales) log(`  · ${s}`);
  if (horsPerimetre.length) log(`  · hors jobs de fichiers, non versionnés ici : ${horsPerimetre.join(", ")}`);
  if (OUT_FILE && OUT_FILE !== "-") log(`  · écrit dans ${OUT_FILE}`);
}

async function main() {
  requireEnv("DBACKUP_ADMIN_EMAIL", "DBACKUP_ADMIN_PASSWORD");
  await waitForApi();

  if (MODE_EXPORT) {
    await signIn();
    await assertApiWorks();
    await exporterJobs();
    return;
  }

  log("Amorçage de la console de sauvegarde…");
  const etat = await signIn();
  log(`  · compte administrateur ${ADMIN_EMAIL} : ${etat}`);
  await assertApiWorks();

  const sourceId = await ensureStorageAdapter(NAMES.source, "SOURCE", { basePath: SOURCE_BASE });
  const destId = await ensureStorageAdapter(NAMES.destination, "DESTINATION", { basePath: DEST_BASE });
  await ensureStorageAdapter(NAMES.restore, "SOURCE", { basePath: RESTORE_BASE });
  log(`  · restauration : cible « ${NAMES.restore} » (${RESTORE_BASE}), chemin relatif « <dossier> » — jamais les sources, en lecture seule`);

  // Un job par dossier : le nom du job devient le dossier d'archives, donc la
  // ligne « Jobs » en échec désigne le dossier en cause sans qu'on ouvre rien.
  for (const dossier of FILE_JOBS) {
    const actif = dossier.enabled ?? true;
    await createJob(
      {
        ...JOB_DEFAULTS,
        name: dossier.name,
        description: `Sauvegarde du dossier ${SOURCE_BASE}/${dossier.path} — ${dossier.label}.`,
        schedule: dossier.schedule,
        enabled: actif,
        destinations: [{ configId: destId, priority: 1, retentionPolicyId: RETENTION }],
        sources: [
          {
            configId: sourceId,
            priority: 1,
            // « stopContainers » vaut true par défaut dans la console (mesuré sur la
            // relecture du job) : c'est une option du connecteur « docker-volume »,
            // qui arrête le conteneur pendant la lecture. Les sources ici sont des
            // montages en lecture seule, et un arrêt nocturne de Traefik ou de php
            // par un job de sauvegarde n'a jamais été demandé.
            stopContainers: false,
            path: dossier.path,
            excludePatterns: EXCLUDES,
          },
        ],
      },
      actif ? "activé" : "désactivé",
      { resyncSources: true },
    );
  }

  await signalerEtatDesJobs();
  log("Console prête.");
}

main().catch((e) => die(`amorcage interrompu : ${e?.message ?? e}`));

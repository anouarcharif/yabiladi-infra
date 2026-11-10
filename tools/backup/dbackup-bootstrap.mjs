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
 */

const BASE = `http://127.0.0.1:${process.env.PORT || 3000}`;
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
// planification déjà créée (elle appartient à l'interface). Le même mouvement
// ferme le trou de 04:04 laissé par « logs » le 2026-11-09 : « var/log » est
// sorti du périmètre (les journaux Symfony ne sont pas une donnée à restaurer),
// et la planification des jobs restants se décale d'autant sur une machine
// neuve. Sur une instance déjà amorcée, ces minutes restent celles de
// l'interface : le décalage se décide dans « Jobs », job par job. Un écartement
// ne sérialise rien — « media » court encore quand le suivant démarre —, il
// baisse seulement le pic de lectures simultanées sur le NFS de destination. Le
// « créneau du dump SQL » invoqué ici jusqu'au 2026-11-09 n'existe plus : la
// base part à 02:00 par le DAG « mariadb_fetch », avant toute la série, et son
// archivage la ferme. Mesuré sur le poste de développement, donc sans valeur de
// débit : la cible a 16 cœurs et lit la MariaDB à distance, les durées réelles
// se liront sur le serveur.
const FILE_JOBS = [
  { name: "Fichiers - media", path: "media", schedule: "0 4 * * *", label: "médias téléversés (webroot/files)" },
  { name: "Fichiers - editor-images", path: "editor-images", schedule: "4 4 * * *", label: "images insérées par l'éditeur (webroot/img)" },
  { name: "Fichiers - traefik-config", path: "traefik-config", schedule: "8 4 * * *", label: "autorité et certificats auto-signés (docker/traefik)" },
  // Le montage du volume ACME est « docker/traefik-acme » ; le nom du job, lui,
  // ne prend pas de barre oblique — ce serait un sous-dossier sur le dépôt.
  { name: "Fichiers - traefik-acme", path: "docker/traefik-acme", schedule: "12 4 * * *", label: "certificats ACME (volume traefik_acme)" },
  // Les quatre suivants naissent désactivés : les trois applications voisines ne
  // sont pas encore servies et la MariaDB n'est pas encore équipée de son
  // mariabackup, leurs dossiers n'ont donc rien à archiver chaque nuit. Le job
  // existe pour que la bascule ne soit qu'un bouton — le jour J, on l'active
  // depuis « Jobs » après y avoir associé un profil de chiffrement.
  // L'amorçage ne rallume jamais un job existant ; une machine neuve doit donc
  // reproduire cet état, d'où le drapeau ici plutôt qu'une action manuelle.
  { name: "Fichiers - mediakit-img", path: "mediakit/public/img", schedule: "16 4 * * *", label: "visuels du catalogue mediakit (public/img)", enabled: false },
  // « public/uploads » couvre les documents de projets et les images des
  // incidents ; « var/bc_files » porte les bons de commande téléversés. Deux
  // jobs, donc deux archives et deux lignes de statut, comme pour les autres
  // dossiers : un bon de commande manquant ne doit pas se lire comme une pièce
  // jointe manquante. Le second suit le défaut de BC_PATH
  // (%kernel.project_dir%/var/bc_files) ; un chemin absolu sur le serveur
  // demanderait son propre montage.
  { name: "Fichiers - facturation-uploads", path: "facturation/public/uploads", schedule: "20 4 * * *", label: "pièces jointes de l'intranet (public/uploads)", enabled: false },
  { name: "Fichiers - facturation-bc", path: "facturation/var/bc_files", schedule: "24 4 * * *", label: "bons de commande de l'intranet (var/bc_files)", enabled: false },
  // Backup MariaDB physique (mariabackup) : 60GB de données, backup à chaud
  // sans downtime. Le job est désactivé en attendant la préparation du serveur
  // MariaDB (installation de mariabackup, déploiement des scripts, cron).
  // Une fois prêt : activer depuis l'interface Jobs, après avoir associé un
  // profil de chiffrement (recommandé pour les backups de base de données).
  // Voir scripts/backup/README.md pour la procédure complète.
  { name: "Fichiers - mariadb-physical", path: "mariadb-backups", schedule: "28 4 * * *", label: "backups physiques MariaDB (mariabackup, 60GB → ~15GB compressés)", enabled: false },
  // La discothèque des antennes : 9 Go mesurés sur le poste de développement,
  // et le contenu du site qui ne se régénère pas — il n'est ni dans git ni
  // dans les bases. Activé d'emblée, contrairement aux quatre jobs désactivés
  // d'à côté : ici la donnée est déjà en service. GZIP sur des MP3 ne gagne
  // presque rien, mais c'est le défaut de la maison et le « media » téléversé le
  // partage ; un réglage job par job se décide dans l'interface.
  { name: "Fichiers - radio-content", path: "radio-content", schedule: "32 4 * * *", label: "discothèque des antennes (data/radio_content)" },
];

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
const log = (m) => process.stdout.write(`${m}\n`);
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
  const setCookies = res.headers.getSetCookie?.() ?? [];
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
    log(`  · adaptateur ${role.toLowerCase()} « ${name} » : déjà en place`);
    return found.id;
  }
  const r = await call("POST", "/api/adapters", { name, type: "storage", adapterId: "local-filesystem", config, storageRole: role });
  if (r.status !== 201) die(`création de l'adaptateur « ${name} » (${r.status}) : ${r.text.slice(0, 200)}`);
  log(`  · adaptateur ${role.toLowerCase()} « ${name} » : créé (${config.basePath})`);
  return r.json.id;
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

async function main() {
  requireEnv("DBACKUP_ADMIN_EMAIL", "DBACKUP_ADMIN_PASSWORD");
  await waitForApi();

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

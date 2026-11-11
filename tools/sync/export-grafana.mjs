#!/usr/bin/env node
/**
 * Export des dashboards Grafana vers l'arbre versionné du dépôt d'infra.
 *
 *   node tools/sync/export-grafana.mjs                 # écrit les écarts
 *   node tools/sync/export-grafana.mjs --check          # ne écrit rien, signale
 *   node tools/sync/export-grafana.mjs --root <dir>      # cible un autre dépôt
 *
 * Codes de sortie : 0 rien à dire, 1 échec d'API, 2 écart constaté (« --check »),
 * 3 le crédit Viewer reçu n'ouvre pas CETTE instance — cas d'une machine neuve
 * avec la clé scellée d'un autre poste, c'est ce code que regarde le conducteur
 * de synchro pour aller fabriquer une clé locale.
 *
 * Identification : la seule acceptée est la clé du compte de service Viewer
 * « synchro-ihm », par « GRAFANA_SYNC_TOKEN » ou « GRAFANA_SYNC_TOKEN_FILE ».
 * Voir « authentification() » plus bas pour pourquoi le compte administrateur
 * n'y a plus sa place.
 *
 * Pourquoi un export et pas une écriture directe de Grafana : mesuré sur
 * 13.3.0 (2026-11-11, dossier « Radio », dashboard « yabiladi-radio-sante ») :
 *
 *   - « allowUiUpdates: false » → « GET /api/dashboards/uid/… » rend
 *     « meta.provisioned: true » : l'éditeur affiche la page en lecture seule.
 *     Le passer à « true » rend « meta.provisioned: false », « canEdit: true »
 *     et la retouche devient possible — c'est le réglage demandé ;
 *   - l'ancienne route d'écriture (« POST /api/dashboards/db », celle qui
 *     écrivait le fichier provisionné) répond 400 « Cannot save provisioned
 *     dashboard » dans les DEUX cas : avec le stockage unifié, l'écriture
 *     directe du fichier n'existe plus ;
 *   - la route de l'éditeur (« PUT /apis/dashboard.grafana.app/v1/… ») répond
 *     200 et écrit dans la base, pas dans le fichier ;
 *   - la retouche en base n'est pas annulée par le fournisseur tant que le
 *     fichier ne bouge pas (« grafana.app/sourceChecksum » reste égal au
 *     checksum du fichier, la sonde de 30 s ne re-provisionne pas). Elle l'est
 *     dès que le fichier change — donc si un « git pull » ramène un JSON plus
 *     vieux que la dernière retouche, l'interface la perd.
 *
 * Le fichier n'est donc pas la sortie de l'interface : ce script en est la
 * seule. Il lit l'instance par son API et n'y écrit jamais.
 *
 * Ce qu'il ne fait PAS : les règles d'alerte, les points de contact et la
 * politique de notification. Les trois sont provisionnés (« managedBy ») et
 * l'interface refuse de les enregistrer ; une règle créée à la main dans un
 * dossier hors approvisionnement ne se retrouve pas dans un fichier que
 * Grafana relirait — « --check » les signale, il n'y a rien à commiter de
 * fiable sur ce terrain-là tant que l'approvisionnement reste la source.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, renameSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RACINES = (() => {
  // Le script vit à <dépôt>/tools/sync/ ; « --root » permet de viser un autre
  // dépôt (le DAG de synchro travaille dans une copie de celui-là).
  const ici = dirname(fileURLToPath(import.meta.url));
  let racine = resolve(ici, "..", "..");
  const idx = process.argv.indexOf("--root");
  if (idx >= 0) racine = resolve(process.argv[idx + 1]);
  return {
    racine,
    dashboards: join(racine, "docker", "grafana", "dashboards"),
    aprovisionnement: join(racine, "docker", "grafana", "provisioning", "dashboards"),
  };
})();

// « GRAFANA » est le nom déjà employé par tools/logging/validate-dashboards.js
// pour viser la même instance ; « GRAFANA_URL » est celui des outils du dépôt
// d'infra passés par l'environnement. Les deux marchent, le premier cité gagne.
const URL_BASE = (process.env.GRAFANA_URL || process.env.GRAFANA || "http://grafana:3000").replace(/\/+$/, "");
const CHECK = process.argv.includes("--check");
const VERBEUX = process.argv.includes("--verbose");

// La valeur lue dans un fichier de secret est utilisée TELS QUELS, au \r près :
// mesuré le 2026-11-11, le mot de passe posé sur ce poste porte un « \r » de
// fin de ligne, la base Grafana l'a enregistré avec, et un « trim() » dans
// l'outillage produit un 401 « password-auth.failed » sans rapport apparent —
// et consomme une des vingt-cinq tentatives du limiteur d'authentification.
// Seuls les sauts de ligne finals sont retirés (ce que « $(cat) » fait), pas
// les retours chariot.
const lectureSecret = (chemin) => readFileSync(chemin, "utf8").replace(/\n+$/, "");

// Un fichier de secret se lit TEL QUEL — un jeton nu, la forme des « *_FILE » de
// Grafana — ou en bloc « .env », et les DEUX formes existent sur ces machines.
// Mesuré le 2026-11-11 avec une instance Grafana neuve sous les yeux : la clé
// que le DAG y fabrique atterrit dans « GRAFANA_SYNC_TOKEN=… », et envoyer le
// contenu entier comme jeton rend exactement le même 401 qu'une mauvaise clé —
// donc un message qui accuse l'identification alors que la clé est bonne, écrite
// et validée deux lignes plus haut par « GET /api/folders ». La ligne nommée est
// donc déshabillée si elle existe, sinon le contenu est le jeton.
const lectureJeton = (chemin) => {
  const texte = lectureSecret(chemin);
  const m = /^GRAFANA_SYNC_TOKEN=(.*)$/m.exec(texte);
  return (m ? m[1] : texte).replace(/\r$/, "");
};

// Code de sortie réservé : « le crédit que j'ai ne vaut pas pour CETTE
// instance ». C'est ce code que regarde « docker/dagu/ui-git-sync.sh » pour
// déclencher la fabrication d'une clé Viewer sur place
// (« tools/sync/bootstrap-grafana-sync-token.mjs ») puis relire la lecture. Un
// « 1 » reste une panne d'API, sans remède automatique.
const CODE_SANS_CREDIT = 3;
function sansCredit(motif) {
  process.stderr.write(
    `PAS DE CREDIT: ${motif} pour ${URL_BASE}.\n` +
    "Une clé de compte de service appartient à la base Grafana qui l'a émise : celle du coffre\n" +
    "ouvre le poste qui l'a vue naître, pas une instance neuve. Le conducteur de synchro\n" +
    "(« docker/dagu/ui-git-sync.sh » du dépôt du site) s'en fabrique alors une sur place avec\n" +
    "« tools/sync/bootstrap-grafana-sync-token.mjs » ; à la main, la même chose :\n" +
    "  node tools/sync/bootstrap-grafana-sync-token.mjs --out /chemin/cle-grafana\n" +
    "  GRAFANA_SYNC_TOKEN_FILE=/chemin/cle-grafana node tools/sync/export-grafana.mjs\n" +
    "La clé fabriquée ne se re-scelle PAS : elle ne vaut que pour cette instance.\n"
  );
  process.exit(CODE_SANS_CREDIT);
}

// Un seul crédit : la clé Viewer du compte de service, en variable ou dans un
// fichier. Le repli sur le compte administrateur que cette fonction contenait
// est supprimé, pour deux raisons mesurées : il ne pouvait fonctionner que là où
// le fichier « docker/grafana/secrets/admin_password » est lisible, donc jamais
// dans le conteneur dagu (uid 33, fichier en 0640 root:472 sur le serveur) ; et
// il donnait aux exporteurs un droit d'écriture qu'ils n'ont pas à avoir — ils
// ne lisent que des dashboards. L'administrateur ne sert qu'à FABRIQUER la clé
// Viewer, une fois par instance, dans l'outil d'amorçage.
function authentification() {
  const jeton = process.env.GRAFANA_SYNC_TOKEN || (process.env.GRAFANA_SYNC_TOKEN_FILE ? lectureJeton(process.env.GRAFANA_SYNC_TOKEN_FILE) : "");
  if (!jeton) sansCredit("aucune clé reçue (GRAFANA_SYNC_TOKEN et GRAFANA_SYNC_TOKEN_FILE sont vides)");
  return { authorization: `Bearer ${jeton.replace(/\r$/, "")}` };
}

const HEADERS = { ...authentification(), "content-type": "application/json" };

async function get(url) {
  const res = await fetch(`${URL_BASE}${url}`, { headers: HEADERS });
  const texte = await res.text();
  if (res.status === 401 || res.status === 403) {
    sansCredit(`refusé (${res.status})`);
  }
  if (!res.ok) {
    process.stderr.write(`ERREUR: ${url} → ${res.status} ${texte.slice(0, 200)}\n`);
    process.exit(1);
  }
  return JSON.parse(texte);
}

// Le dossier Git de chaque dashboard se déduit du fichier d'approvisionnement,
// pas d'une table recopiée ici : « folderUid » et « options.path » y sont déjà,
// et c'est ce que Grafana lit. Ajouter un fournisseur au YAML suffit donc pour
// que l'export aille écrire dans le répertoire correspondant.
function correspondanceDossiers() {
  const table = new Map();
  if (!existsSync(RACINES.aprovisionnement)) return table;
  for (const nomFichier of readdirSync(RACINES.aprovisionnement).filter((n) => /\.ya?ml$/.test(n))) {
    const texte = readFileSync(join(RACINES.aprovisionnement, nomFichier), "utf8");
    let courant = null;
    for (const ligne of texte.split(/\r?\n/)) {
      const uid = ligne.match(/^\s*folderUid:\s*'?([^']+)'?\s*$/);
      const chemin = ligne.match(/^\s*path:\s*'?([^']+)'?\s*$/);
      if (uid) courant = uid[1].trim();
      else if (chemin && courant) {
        table.set(courant, join(RACINES.dashboards, chemin[1].trim().split("/").pop()));
        courant = null;
      }
    }
  }
  return table;
}

// Deux JSON disent la même chose quand, une fois les clés des OBJETS triées à
// tous les niveaux, la suite d'octets est identique. L'ordre des TABLEAUX n'est
// pas neutralisé, et c'est mesuré (2026-11-11, les quatorze dashboards de
// l'instance, fichier versionné contre « GET /api/dashboards/uid/… ») : treize
// sur quatorze ressortent identiques tableau par tableau, dans l'ordre du
// fichier. Grafana ne permute donc pas « panels » — un panneau déplacé dans
// l'interface est un vrai changement, et le masquer reviendrait à ne jamais le
// committer. Ce qui diffère, ce n'est que l'ordre des clés, d'où le tri ici et
// la conservation de l'ordre du fichier à l'écriture.
//
// « id » et « version » sont retirés au niveau du dashboard (compteurs de la
// base Grafana) mais gardés partout ailleurs : « panels[].id » est une
// identité, pas un compteur.
const VOLATILES = new Set(["id", "version"]);
function canon(o) {
  if (Array.isArray(o)) return "[" + o.map(canon).join(",") + "]";
  if (o && typeof o === "object") {
    return "{" + Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canon(o[k])}`).join(",") + "}";
  }
  return JSON.stringify(o) ?? "null";
}
const sansCompteurs = (o) => {
  if (!o || typeof o !== "object" || Array.isArray(o)) return o;
  const c = { ...o };
  for (const k of VOLATILES) delete c[k];
  return c;
};
const memeContenu = (a, b) => canon(a) === canon(b);

// Écriture : conserver l'ordre des clés et la mise en forme du fichier là où le
// contenu n'a pas bougé, pour que « git diff » ne montre que la retouche.
//
// Les éléments de tableau se retrouvent par identité, dans cet ordre : « id »
// (un panneau), « name » (une variable), « title » (un panneau écrit à la main
// dans le dépôt et qui n'a pas d'« id » versionné — mesuré sur
// « yabiladi-radio-sante » : le fichier n'a pas d'« id », l'API en donne un à
// chaque panneau), puis par index si le contenu correspond à cela près, puis
// n'importe où dans le reste du tableau. Sans ces rapprochements, chaque
// exportation rendrait tout le tableau dans l'ordre de l'API avec ses clés dans
// le désordre de l'API : 429 lignes changées pour 2 clés ajoutées, et un
// « git diff » illisible.
const CLE_DIDENTITE = ["id", "name", "title", "uid"];
const canonSansCompteurs = (o) => canon(sansCompteurs(o));
function ordonner(depuis, neuf, auRacine) {
  if (Array.isArray(neuf)) {
    const avant = Array.isArray(depuis) ? depuis : [];
    const restants = avant.map((v, i) => ({ v, i, pris: false }));
    return neuf.map((item, index) => {
      let couple = null;
      for (const k of CLE_DIDENTITE) {
        if (!item || typeof item !== "object" || item[k] === undefined) continue;
        couple = restants.find((r) => !r.pris && r.v && typeof r.v === "object" && canon(r.v[k]) === canon(item[k]));
        if (couple) break;
      }
      if (!couple) couple = restants.find((r) => !r.pris && r.i === index && canonSansCompteurs(r.v) === canonSansCompteurs(item));
      if (!couple) couple = restants.find((r) => !r.pris && canonSansCompteurs(r.v) === canonSansCompteurs(item));
      if (couple) couple.pris = true;
      return ordonner(couple ? couple.v : undefined, item, false);
    });
  }
  if (neuf && typeof neuf === "object") {
    const avant = depuis && typeof depuis === "object" && !Array.isArray(depuis) ? depuis : {};
    const communes = Object.keys(avant).filter((k) => k in neuf);
    const nouvelles = Object.keys(neuf).filter((k) => !communes.includes(k)).sort();
    const sortie = {};
    for (const k of [...communes, ...nouvelles]) {
      if (auRacine && VOLATILES.has(k)) continue;
      sortie[k] = ordonner(avant[k], neuf[k], false);
    }
    return sortie;
  }
  return neuf;
}
function enForme(depuisFichier, neuf) {
  return JSON.stringify(ordonner(depuisFichier, neuf, true), null, 2) + "\n";
}

async function main() {
  const dossiers = correspondanceDossiers();
  const recherche = await get("/api/search?type=dash-db&limit=1000");
  const ecrits = [];
  const informes = [];
  const vivants = new Set();
  let inchanges = 0;

  for (const item of recherche) {
    const detail = await get(`/api/dashboards/uid/${item.uid}`);
    const meta = detail.meta;
    const corps = sansCompteurs(detail.dashboard);
    corps.uid = corps.uid ?? item.uid;

    const dossier = dossiers.get(meta.folderUid);
    if (!dossier) {
      informes.push(`« ${item.title} » (${item.uid}) : dossier « ${meta.folderUid || "Général"} » inconnu de l'approvisionnement — à ranger dans docker/grafana/dashboards/<dossier> et à déclarer dans le YAML des fournisseurs`);
      continue;
    }
    // Le nom du fichier vient de ce que Grafana a lu (« provisionedExternalId »)
    // pour ne jamais renommer un dashboard écrit à la main ; un dashboard créé
    // dans l'interface hérite de son uid.
    const nom = meta.provisionedExternalId || `${item.uid}.json`;
    const cible = join(dossier, nom);
    vivants.add(cible);
    const avant = existsSync(cible) ? sansCompteurs(JSON.parse(readFileSync(cible, "utf8"))) : null;

    if (avant && memeContenu(avant, corps)) {
      inchanges++;
      continue;
    }
    ecrits.push({
      chemin: cible,
      texte: enForme(avant, corps),
      motif: avant ? "contenu différent" : "nouveau dashboard",
      titre: item.title,
    });
  }

  // Un fichier versionné dont l'instance ne veut plus : il n'est pas supprimé
  // (« disableDeletion: true », et une suppression ne se décide pas depuis
  // l'interface) mais il doit se voir.
  if (existsSync(RACINES.dashboards)) {
    for (const sous of readdirSync(RACINES.dashboards, { withFileTypes: true })) {
      if (!sous.isDirectory()) continue;
      for (const f of readdirSync(join(RACINES.dashboards, sous.name)).filter((n) => n.endsWith(".json"))) {
        const chemin = join(RACINES.dashboards, sous.name, f);
        if (!vivants.has(chemin)) informes.push(`« ${sous.name}/${f} » : fichier versionné sans dashboard correspondant dans l'instance — rien n'est supprimé`);
      }
    }
  }

  for (const e of ecrits) {
    if (CHECK) {
      process.stdout.write(`à réécrire : ${e.chemin.slice(RACINES.racine.length + 1)} (${e.motif})\n`);
      continue;
    }
    mkdirSync(dirname(e.chemin), { recursive: true });
    const tmp = `${e.chemin}.tmp-export`;
    writeFileSync(tmp, e.texte);
    renameSync(tmp, e.chemin);
    process.stdout.write(`écrit : ${e.chemin.slice(RACINES.racine.length + 1)} (${e.motif})\n`);
  }
  for (const i of informes) process.stdout.write(`signalé : ${i}\n`);

  process.stdout.write(
    `dashboards : ${recherche.length} dans l'instance, ${ecrits.length} ${CHECK ? "en écart" :("réécrit(s)")}, ${inchanges} inchangé(s), ${informes.length} signal(s)\n`
  );

  // Codes de sortie : 0 rien à dire, 1 échec d'API, 2 écart constaté (--check),
  // 3 sans crédit (vu par « sansCredit() », seul code que le conducteur sait
  // réparer tout seul).
  if (CHECK && ecrits.length) process.exit(2);
  if (VERBEUX) process.stdout.write(`base : ${URL_BASE}\n`);
}

main().catch((e) => {
  process.stderr.write(`ERREUR: export interrompu : ${e?.message ?? e}\n`);
  process.exit(1);
});

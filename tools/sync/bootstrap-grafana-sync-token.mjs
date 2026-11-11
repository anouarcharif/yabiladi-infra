#!/usr/bin/env node
/**
 * Crée le compte de service Grafana dont la synchro d'IHM a besoin pour relire
 * les dashboards, et pose sa clé dans un fichier lu par elle.
 *
 *   node tools/sync/bootstrap-grafana-sync-token.mjs                       # depuis le dépôt
 *   GRAFANA=http://127.0.0.1:8088 node tools/sync/bootstrap-grafana-sync-token.mjs   # depuis l'hôte
 *   node tools/sync/bootstrap-grafana-sync-token.mjs --out <fichier>        # autre destination
 *
 * Pourquoi un compte de service et pas le compte administrateur : la synchro lit
 * des dashboards, elle n'écrit rien dans Grafana (mesuré le 2026-11-11 :
 * l'enregistrement d'une retouche passe par « PUT /apis/dashboard.grafana.app/v1/
 * … » et n'écrase aucun fichier). Le rôle « Viewer » suffit, et un jeton Viewer
 * volé ne donne pas la main sur Grafana.
 *
 * Ce script est le SEUL endroit de la synchro qui utilise le compte
 * administrateur — et le seul endroit où ce mot de passe voyage : il est scellé
 * sous deploy/secrets/grafana-admin.sops.bin et recopié, en sixième variable du
 * bloc « ui-sync », pour la raison mesurée suivante : une clé de compte de
 * service appartient à la base qui l'a émise. Celle du coffre ouvre CE poste et
 * rend 401 sur un serveur neuf, et rien de déclaratif n'en donne une à une
 * instance vierge (13.3.0 OSS ne lit pas « provisioning/access », et
 * « [security] admin_api_key » a disparu de « conf/defaults.ini »). Le conducteur
 * « docker/dagu/ui-git-sync.sh » appelle donc ce script avec « --out » sur son
 * propre volume à chaque « PAS DE CREDIT » : la clé fabriquée reste sur la
 * machine, elle n'est pas re-scellée — elle ne vaut que pour son instance.
 *
 * Les règles de secrets de ce dépôt s'appliquent :
 *  - la valeur n'est JAMAIS imprimée, ni ici ni dans un log ;
 *  - elle ne passe par aucun argument de ligne de commande (elle resterait dans
 *    « ps ») : le script la lit de l'API et l'écrit directement dans le fichier,
 *    en 0600, umask 077 ;
 *  - par défaut le fichier de sortie est docker/legacy/ui-sync.env du dépôt du
 *    site, hors git, déclaré dans deploy/secrets.manifest ; son contenu existant
 *    est CONSERVÉ — la ligne « GRAFANA_SYNC_TOKEN= » est remplacée en place, ou
 *    ajoutée, jamais écrasée au profit d'une écriture nue qui perdrait les cinq
 *    autres variables scellées (mesuré le 2026-11-11 sur ce poste : la première
 *    version du script faisait exactement cela) ;
 *  - le gabarit versionné des noms est docker/legacy/ui-sync.env.example.
 *
 * Idempotent : relancé, il vérifie que la clé déjà en place ouvre bien l'API en
 * lecture ; si oui il ne touche à rien, si non il crée une nouvelle clé (l'ancien
 * jeton est révoqué, sinon la console en garderait deux).
 *
 * Sorties : 0 clé en place, 1 échec (Grafana injoignable, refusé, ou écriture
 * impossible), 2 usage.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, chmodSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RACINE = (() => {
  const ici = dirname(fileURLToPath(import.meta.url));
  const idx = process.argv.indexOf("--repo");
  return idx >= 0 ? resolve(process.argv[idx + 1]) : resolve(ici, "..", "..");
})();
const NOM_COMPTE = process.env.GRAFANA_SYNC_SA_NAME || "synchro-ihm";
const NOM_CLE = "synchro";
let SORTIE = process.env.GRAFANA_SYNC_ENV_FILE || join(RACINE, "docker", "legacy", "ui-sync.env");
// « --out » = destination hors coffre (le volume du conteneur dagu, sur une
// machine neuve). Elle change le mot de la fin : une clé fabriquée pour UNE
// instance ne se scelle pas, elle ferait disparaître celle de la machine qui a
// servi de source au scellement.
let HORS_COFFRE = false;
{
  const idx = process.argv.indexOf("--out");
  if (idx >= 0) { SORTIE = resolve(process.argv[idx + 1]); HORS_COFFRE = true; }
}
if (process.argv.includes("--help") || process.argv.includes("-h")) {
  process.stdout.write("Usage : node tools/sync/bootstrap-grafana-sync-token.mjs [--repo <dépôt>] [--out <fichier>]\nCrée le compte de service « " + NOM_COMPTE + " » et pose sa clé sans jamais l'afficher : dans\ndocker/legacy/ui-sync.env (le clair que scelle le coffre) par défaut, dans « --out » sinon —\nc'est le cas du conteneur dagu sur une machine neuve, où la clé reste sur le volume.\n");
  process.exit(0);
}

const BASE = (process.env.GRAFANA_URL || process.env.GRAFANA || "http://grafana:3000").replace(/\/+$/, "");
const LECTURE_ADMIN = () => {
  const usager = process.env.GRAFANA_ADMIN_USER || "yabiladi";
  // Même handling que tools/sync/export-grafana.mjs : les sauts de ligne finaux
  // seulement, jamais les retours chariot. Mesuré le 2026-11-11 sur ce poste : le
  // fichier portait un « \r » que la base Grafana a enregistré tel quel, et un
  // « trim() » donnait un 401 sans rapport apparent — plus vingt-cinq tentatives
  // du limiteur d'authentification consommées. Le fichier est maintenant propre
  // (43 octets, sans CR ni LF) et c'est cet état qui est scellé ; la règle de
  // tonte, elle, ne change pas, sinon la valeur re-scellée divergerait de la base.
  const motDePasse = (process.env.GRAFANA_ADMIN_PASSWORD || "").replace(/\n+$/, "")
    || (() => {
      const fichier = process.env.GRAFANA_ADMIN_PASSWORD_FILE || join(RACINE, "docker", "grafana", "secrets", "admin_password");
      if (!existsSync(fichier)) return "";
      return readFileSync(fichier, "utf8").replace(/\n+$/, "");
    })();
  if (!usager || !motDePasse) {
    process.stderr.write("ERREUR: pas de compte administrateur — GRAFANA_ADMIN_USER + GRAFANA_ADMIN_PASSWORD(_FILE) dans l'environnement (le bloc « ui-sync » du coffre porte cette sixième variable, et c'est de là que la lit le conteneur dagu), ou le fichier docker/grafana/secrets/admin_password de la machine (celui que scelle deploy/secrets/grafana-admin.sops.bin)\n");
    process.exit(1);
  }
  return "Basic " + Buffer.from(`${usager}:${motDePasse}`).toString("base64");
};

async function api(méthode, url, corps, authorization) {
  const entêtes = { authorization: authorization ?? LECTURE_ADMIN() };
  if (corps !== undefined) entêtes["content-type"] = "application/json";
  const res = await fetch(`${BASE}${url}`, { method: méthode, headers: entêtes, body: corps === undefined ? undefined : JSON.stringify(corps) });
  const texte = await res.text();
  let json = null;
  try { json = JSON.parse(texte); } catch { /* un HTML d'erreur n'est pas du JSON */ }
  return { statut: res.status, json, texte };
}

// La clé déjà posée vaut-elle encore en lecture ? C'est le seul test : un jeton
// révoqué, un compte supprimé ou un mot de passe changé donnent le même 401.
async function cleValide(cle) {
  if (!cle) return false;
  const r = await api("GET", "/api/folders", undefined, `Bearer ${cle}`);
  return r.statut === 200;
}

function cleDejaDansLeFichier() {
  if (!existsSync(SORTIE)) return "";
  const m = /^GRAFANA_SYNC_TOKEN=(.*)$/m.exec(readFileSync(SORTIE, "utf8"));
  return m ? m[1].trim() : "";
}

async function main() {
  // « /api/health » est public : c'est la sonde de présence, avant de toucher
  // un fichier de secret sur la machine.
  try {
    const santé = await fetch(`${BASE}/api/health`);
    if (santé.status !== 200) {
      process.stderr.write(`ERREUR: Grafana répond ${santé.status} sur ${BASE}\n`);
      process.exit(1);
    }
  } catch {
    process.stderr.write(`ERREUR: Grafana injoignable sur ${BASE}\n`);
    process.exit(1);
  }

  const cleExistante = cleDejaDansLeFichier();
  if (await cleValide(cleExistante)) {
    process.stdout.write(`Clé déjà en place dans ${SORTIE} : rien n'est changé.\n`);
    return;
  }

  // Le compte, s'il manque. « POST /api/serviceaccounts » répond 404 en lecture
  // (la route n'existe qu'en écriture) ; c'est « /api/serviceaccounts/search »
  // qui liste, mesuré sur 13.3.0.
  const recherche = await api("GET", "/api/serviceaccounts/search");
  if (recherche.statut !== 200) {
    process.stderr.write(`ERREUR: lecture des comptes de service refusée (${recherche.statut}) — le compte administrateur est-il le bon ? La valeur n'est jamais affichée.\n`);
    process.exit(1);
  }
  let compte = (recherche.json?.serviceAccounts ?? []).find((sa) => sa.name === NOM_COMPTE && !sa.isDisabled);
  if (!compte) {
    const création = await api("POST", "/api/serviceaccounts", { name: NOM_COMPTE, role: "Viewer", isDisabled: false });
    if (![200, 201].includes(création.statut)) {
      process.stderr.write(`ERREUR: création du compte de service « ${NOM_COMPTE} » (${création.statut}) : ${création.texte.slice(0, 200)}\n`);
      process.exit(1);
    }
    compte = création.json;
    process.stdout.write(`compte de service « ${NOM_COMPTE} » créé (rôle Viewer, id ${compte.id})\n`);
  } else {
    process.stdout.write(`compte de service « ${NOM_COMPTE} » déjà là (id ${compte.id})\n`);
  }

  // Une seule clé à la fois sur ce compte : les jetons du même nom sont révoqués
  // avant la recréation, sinon la console accumulerait des clés vivantes.
  const listes = await api("GET", `/api/serviceaccounts/${compte.id}/tokens`);
  for (const jeton of (listes.json ?? [])) {
    if (jeton.name !== NOM_CLE) continue;
    await api("DELETE", `/api/serviceaccounts/${compte.id}/tokens/${jeton.id}`);
    process.stdout.write(`ancienne clé « ${NOM_CLE} » révoquée\n`);
  }

  const nouvelle = await api("POST", `/api/serviceaccounts/${compte.id}/tokens`, { name: NOM_CLE });
  const cle = nouvelle.json?.key ?? nouvelle.json?.token;
  if (![200, 201].includes(nouvelle.statut) || !cle) {
    process.stderr.write(`ERREUR: création de la clé (${nouvelle.statut}) : ${nouvelle.texte.slice(0, 200)}\n`);
    process.exit(1);
  }
  if (!(await cleValide(cle))) {
    process.stderr.write("ERREUR: la clé créée n'ouvre pas l'API en lecture — rien n'est écrit.\n");
    process.exit(1);
  }

  mkdirSync(dirname(SORTIE), { recursive: true });
  // Fusion, pas réécriture : « SORTIE » est le fichier que le coffre scelle, et
  // il porte cinq autres lignes (GIT_PUSH_TOKEN, GIT_PUSH_USER, le couple
  // DBackup, GRAFANA_ADMIN_PASSWORD). Écrire le fichier depuis zéro les effaçait,
  // et le scellement suivant partait d'un clair amputé. Le remplacement vise la
  // seule ligne « GRAFANA_SYNC_TOKEN= » et laisse les autres octets en place ; la
  // valeur s'insère par une fonction, sinon un « $ » d'un jeton serait lu comme
  // une référence d'expression régulière.
  const existant = existsSync(SORTIE) ? readFileSync(SORTIE, "utf8") : "";
  const ligne = `GRAFANA_SYNC_TOKEN=${cle}`;
  const prochain = /^GRAFANA_SYNC_TOKEN=.*$/m.test(existant)
    ? existant.replace(/^GRAFANA_SYNC_TOKEN=.*$/m, () => ligne)
    : `${existant}${existant === "" || existant.endsWith("\n") ? "" : "\n"}${ligne}\n`;
  const umask = process.umask(0o077);
  try {
    writeFileSync(SORTIE, prochain, { mode: 0o600 });
  } finally {
    process.umask(umask);
  }
  try { chmodSync(SORTIE, 0o600); } catch { /* Windows : le mode vient de l'ACL, pas de umask */ }
  process.stdout.write(
    HORS_COFFRE
      ? `clé écrite dans ${SORTIE} (0600, jamais affichée) — elle reste sur cette machine : émise par ${BASE}, elle n'ouvre aucune autre instance et ne se scelle pas\n`
      : `clé écrite dans ${SORTIE} (0600, jamais affichée) — à sceller depuis le dépôt d'infra : TARGET_PROJECT=site TARGET_PROJECT_DIR=<dépôt du site> SECRETS_ONLY=ui-sync ./deploy.sh --encrypt\n`
  );
}

main().catch((e) => {
  process.stderr.write(`ERREUR: amorçage interrompu : ${e?.message ?? e}\n`);
  process.exit(1);
});

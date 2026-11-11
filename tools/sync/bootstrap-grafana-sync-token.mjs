#!/usr/bin/env node
/**
 * Crée le compte de service Grafana dont la synchro d'IHM a besoin pour relire
 * les dashboards, et pose sa clé dans le fichier que le coffre scelle.
 *
 *   node tools/sync/bootstrap-grafana-sync-token.mjs                       # depuis le dépôt
 *   GRAFANA=http://127.0.0.1:8088 node tools/sync/bootstrap-grafana-sync-token.mjs   # depuis l'hôte
 *
 * Pourquoi un compte de service et pas le compte administrateur : la synchro lit
 * des dashboards, elle n'écrit rien dans Grafana (mesuré le 2026-11-11 :
 * l'enregistrement d'une retouche passe par « PUT /apis/dashboard.grafana.app/v1/
 * … » et n'écrase aucun fichier). Le rôle « Viewer » suffit, et un jeton Viewer
 * volé ne donne pas la main sur Grafana. Le compte administrateur de la machine,
 * lui, reste hors coffre (voir deploy/secrets.manifest : il n'a d'effet qu'au
 * tout premier démarrage).
 *
 * Les règles de secrets de ce dépôt s'appliquent :
 *  - la valeur n'est JAMAIS imprimée, ni ici ni dans un log ;
 *  - elle ne passe par aucun argument de ligne de commande (elle resterait dans
 *    « ps ») : le script la lit de l'API et l'écrit directement dans le fichier,
 *    en 0600, umask 077 ;
 *  - le fichier de sortie est hors git (docker/legacy/*.env) et sa ligne est
 *    déclarée dans deploy/secrets.manifest ; le gabarit versionné des noms est
 *    docker/legacy/ui-sync.env.example.
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
{
  const idx = process.argv.indexOf("--out");
  if (idx >= 0) SORTIE = resolve(process.argv[idx + 1]);
}
if (process.argv.includes("--help") || process.argv.includes("-h")) {
  process.stdout.write("Usage : node tools/sync/bootstrap-grafana-sync-token.mjs [--repo <dépôt>] [--out <fichier>]\nCrée le compte de service « " + NOM_COMPTE + " » et pose sa clé dans docker/legacy/ui-sync.env, sans jamais l'afficher.\n");
  process.exit(0);
}

const BASE = (process.env.GRAFANA_URL || process.env.GRAFANA || "http://grafana:3000").replace(/\/+$/, "");
const LECTURE_ADMIN = () => {
  const usager = process.env.GRAFANA_ADMIN_USER || "yabiladi";
  // Même handling que tools/sync/export-grafana.mjs : les sauts de ligne finaux
  // seulement. Le fichier de la machine se termine par un « \r » que la base
  // Grafana a enregistré ; le retirer produit un 401 sans rapport apparent.
  const motDePasse = (process.env.GRAFANA_ADMIN_PASSWORD || "").replace(/\n+$/, "")
    || (() => {
      const fichier = process.env.GRAFANA_ADMIN_PASSWORD_FILE || join(RACINE, "docker", "grafana", "secrets", "admin_password");
      if (!existsSync(fichier)) return "";
      return readFileSync(fichier, "utf8").replace(/\n+$/, "");
    })();
  if (!usager || !motDePasse) {
    process.stderr.write("ERREUR: pas de compte administrateur — GRAFANA_ADMIN_USER + GRAFANA_ADMIN_PASSWORD(_FILE), ou docker/grafana/secrets/admin_password sur la machine (reposé par tools/logging/bootstrap-grafana-admin.sh)\n");
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
  const umask = process.umask(0o077);
  try {
    writeFileSync(SORTIE, `GRAFANA_SYNC_TOKEN=${cle}\n`, { mode: 0o600 });
  } finally {
    process.umask(umask);
  }
  try { chmodSync(SORTIE, 0o600); } catch { /* Windows : le mode vient de l'ACL, pas de umask */ }
  process.stdout.write(`clé écrite dans ${SORTIE} (0600, jamais affichée) — à sceller : SECRETS_ONLY=ui-sync ./deploy.sh --encrypt\n`);
}

main().catch((e) => {
  process.stderr.write(`ERREUR: amorçage interrompu : ${e?.message ?? e}\n`);
  process.exit(1);
});

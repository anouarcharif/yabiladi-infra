#!/usr/bin/env node
/**
 * Déclenche une sauvegarde immédiate dans la console DBackup, attend sa fin et
 * en vérifie le résultat matériel. C'est le pendant « un seul job » de
 * « dbackup-bootstrap.mjs », qui pose les réglages mais n'exécute rien.
 *
 *   docker compose exec -T dbackup node /opt/backup-tools/run-job.mjs "portainer-volume-backup"
 *   docker compose exec -T dbackup node /opt/backup-tools/run-job.mjs --list
 *   docker compose exec -T dbackup node /opt/backup-tools/run-job.mjs --check "portainer-volume-backup"
 *
 * Trois verbes :
 *   --list          les jobs de la console, avec leur dernière exécution ;
 *   --check         relire la dernière archive d'un job sans rien déclencher ;
 *   (nom du job)    lancer, attendre, prouver.
 *
 * Le troisième est la réponse à un angle mort mesuré de la console : elle
 * déclare « Success » une archive qui ne contient RIEN. Le 2026-11-12, dix
 * archives produites depuis le 2026-11-01 portaient « files: 0 » et
 * « logicalSize: 0 » pendant que l'adaptateur de source pointait sur la racine
 * des archives au lieu des données — chacune s'affichait en vert dans
 * « Executions ». Ce script ne se contente donc pas du statut : il relit le
 * manifeste JSON posé à côté du TAR et meurt si le compte des fichiers vaut
 * zéro. Une sauvegarde vide n'est pas une sauvegarde réussie.
 *
 * Les trois routes utilisées sont mesurées sur 4.0.2 (le 2026-11-12) :
 *   POST /api/jobs/{id}/run   → 200 {"success":true,"executionId":"…"} ;
 *   GET  /api/jobs/{id}/runs  → 200 {"success":true,"data":{"runs":[…]}} ;
 *   GET  /api/jobs            → 200, tableau des jobs (jamais /api/archives : 404).
 *
 * Le compte vient de l'environnement du conteneur (docker/legacy/dbackup.env,
 * scellé dans deploy/secrets/dbackup.sops.bin) : rien n'est demandé au clavier,
 * rien n'est jamais affiché.
 */

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";

const BASE = (process.env.DBACKUP_URL || `http://127.0.0.1:${process.env.PORT || 3000}`).replace(/\/+$/, "");
const AUTH_ORIGIN = process.env.BETTER_AUTH_URL || BASE;
const DEST_BASE = process.env.DBACKUP_DEST_BASE || "/backups";
const ADMIN_EMAIL = process.env.DBACKUP_ADMIN_EMAIL;
const ADMIN_PASSWORD = process.env.DBACKUP_ADMIN_PASSWORD;

const ARGS = process.argv.slice(2);
const TIMEOUT_SECONDS = (() => {
    const i = ARGS.indexOf("--timeout");
    return i >= 0 ? Number(ARGS[i + 1]) : 1800;
})();
const AS_JSON = ARGS.includes("--json");
const LIST = ARGS.includes("--list");
const CHECK = ARGS.includes("--check");
const JOB_NAME = ARGS.find((a, i) => !a.startsWith("--") && ARGS[i - 1] !== "--timeout");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// En mode « --json », stdout ne rend que l'objet de résultat : le script se
// termine alors par un « console.log(JSON.stringify(…)) » unique, et les
// journaux de progression partent sur stderr.
const say = (m) => process.stderr.write(`${m}\n`);
function die(message, detail = null) {
    if (AS_JSON && detail) process.stdout.write(`${JSON.stringify({ ok: false, message, ...detail }, null, 2)}\n`);
    process.stderr.write(`ERREUR: ${message}\n`);
    process.exit(1);
}

let cookie = "";
async function call(method, path, body, { auth = true, origin = false } = {}) {
    const headers = {};
    if (body !== undefined) headers["content-type"] = "application/json";
    if (origin) headers.origin = AUTH_ORIGIN;
    if (auth && cookie) headers.cookie = cookie;
    let res;
    try {
        res = await fetch(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    } catch {
        return { status: 0, json: null, text: "" };
    }
    // Repli sur l'en-tête unique pour les Node qui n'ont pas getSetCookie()
    // (mesuré sur 4.0.2 : l'image en embarque un 18.x côté Dagu, un 24.x ici).
    const setCookies = typeof res.headers.getSetCookie === "function"
        ? res.headers.getSetCookie()
        : (res.headers.get("set-cookie") ?? "").split(/,(?=\s*[A-Za-z0-9_.-]+=)/).map((c) => c.trim()).filter((c) => c.length);
    for (const c of setCookies) {
        const pair = c.split(";")[0].trim();
        cookie = cookie ? `${cookie}; ${pair}` : pair;
    }
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* les pages rendues ne sont pas du JSON */ }
    return { status: res.status, json, text };
}

async function waitForApi(maxSeconds = 120) {
    for (let waited = 0; waited < maxSeconds; waited += 3) {
        const r = await call("GET", "/api/health", undefined, { auth: false });
        if (r.status === 200 && r.json?.status === "healthy" && r.json?.database === "connected") return;
        await sleep(3000);
    }
    die("la console ne répond pas sur /api/health — « docker compose logs dbackup »");
}

async function signIn() {
    for (let attempt = 1; attempt <= 3; attempt++) {
        const r = await call("POST", "/api/auth/sign-in/email", { email: ADMIN_EMAIL, password: ADMIN_PASSWORD }, { auth: false, origin: true });
        if (r.status === 200) { await call("GET", "/dashboard"); return; }
        if (r.status === 429) { say("   (limite de débit de l'authentification, nouvelle tentative dans 60 s)"); await sleep(60000); continue; }
        die(`authentification refusée (${r.status}) — le compte du coffre n'ouvre pas cette console`);
    }
    die("authentification impossible : limite de débit atteinte");
}

async function listJobs() {
    const r = await call("GET", "/api/jobs");
    if (r.status !== 200) die(`lecture des jobs (${r.status})`);
    return Array.isArray(r.json) ? r.json : [];
}

async function runsOf(jobId) {
    const r = await call("GET", `/api/jobs/${jobId}/runs`);
    if (r.status !== 200) die(`lecture des exécutions du job (${r.status})`);
    return r.json?.data?.runs ?? [];
}

// Ce que la console écrit à côté de chaque TAR. Le nom du dossier de
// destination est le NOM DU JOB, mesuré : « /backups/<nom du job>/chain-<horodatage>/…».
function manifstes(jobName) {
    const dossier = `${DEST_BASE}/${jobName}`;
    if (!existsSync(dossier)) return [];
    const fichiers = [];
    for (const chaine of readdirSync(dossier)) {
        const chemin = `${dossier}/${chaine}`;
        if (!statSync(chemin).isDirectory()) continue;
        for (const f of readdirSync(chemin)) {
            if (f.endsWith(".tar.meta.json")) fichiers.push(`${chemin}/${f}`);
        }
    }
    // Le plus récent d'abord, à la fois par l'horodatage du nom de chaîne et par
    // celui du disque : un « chain- » écrit à la main romprait le premier tri.
    return fichiers
        .map((p) => ({ path: p, mtime: statSync(p).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime);
}

// Une chaîne, pas un fichier : « portainer-volume-backup » tourne toutes les
// nuits, et une nuit sans changement produit un incrémental légitimement à
// « files: 0 » (mesuré le 2026-11-12 : le deuxième passage après un complet à 6
// fichiers rend « inc-001.tar », 0 fichier, « Success »). Déclarer cette
// exécution-là échouée serait faux ; déclarer une chaîne sauvegardée sur la foi
// de son seul dernier maillon l'est aussi. Ce qui se juge, c'est la chaîne la
// plus récente : son complet doit tenir des fichiers, et chaque maillon doit
// avoir passé le contrôle post-envoi de la console.
function decrireChaine(jobName) {
    const tous = manifstes(jobName);
    if (!tous.length) return { presente: false, chaine: null, maillons: [], pleine: null, fichiers: null, octets: null, taries: 0 };

    const parChaine = new Map();
    for (const { path, mtime } of tous) {
        const dossier = path.slice(0, path.lastIndexOf("/"));
        if (!parChaine.has(dossier)) parChaine.set(dossier, { maillons: [], frais: 0 });
        let meta = null;
        try { meta = JSON.parse(readFileSync(path, "utf8")); } catch { meta = null; }
        parChaine.get(dossier).maillons.push({
            tar: path.replace(/\.meta\.json$/, ""),
            // « files » n'est PAS au premier niveau du manifeste (mesuré) : il
            // vit sous « archive », à côté de « compression » et « encrypted ».
            nom: path.slice(path.lastIndexOf("/") + 1).replace(".tar.meta.json", ".tar"),
            type: meta?.backupType ?? null,
            fichiers: meta?.archive?.files ?? null,
            octets: meta?.logicalSize ?? null,
            verification: meta?.verification?.passed ?? null,
            checksum: meta?.checksum ?? null,
            methodeControle: meta?.verification?.method ?? null,
        });
        parChaine.get(dossier).frais = Math.max(parChaine.get(dossier).frais, mtime);
        parChaine.get(dossier).dossier = dossier;
    }
    // La chaîne « la plus récente » est celle dont un maillon a été écrit le
    // plus tard — et non celle dont le nom porte le plus vieil horodatage : un
    // incrémental d'aujourd'hui vit dans la chaîne ouverte il y a sept jours.
    const chaine = [...parChaine.values()].sort((a, b) => a.frais - b.frais).pop();

    const maillons = chaine.maillons;
    const pleine = maillons.find((m) => m.type === "full") ?? null;
    // « manifstes » rend le plus récent d'abord, donc maillons[0] est le dernier
    // écrit de la chaîne — c'est lui que la juste exécution a produit.
    const recent = maillons[0];
    return {
        presente: true,
        chaine: chaine.dossier,
        maillons,
        pleine,
        recent,
        // Ce que la chaîne sait rendre : le contenu du complet, plus les
        // incrémentaux. Un complet absent (chaîne purgée, rétention) se dit.
        fichiers: pleine?.fichiers ?? null,
        octets: pleine?.octets ?? null,
        type: recent?.type ?? null,
        verification: maillons.every((m) => m.verification === true),
        checksum: recent?.checksum ?? null,
        methodeControle: recent?.methodeControle ?? null,
        taries: maillons.length,
    };
}

const ETATS_FINAUX = new Set(["Success", "Successful", "Completed", "Failed", "Error", "Partial", "Cancelled", "Canceled", "Aborted"]);

async function principale() {
    if (!ADMIN_EMAIL || !ADMIN_PASSWORD) {
        die("variables DBACKUP_ADMIN_EMAIL et DBACKUP_ADMIN_PASSWORD absentes — docker/legacy/dbackup.env n'est pas matérialisé sur cette machine");
    }
    await waitForApi();
    await signIn();

    const jobs = await listJobs();

    if (LIST) {
        for (const j of jobs) {
            const runs = await runsOf(j.id);
            const derniere = runs[0];
            say(`  · ${j.name}  ${j.enabled ? "activé " : "éteint "}  schedule « ${j.schedule ?? j.cronExpression ?? "—"} »  dernière : ${derniere ? `${derniere.status} le ${derniere.startedAt ?? "?"}` : "aucune"}`);
        }
        say(`  ${jobs.length} job(s) dans la console.`);
        return;
    }

    if (!JOB_NAME) die("aucun nom de job — « run-job.mjs \"portainer-volume-backup\" », ou --list, ou --check <nom>");
    const job = jobs.find((j) => j.name === JOB_NAME);
    if (!job) die(`aucun job ne s'appelle exactement « ${JOB_NAME} » — « --list » montre les ${jobs.length} noms en place`);

    if (CHECK) {
        const etat = decrireChaine(JOB_NAME);
        if (!etat.presente) die(`aucune archive pour « ${JOB_NAME} » sous ${DEST_BASE}/${JOB_NAME}`);
        say(`  · chaîne : ${etat.chaine} (${etat.taries} maillon(s))`);
        for (const m of etat.maillons) say(`    - ${m.nom} : ${m.type}, ${m.fichiers ?? "?"} fichier(s), ${m.octets ?? "?"} octet(s) logiques, contrôle ${m.verification === true ? "passé" : m.verification === false ? "ÉCHEC" : "absent"}`);
        if (!etat.pleine) die(`chaîne sans « full » : la rétention a purgé le complet, les incrémentaux ne se relisent plus`);
        if (!(etat.fichiers > 0)) die(`le complet de la chaîne est vide (${etat.fichiers ?? "absent"} fichier) : la sauvegarde est déclarée, pas faite`);
        if (!etat.verification) die("un maillon au moins n'a pas passé le contrôle post-envoi de la console");
        say(`  · chaîne sauvegardée et contrôlée : ${etat.fichiers} fichier(s), ${etat.octets} octet(s) logiques au complet.`);
        return;
    }

    if (!job.enabled) {
        // Un job éteint reste exécutable à la demande : c'est ce qui permet de
        // jouer une première sauvegarde avant de l'activer pour la nuit.
        say(`  · ATTENTION : « ${JOB_NAME} » est désactivé dans la console — exécution unique, rien n'est changé.`);
    }

    const avant = await runsOf(job.id);
    const identifiantsConnus = new Set(avant.map((r) => r.id));

    say(`  · déclenchement de « ${JOB_NAME} »…`);
    const lance = await call("POST", `/api/jobs/${job.id}/run`, {});
    if (lance.status !== 200 || lance.json?.success !== true) {
        die(`« POST /api/jobs/{id}/run » refusé (${lance.status}) : ${lance.text.slice(0, 200)}`);
    }
    const executionId = lance.json.executionId ?? null;
    say(`  · exécution ${executionId ?? "?"} mise en file — attente jusqu'à ${Math.round(TIMEOUT_SECONDS / 60)} min`);

    let courante = null;
    const fin = Date.now() + TIMEOUT_SECONDS * 1000;
    while (Date.now() < fin) {
        await sleep(5000);
        const runs = await runsOf(job.id);
        courante = (executionId ? runs.find((r) => r.id === executionId) : null)
            ?? runs.find((r) => !identifiantsConnus.has(r.id))
            ?? runs[0] ?? null;
        if (courante && ETATS_FINAUX.has(courante.status)) break;
        courante = null;
    }
    if (!courante) die(`exécution non terminée au bout de ${TIMEOUT_SECONDS} s — « --check ${JOB_NAME} » relira l'archive plus tard`);

    const chaine = decrireChaine(JOB_NAME);
    const resultat = {
        ok: courante.status === "Success" && chaine.presente && (chaine.fichiers ?? 0) > 0 && chaine.verification,
        job: JOB_NAME,
        execution: { id: courante.id, status: courante.status, startedAt: courante.startedAt, finishedAt: courante.finishedAt ?? courante.completedAt ?? null },
        chaine: chaine.chaine,
        maillonProduit: chaine.recent?.nom ?? null,
        typeDuMaillon: chaine.type,
        fichiersDuMaillon: chaine.recent?.fichiers ?? null,
        octetsDuMaillon: chaine.recent?.octets ?? null,
        fichiersDuComplet: chaine.fichiers,
        octetsDuComplet: chaine.octets,
        maillonsDansLaChaine: chaine.taries,
        verification: chaine.verification,
        checksum: chaine.checksum,
        message: courante.error ?? courante.message ?? null,
    };
    if (AS_JSON) process.stdout.write(`${JSON.stringify(resultat, null, 2)}\n`);
    say(`  · exécution ${courante.id} : ${courante.status}`);
    if (resultat.message) say(`  · ${resultat.message}`);
    say(`  · chaîne : ${chaine.chaine ?? "aucune"} — maillon de cette exécution : ${chaine.recent?.nom ?? "?"} (${chaine.type}, ${chaine.recent?.fichiers ?? "?"} fichier(s), ${chaine.recent?.octets ?? "?"} octet(s) logiques)`);
    say(`  · ce que la chaîne sait rendre : ${chaine.fichiers ?? "?"} fichier(s), ${chaine.octets ?? "?"} octet(s) logiques au complet (${chaine.taries} maillon(s))`);
    if (chaine.checksum) say(`  · sha256 du maillon : ${String(chaine.checksum).slice(0, 16)}… (contrôle ${chaine.methodeControle ?? "?"})`);
    if (courante.status !== "Success") die(`la console rend « ${courante.status} », pas « Success »`, resultat);
    if (!chaine.presente) die("aucune archive écrite par cette exécution", resultat);
    if (!chaine.pleine) die("la chaîne ne contient plus de « full » : la rétention a purgé le complet, les incrémentaux ne se relisent plus", resultat);
    // Un incrémental à zéro fichier est un résultat NORMAL (rien n'a bougé depuis
    // la dernière passe) : ce n'est pas une sauvegarde vide. Ce qui doit être non
    // vide, c'est ce que la chaîne sait rendre — son complet.
    if ((chaine.recent?.fichiers ?? 0) === 0 && chaine.type !== "incremental") {
        die(`complet produit à ${chaine.recent?.fichiers ?? "absent"} fichier(s) : la console l'a déclaré sans le vérifier`, resultat);
    }
    if (!(chaine.fichiers > 0)) die(`chaîne sauvegardée vide (${chaine.fichiers ?? "absent"} fichier au complet) : rien à restaurer`, resultat);
    // « verification.passed » est le contrôle que la console fait ELLE-MÊME après
    // envoi (méthode « native », mesuré) : faux veut dire archive écrite mais non
    // relue, donc à ne pas considérer comme récupérable.
    if (!chaine.verification) die("un maillon n'a pas passé le contrôle post-envoi de la console", resultat);
    say("  · intégrité : chaque maillon a passé le contrôle post-envoi de la console");
    if (chaine.type === "incremental" && (chaine.recent?.fichiers ?? 0) === 0) {
        say(`  · sauvegarde prouvée pour « ${JOB_NAME} » (aucun changement depuis le complet, incrémental vide normal).`);
    } else {
        say(`  · sauvegarde prouvée non vide pour « ${JOB_NAME} ».`);
    }
}

principale().catch((e) => die(e?.message ?? String(e)));

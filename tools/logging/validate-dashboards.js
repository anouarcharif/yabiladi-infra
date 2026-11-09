// Balayage des requêtes de tous les tableaux provisionnés, par le chemin réel
// des panneaux : POST /api/ds/query sur Grafana. La source de données, son UID
// provisionné et la substitution des variables sont donc testés avec eux — un
// JSON de tableau qui « passe » en LogQL mais dont la source n'existe pas ne
// tromperait pas ce contrôle.
//
// Chaque expression est classée : renseignée / valide mais vide / refusée. Une
// expression vide n'est pas un échec : le panneau n'affichera rien tant que la
// mesure n'existe pas sur la fenêtre (aucun auditeur radio, aucun envoi d'e-mail,
// aucune erreur Traefik hors incident). C'est cette liste qu'il faut lire avant
// d'écrire dans docs/logging/README.md (§8.1) qu'un tableau est validé.
//
// Les variables sont remplacées par la valeur que l'UI leur donne à l'ouverture
// du tableau : « All » -> allValue (la règle de la maison est ".+" : Loki refuse
// un matcher qui accepte la chaîne vide), sinon la valeur « current ». Les
// macros Grafana prennent la fenêtre par défaut et le pas de 60 s.
//
// Trois règles de payload, mesurées le 2026-11-04, sans lesquelles le harnais
// invente des pannes :
//   - « queryType » doit suivre le panneau : avec « instant: true » mais sans
//     « queryType: "instant" », Loki rejoue la requête en plage sur toute la
//     fenêtre et la refuse en 400 « maximum number of series (200) reached »
//     (le plafond vient de max_query_series dans docker/loki/config.yaml) ;
//   - « query » ET « expr » portent le même texte : un payload qui n'envoie que
//     « query » arrive vide chez Loki (« syntax error: unexpected $end »), ce
//     qui ressemble à une LogQL invalide ;
//   - « $__rate_interval » vaut 4 m ici (pas de 60 s, scrape à 30 s), jamais 1 m :
//     avec une minute, le panneau « CPU des conteneurs » oscillait entre 3, 1 et
//     0 séries sans que la machine change rien.
//
// Le rythme compte : 400 ms entre chaque appel. Ce n'est pas une précaution
// contre le verrou d'authentification — mesuré le 2026-11-04, 40 appels
// rapprochés AVEC la bonne valeur passent tous en 200 ; ce sont les échecs qui
// verrouillent (25 appels avec une valeur invalide suffisent : la bonne valeur
// répond alors 401 « password-auth.failed » pendant 301 s, cinq minutes). La
// respiration garde simplement le balayage doux pour Grafana, Loki et Prometheus :
// 203 requêtes d'affilée sur un poste mutualisé, c'est une charge comme une autre.
// Si le balayage s'ouvre par 401 partout, lire d'abord §5.3 du README : c'est le
// verrou, pas une source mal provisionnée.
//
// Le fichier de secret est lu, jamais reçu en argument (il ne doit pas passer
// par la ligne de commande ni s'afficher). Écrit sous Windows, il se termine par
// un CR seul : tout caractère de fin de ligne doit sauter, sinon le mot de passe
// part avec ce CR et Grafana répond 401 comme si la valeur était fausse.
//
// Usage :
//   node tools/logging/validate-dashboards.js [dossier|tous]
//   GRAFANA=http://127.0.0.1:8088 GRAFANA_USER=yabiladi node tools/logging/validate-dashboards.js radio
//
// Sur une machine sans Node (le serveur de production), la même lecture se fait
// dans un conteneur, posé sur le réseau « logging » pour joindre Grafana par son
// nom de service, avec deux montages en lecture seule : les scripts d'une part,
// les tableaux et le secret d'autre part. REPO_ROOT désigne alors la racine
// reconstruite par ces montages :
//   docker run --rm --network yabiladi_logging \
//     -v "$PWD/tools":/tools:ro \
//     -v "$PWD/docker/grafana":/dashboards/docker/grafana:ro \
//     -e REPO_ROOT=/dashboards -e GRAFANA=http://grafana:3000 \
//     node:24-alpine sh -c 'node /tools/logging/validate-dashboards.js tous'
// Le secret n'est jamais passé en argument ni affiché : le script le lit du
// fichier, comme les panneaux lisent Grafana.
//
// Les dossiers du dépôt sont general | applications | infrastructure |
// backups-batchs | radio.

const fs = require('fs');
const path = require('path');

const root = process.env.REPO_ROOT || path.resolve(__dirname, '../..');
const FILTRE = process.argv[2] || 'tous';
const GRAFANA = process.env.GRAFANA || `http://127.0.0.1:${process.env.GRAFANA_HTTP_PORT || 8088}`;
const USER = process.env.GRAFANA_USER || 'yabiladi';
const dir = path.join(root, 'docker/grafana/dashboards');
const secretFile = path.join(root, 'docker/grafana/secrets/admin_password');

if (!fs.existsSync(secretFile)) {
  console.error('Secret introuvable : ' + secretFile + ' (§5.2, reposé par tools/logging/bootstrap-grafana-admin.sh)');
  process.exit(1);
}
const pass = fs.readFileSync(secretFile, 'utf8').replace(/[\r\n]/g, '');
const b64 = Buffer.from(USER + ':' + pass).toString('base64');

function variables(dash) {
  const v = {};
  for (const t of (dash.templating || { list: [] }).list || []) {
    const many = t.type === 'query' && (t.multi || t.includeAll);
    v['$' + t.name] = many ? (t.allValue || '.+') : String((t.current && t.current.value) || (t.query && typeof t.query === 'string' ? t.query : '') || '');
  }
  return v;
}

function subst(expr, vars) {
  let e = expr || '';
  for (const [k, val] of Object.entries(vars)) e = e.split(k).join(val);
  e = e.split('$__rate_interval').join('4m');
  // Fenêtre de la requête : 6 h, la plus large des fenêtres par défaut des
  // tableaux (6 h pour « Docker et système », 3 h pour les radio) — donc le cas
  // le plus coûteux.
  e = e.split('$__range').join('6h');
  // « $__auto » (intervalle calculé par Grafana) : 5 m, valeur de confort pour un
  // balayage ; le panneau, lui, prend le pas adapté à la fenêtre affichée.
  e = e.split('$__auto').join('5m');
  e = e.split('$__interval_ms').join('60000');
  e = e.split('$__interval').join('1m');
  return e;
}

const tableaux = [];
const sautes = [];
for (const dossier of fs.readdirSync(dir)) {
  if (FILTRE !== 'tous' && dossier !== FILTRE) continue;
  for (const fichier of fs.readdirSync(path.join(dir, dossier))) {
    if (!fichier.endsWith('.json')) continue;
    const dash = JSON.parse(fs.readFileSync(path.join(dir, dossier, fichier), 'utf8'));
    const vars = variables(dash);
    const cibles = [];
    (function walk(panels, parent) {
      for (const p of panels || []) {
        const dsPanel = p.datasource || {};
        for (const t of p.targets || []) {
          if (!t.expr) continue;
          const ds = t.datasource || dsPanel;
          const expr = subst(t.expr, vars);
          if (/\$\w/.test(expr)) {
            sautes.push({ panel: (parent ? parent + ' / ' : '') + (p.title || p.type), refId: t.refId, expr: t.expr });
            continue; // variable sans valeur de repli : à compter à la main
          }
          cibles.push({
            panel: (parent ? parent + ' / ' : '') + (p.title || p.type),
            refId: t.refId,
            type: ds.type || 'loki',
            uid: ds.uid || 'yabiladi-loki',
            instant: t.queryType === 'instant' || t.instant === true,
            expr,
          });
        }
        if (p.panels) walk(p.panels, p.title || parent);
      }
    })(dash.panels, null);
    tableaux.push({ nom: `${dossier}/${fichier}`, uid: dash.uid, vars, cibles });
  }
}

async function jouer(c) {
  const r = await fetch(GRAFANA + '/api/ds/query', {
    method: 'POST',
    headers: { Authorization: 'Basic ' + b64, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      queries: [
        c.type === 'prometheus'
          ? { refId: c.refId, datasource: { uid: c.uid, type: 'prometheus' }, type: 'prometheus', expr: c.expr, intervalMs: 60000, step: '60', instant: true, range: false, hide: false }
          : { refId: c.refId, datasource: { uid: c.uid, type: 'loki' }, query: c.expr, expr: c.expr, maxLines: 5, intervalMs: 60000, step: '60', instant: c.instant, range: !c.instant, queryType: c.instant ? 'instant' : 'range', hiding: false },
      ],
      from: 'now-6h', to: 'now',
    }),
  });
  const txt = await r.text();
  let j = null; try { j = JSON.parse(txt); } catch {}
  if (!r.ok) return { err: r.status + ' ' + String((j && (j.message || j.error)) || txt.slice(0, 140)).replace(/\s+/g, ' ') };
  const first = (j.results || {})[c.refId] || Object.values(j.results || {})[0] || {};
  if (first.error) return { err: String(first.error.message || JSON.stringify(first.error)).slice(0, 140).replace(/\s+/g, ' ') };
  const frames = first.frames || [];
  // Une série = une frame : compter sur toutes les frames, pas la première, sinon
  // « 22 conteneurs » se lit comme un seul et le harnais sous-déclare ce que le
  // panneau affiche vraiment.
  const n = frames.reduce((k, f) => k + (f.data?.values?.[0] ? f.data.values[0].length : 0), 0);
  return { n };
}

(async () => {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  let ok = 0, vide = 0, refuse = 0;
  for (const t of tableaux) {
    let a = 0, b = 0, c = 0;
    for (const cible of t.cibles) {
      const out = await jouer(cible);
      await wait(400);
      if (out.err) {
        c++;
        console.log('  REFUSÉE ' + cible.panel + ' (' + cible.refId + ') : ' + out.err + '\n          ' + cible.expr.slice(0, 150));
      } else if (out.n === 0) {
        b++;
        console.log('  vide    ' + cible.panel + ' (' + cible.refId + ')');
      } else a++;
    }
    ok += a; vide += b; refuse += c;
    console.log(t.nom + ' : ' + t.cibles.length + ' expressions -> renseignées ' + a + ', vides ' + b + ', refusées ' + c);
  }
  console.log('\nTOTAL ' + (ok + vide + refuse) + ' expressions rejouées (' + tableaux.length + ' tableaux, via ' + GRAFANA + ') : renseignées ' + ok + ', vides ' + vide + ', refusées ' + refuse);
  console.log('non rejouées (' + sautes.length + ', variable sans valeur de repli) :');
  for (const s of sautes) console.log('  ' + s.panel + ' (' + s.refId + ') ' + s.expr.slice(0, 130));
})();

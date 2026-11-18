# Base « trixie » depuis le 2026-11-18, pour arriver en production sur la
# dernière version stable. La montée a été répétée sur CE code dans des
# conteneurs jetables (réseau, filet SMTP, clé DKIM et tas persistants
# rejoués d'une image à l'autre), jamais déduite d'une note amont. Mesuré :
#   - « apt-get download postfix » sur debian:trixie-slim rend 3.10.13-0+deb13u1.
#     bookworm-backports plafonne à 3.10.3-2~bpo12+1 et seul le dépôt instable
#     porte 3.11.7 : la dernière version STABLE Debian est 3.10.13.
#   - opendkim reste packagé en trixie (2.11.0~beta2-9.1) : la liste
#     « apt-get install » ci-dessous ne change pas d'un paquet, et la contrainte
#     mesurée sur ce 2.11.0 (« InternalHosts » en FICHIER, la forme en ligne
#     étant refusée à l'analyse) tient toujours — voir opendkim.conf.
#   - trois défauts changent vraiment de comportement entre 3.7.11 et 3.10.13, et
#     « compatibility_level = 3.6 » ne les garde PAS (lus au « postconf » des
#     deux images, gabarit rendu à l'appui) : milter_default_action
#     (tempfail → shutdown), smtpd_forbid_bare_newline (no → normalize),
#     smtpd_forbid_unauth_pipelining (no → yes). Le premier est épinglé dans
#     main.cf parce qu'il regarde la panne d'OpenDKIM ; les deux autres restent à
#     leur nouvelle valeur, la répétition ayant rendu le même transcript des deux
#     côtés (corps en LF seuls accepté, remis et signé ; rafale pipelinée
#     « 250 250 354 » ; et le 554 d'un client hors mynetworks décroché de
#     l'une comme de l'autre). Les deux défauts TLS qui bougent aussi
#     (smtp_tls_dane_insecure_mx_policy, smtp_tls_enforce_sts_mx_patterns) sont
#     inertes ici : le niveau est « may » et « smtp_tls_policy_maps » reste vide.
#   - les comptes internes bougent, eux : uid postfix = 101 sur les deux bases,
#     mais les gid glissent (postfix 103 → 102, postdrop 104 → 103, opendkim
#     102 → 101) et /var/spool/postfix/public passe de drwx--s--- à drwx--x---.
#     C'est exactement ce que répare l'ordre « set-permissions » avant « check »
#     de l'entrypoint : mesuré sur le volume écrit par 3.7, le premier démarrage
#     en 3.10 rend « maildrop » et « public » à leurs propriétaires du jour, et
#     « postfix check » garde le code de sortie 0 SANS AUCUNE ligne — sur les
#     deux images, tas neuf comme tas hérité. Le seul bruit cosmétique venu d'un
#     démarrage est « warning: /var/spool/postfix/etc/services and /etc/services
#     differ » : trois fois par passe sur l'image bookworm, zéro fois sur
#     l'image trixie. C'est une copie périmée dans un tas qui n'utilise aucun
#     chroot, et hors ces lignes le journal des deux passes ne contient ni
#     « fatal », ni « error », ni « panic ».
#   - un tas créé par l'une des deux images démarre, signe et remet avec
#     l'autre, et cela a été joué dans les DEUX sens sur le même volume : le
#     message accepté puis différé par 3.7 est repris par 3.10 (« reste au tas :
#     1, dont 1 en differe » → « recus a la reprise : 1 », 716 octets au filet,
#     « bh= » et « b= » vérifiés RSA-SHA256 valides — donc la signature apposée
#     par l'ancienne image tient après le changement), et le message différé par
#     3.10 est repris par 3.7 avec le même contenu et la même vérification.
#     « healthy », /run/opendkim.state « on » et « postfix check » à 0 dans les
#     deux cas. La montée n'impose donc pas un tas neuf, et le retour à l'image
#     bookworm reste jouable tel quel.
#   - le transcript des deux passes est identique ligne à ligne, à trois
#     exceptions près et toutes expliquées : les 3 lignes « etc/services »
#     ci-dessus, le décalage du compteur de messages (la seconde passe reçoit le
#     message hérité en plus), et 2 à 3 octets sur les messages du filet —
#     uniquement le nom du conteneur client, le « qid » et l'horodatage du
#     « Received: » ; mêmes en-têtes, même « bh= » pour un même corps.
#
# Contrepartie assumée : le socle du conteneur n'est plus celui de la machine
# (imouzzer est en Debian 12). Les paquets de l'hôte ne dépendent pas de cette
# base : c'est le principe du conteneur.
#
# Copie croisée avec Yabiladi-Postfix-Primary/docker/postfix/Dockerfile (la
# machine tarourt) : « ./deploy.sh --check-sync » compare le CODE, commentaires
# retirés, des cinq fichiers des deux dossiers. Ce qui diffère volontairement
# d'un dépôt à l'autre tient en trois valeurs : le sélecteur DKIM
# (« mail » ici, « mail2 » sur tarourt), le HELO de repli et le message d'alerte
# sans clé.
FROM debian:trixie-slim
# Postfix et OpenDKIM ne doivent pas démarrer pendant la construction de
# l'image : policy-rc.d répond 101 à invoke-rc.d, et debconf fixe le type de
# site sans dialogue.
#
# OpenDKIM est ici parce que le relais signe lui-même. C'est le rôle qu'il
# jouait à côté du Postfix Debian : il couvre tout ce qui passe par le serveur,
# y compris le courrier qui ne vient pas de l'application Symfony (le V1 de
# l'autre machine, les shells de l'hôte), là où le signer de Symfony ne couvre
# que ses propres messages.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && printf '%s\n' \
        'postfix postfix/main_mailer_type select No configuration' \
        'postfix postfix/mailname string localhost' \
        | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends postfix opendkim ca-certificates gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d

COPY main.cf /etc/postfix/main.cf.template
COPY opendkim.conf /etc/opendkim.conf.template
COPY entrypoint.sh healthcheck.sh /usr/local/bin/

# L'image Debian slim exclut les pages de manuel : « postfix check » puis
# « postfix set-permissions » échouent sur chaque entrée $manpage_directory de
# postfix-files. Ces entrées ne décrivent que des fichiers absents.
# Ce retrait est encore requis en trixie, et cela a été mesuré plutôt que
# supposé : une image trixie construite sans le « sed » rend « postfix
# set-permissions » en échec sur « chown: cannot access
# '/usr/share/man/man1/mailq.1.gz' », avec 74 entrées de manpage listées dans
# /etc/postfix/postfix-files. L'ordre « set-permissions » avant « check » de
# l'entrypoint ne change rien à cette exclusion : c'est le fichier de liste
# qu'il faut corriger, pas l'ordre.
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
    && sed -i '/^\$manpage_directory\//d' /etc/postfix/postfix-files

# Nom HELO du relais : il doit correspondre au PTR de l'IP qui sort. Depuis que
# le Postfix Debian de tarourt est retiré, le relais vit sur imouzzer, dont
# l'IP primaire 57.128.22.216 a précisément ce nom pour PTR (mesuré), et cette
# IP est déjà publiée au SPF sous « a:imouzzer » et « ip4:57.128.22.216 » :
# aucun enregistrement DNS n'est à créer. L'IP sortante n'est pas épinglée dans
# le conteneur (voir main.cf) : c'est celle de la machine hôte.
#
# Ces valeurs ne sont qu'un repli pour un « docker run » nu : ce qui s'applique
# réellement vient du .env versionné, lu par compose.yaml.
ENV POSTFIX_MYHOSTNAME=imouzzer.yabiladi.com \
    POSTFIX_RELAY_NETWORKS="" \
    OPENDKIM_DOMAIN=yabiladi.com \
    OPENDKIM_SELECTOR=mail

EXPOSE 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM debian:bookworm-slim

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

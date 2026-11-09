FROM debian:bookworm-slim

# Postfix ne doit pas démarrer pendant la construction de l'image : policy-rc.d
# répond 101 à invoke-rc.d, et debconf fixe le type de site sans dialogue.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && printf '%s\n' \
        'postfix postfix/main_mailer_type select No configuration' \
        'postfix postfix/mailname string localhost' \
        | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends postfix ca-certificates gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d

COPY main.cf /etc/postfix/main.cf.template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# L'image Debian slim exclut les pages de manuel : « postfix check » puis
# « postfix set-permissions » échouent sur chaque entrée $manpage_directory de
# postfix-files. Ces entrées ne décrivent que des fichiers absents.
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && sed -i '/^\$manpage_directory\//d' /etc/postfix/postfix-files

# Nom HELO du relais : il doit résoudre (A) vers l'IP publique du serveur et
# correspondre à son PTR. C'est le nom du serveur de production qui héberge le
# V1 et son Postfix (PTR tarourt.yabiladi.com) : le relais s'annonce donc sous
# le même nom que lui, sans enregistrement DNS à créer ni à modifier. Un
# déploiement sur une autre machine surcharge POSTFIX_MYHOSTNAME dans son
# compose.override.yaml (fichier non versionné).
ENV POSTFIX_MYHOSTNAME=tarourt.yabiladi.com

EXPOSE 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

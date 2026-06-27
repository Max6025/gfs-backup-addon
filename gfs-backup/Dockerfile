ARG BUILD_FROM
FROM ${BUILD_FROM}

ENV LANG C.UTF-8

# samba-client für Netzwerkfreigaben, jq für JSON-Parsing, coreutils für Zeitfunktionen
RUN apk add --no-cache \
    samba-client \
    jq \
    coreutils \
    tzdata \
    curl \
    bash

COPY run.sh /
COPY gfs_backup.sh /

RUN chmod a+x /run.sh /gfs_backup.sh

CMD [ "/run.sh" ]

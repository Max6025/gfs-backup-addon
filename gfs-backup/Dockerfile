ARG BUILD_FROM
FROM ${BUILD_FROM}

ENV LANG C.UTF-8

RUN apk add --no-cache \
    samba-client \
    python3 \
    coreutils \
    tzdata \
    curl \
    bash

COPY run.sh /
COPY gfs_backup.sh /
COPY server.py /

RUN chmod a+x /run.sh /gfs_backup.sh

CMD [ "/run.sh" ]

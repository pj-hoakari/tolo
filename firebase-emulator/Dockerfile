FROM node:24-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20

RUN apt-get update \
 && apt-get install -y --no-install-recommends wget gnupg ca-certificates \
 && mkdir -p /etc/apt/keyrings \
 && wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo $VERSION_CODENAME) main" \
      > /etc/apt/sources.list.d/adoptium.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends temurin-21-jre \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g firebase-tools

WORKDIR /srv

RUN firebase setup:emulators:firestore \
 && firebase setup:emulators:ui

COPY firebase.json firestore.rules ./

EXPOSE 4000 4400 4500 8080 9099

CMD ["firebase", "emulators:start", "--project", "demo-tolo"]

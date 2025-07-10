FROM cm2network/steamcmd:root

USER root
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y \
     lib32gcc-s1 lib32stdc++6 \
     default-jre-headless \
     unzip wget git pv screen \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash pz

USER pz
WORKDIR /home/pz

RUN mkdir -p /home/pz/pz \
 && /home/steam/steamcmd/steamcmd.sh \
      +force_install_dir /home/pz/pz \
      +login anonymous \
      +app_update 380870 validate \
      +quit

COPY --chown=pz:pz entrypoint.sh /home/pz/entrypoint.sh
RUN chmod +x /home/pz/entrypoint.sh

EXPOSE 16261/udp 16262/udp

ENTRYPOINT ["/home/pz/entrypoint.sh"]


ARG charge_lnd_tag=v0.2.8
ARG lntop_commit=a05908a
ARG rebalance_lnd_tag=v2.1
ARG suez_commit=335d430
ARG ttyd_tag=1.6.3

FROM golang:1.17-bullseye AS builder

ARG arch

WORKDIR /build

RUN apt-get update && apt-get install -y build-essential cmake curl git gnupg libjson-c-dev libwebsockets-dev python3 python3-venv

# getting lnd
ARG lnd_version
RUN curl -sSL -o /build/lnd-linux-${arch}-${lnd_version}.tar.gz https://github.com/lightningnetwork/lnd/releases/download/${lnd_version}/lnd-linux-${arch}-${lnd_version}.tar.gz
RUN curl -sSL -o /build/manifest-guggero-${lnd_version}.sig https://github.com/lightningnetwork/lnd/releases/download/${lnd_version}/manifest-guggero-${lnd_version}.sig
RUN curl -sSL -o /build/manifest-${lnd_version}.txt https://github.com/lightningnetwork/lnd/releases/download/${lnd_version}/manifest-${lnd_version}.txt
RUN curl https://raw.githubusercontent.com/lightningnetwork/lnd/master/scripts/keys/guggero.asc | gpg --import
RUN cd /build && gpg --verify manifest-guggero-${lnd_version}.sig manifest-${lnd_version}.txt && tar xzf lnd-linux-${arch}-${lnd_version}.tar.gz && mv lnd-linux-${arch}-${lnd_version} /lnd

#####

# building lntop
ARG lntop_commit
RUN cd /build && git clone https://github.com/edouardparis/lntop.git && cd lntop && git checkout ${lntop_commit}
ENV GOARCH=${arch}
ENV GOOS=linux
RUN cd /build/lntop && mkdir bin && go build -o bin/lntop cmd/lntop/main.go

# extracting suez requirements
ARG suez_commit
RUN curl -sSL https://raw.githubusercontent.com/python-poetry/poetry/master/install-poetry.py | python3 -
RUN cd /build && git clone https://github.com/prusnak/suez.git && cd suez && git checkout ${suez_commit} && /root/.local/bin/poetry export -f requirements.txt --output requirements.txt --without-hashes

# building ttyd
ARG ttyd_tag
RUN cd /build && git clone --depth 1 --branch ${ttyd_tag} https://github.com/tsl0922/ttyd.git
RUN cd /build/ttyd && mkdir build && cmake . && make

FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y git procps python3 python3-pip screen sysstat tini vim nano micro

ARG charge_lnd_tag
RUN git clone --depth 1 --branch ${charge_lnd_tag} https://github.com/accumulator/charge-lnd.git /charge-lnd
RUN cd /charge-lnd && pip3 install -r requirements.txt
RUN cd /charge-lnd && python3 setup.py install
RUN rm -rf /charge-lnd

ARG rebalance_lnd_tag
RUN git clone --depth 1 --branch ${rebalance_lnd_tag} https://github.com/C-Otto/rebalance-lnd.git /rebalance-lnd
RUN cd /rebalance-lnd && pip3 install -r requirements.txt

ARG suez_commit
RUN git clone https://github.com/prusnak/suez.git /suez && cd /suez && git checkout ${suez_commit}
COPY --from=builder /build/suez/requirements.txt /suez/requirements.txt
RUN pip3 install -r /suez/requirements.txt

COPY --from=builder /lnd/lncli /bin/
COPY --from=builder /build/lntop/bin/lntop /bin/
COPY --from=builder /build/ttyd /bin/
COPY motd /etc/motd

RUN groupadd -r lnshell --gid=1000 && useradd -r -g lnshell --uid=1000 --create-home --shell /bin/bash lnshell

USER lnshell
WORKDIR /home/lnshell

ARG version
RUN mkdir -p /home/lnshell/.local/bin
COPY --chown=lnshell:lnshell bin/* /home/lnshell/.local/bin/
RUN cd /home/lnshell/.local/bin/ && chmod o+x *
RUN echo "PATH=~/.local/bin:$PATH; export PATH" >> /home/lnshell/.bashrc
RUN echo "cat /etc/motd" >> /home/lnshell/.bashrc
RUN echo "${version}" > /home/lnshell/.lnshell-version

EXPOSE 7681

ENV APP_PASSWORD=

ENTRYPOINT /usr/bin/tini /bin/ttyd -- --credential umbrel:${APP_PASSWORD} bash

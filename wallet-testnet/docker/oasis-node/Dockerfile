FROM ubuntu:focal

RUN apt-get update && apt-get install --no-install-recommends -y apt-transport-https wget ca-certificates && rm -rf /var/lib/apt/lists/*
RUN wget -q -O oasis.tar.gz https://github.com/oasisprotocol/oasis-core/releases/download/v22.2.3/oasis_core_22.2.3_linux_amd64.tar.gz
RUN tar -xvzf oasis.tar.gz
RUN cp oasis_core_22.2.3_linux_amd64/oasis-node /usr/local/bin && chmod +x /usr/local/bin/oasis-node
# COPY oasis-node /usr/local/bin
# RUN chmod +x /usr/local/bin/oasis-node
# RUN mkdir -p /node/data && chmod 700 /node/data

CMD cp /init_node/* /node/data || true && \
    chmod -R 700 /node/data && \
    chmod -R 600 /node/data/*.pem && \
    rm -fr /node/data/internal.sock || true && \
    /usr/local/bin/oasis-node --config /node/etc/config.yml \
        --debug.dont_blame_oasis \
        --debug.allow_test_keys

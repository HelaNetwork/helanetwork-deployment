FROM docker.io/library/golang:1.18 AS build-env
WORKDIR /app

# ARG COMMIT="2861780b1dcc9ea6d876621ad059cea6dcd77955"
ARG COMMIT="74acf45b68a6b3ec309691e16a375e499a8f2f88"


# Fetch and build oasis-core-rosetta-gateway.
RUN git clone https://github.com/everstake/oasis-explorer.git /app &&  \
    git checkout $COMMIT

ENV CGO_ENABLED 0
RUN go build

# FROM docker.io/library/alpine:3.17.1
FROM ubuntu:focal
RUN apt-get update
RUN apt-get install -y ca-certificates
RUN update-ca-certificates
# RUN echo "nameserver 8.8.8.8" > /etc/resolv.conf && apt update
# RUN apk update && apk add ca-certificates
# RUN update-ca-certificates
# RUN apk add --no-cache ca-certificates
COPY --from=build-env /app/oasisTracker /oasisTracker
COPY --from=build-env app/dao/postgres/migrations /dao/postgres/migrations
COPY --from=build-env app/dao/clickhouse/migrations /dao/clickhouse/migrations

CMD ["/oasisTracker"]

FROM golang:1.25.5-alpine AS build

ARG BUILDTIME=no-buildtime
ARG VERSION=local-dev
ARG REVISION=no-revision

WORKDIR /app

COPY go.mod ./
COPY go.sum ./

RUN go mod download

COPY . ./

RUN go build -o /semgrep-network-broker -ldflags="-X 'github.com/semgrep/semgrep-network-broker/build.BuildTime=${BUILDTIME}' -X 'github.com/semgrep/semgrep-network-broker/build.Version=${VERSION}' -X 'github.com/semgrep/semgrep-network-broker/build.Revision=${REVISION}'"

FROM alpine:3.23

RUN apk add --no-cache curl ca-certificates
RUN adduser -D semgrep

COPY --from=build /semgrep-network-broker /usr/bin/semgrep-network-broker
COPY scripts/bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh

# Pre-create the bootstrap config dir owned by the runtime user so that a
# docker-managed named volume (or no mount at all) is writable out of the box.
# Bind mounts still need host-side chown — see README.
RUN mkdir -p /emt && chown semgrep:semgrep /emt

USER semgrep
WORKDIR /home/semgrep

ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]

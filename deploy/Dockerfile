FROM golang:1.27.4-alpine3.24 AS source
RUN apk add --no-cache ca-certificates tzdata
ENV TZ=Asia/Hong_Kong
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal

FROM source AS test
RUN apk add --no-cache build-base python3
COPY scripts ./scripts
COPY deploy ./deploy
CMD ["sh", "-c", "go test -race -count=1 ./... && go vet ./... && python3 scripts/test-ci.py"]

FROM source AS build
ENV CGO_ENABLED=0
RUN go test ./... && go vet ./...
ARG CHIRP_VERSION=0.14.0-dev
RUN go build -trimpath -ldflags "-X main.version=${CHIRP_VERSION}" -o /out/chirp ./cmd/chirp
RUN mkdir -p /runtime/data /runtime/app/log /runtime/var/lib/chirp-media && \
    chmod 700 /runtime/data /runtime/app/log /runtime/var/lib/chirp-media
COPY deploy/authorization-key.default /out/authorization-key.default
RUN chmod 0400 /out/authorization-key.default

FROM scratch AS app
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=source /usr/share/zoneinfo/Asia/Hong_Kong /usr/share/zoneinfo/Asia/Hong_Kong
COPY --from=source /usr/share/zoneinfo/Asia/Hong_Kong /etc/localtime
ENV TZ=Asia/Hong_Kong
COPY --from=build --chown=65532:65532 /runtime/ /
USER 65532:65532
COPY --from=build /out/chirp /usr/local/bin/chirp
ENV CHIRP_DATABASE_PATH=/data/chirp.db CHIRP_LISTEN_ADDR=0.0.0.0:18115
WORKDIR /app
EXPOSE 18115/tcp
ENTRYPOINT ["/usr/local/bin/chirp"]
CMD ["serve"]

FROM app AS public
LABEL org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.source="https://github.com/YouZiFeiLe/Chirp"
COPY LICENSE /usr/share/doc/chirp/LICENSE
# This is the published open-source seed paired with the bundled clients' trust resource.
COPY --from=build --chown=65532:65532 /out/authorization-key.default /usr/share/chirp/authorization-key.default

# syntax=docker/dockerfile:1
ARG GO_VERSION=1.27
FROM golang:${GO_VERSION}-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./

RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# *_test.go files are excluded by .dockerignore.
COPY *.go openapi.yaml ./

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/analytics-api .

FROM gcr.io/distroless/static-debian13:nonroot
LABEL org.opencontainers.image.source="https://github.com/mefranklin6/AV-System-Metrics"
LABEL org.opencontainers.image.description="AV-System-Metrics optional read-only Analytics API"

WORKDIR /app
COPY --from=build --chown=65532:65532 --chmod=0555 /out/analytics-api /app/analytics-api
USER 65532:65532
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 CMD ["/app/analytics-api", "healthcheck"]
ENTRYPOINT ["/app/analytics-api"]

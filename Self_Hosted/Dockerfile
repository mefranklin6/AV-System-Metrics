# syntax=docker/dockerfile:1
FROM golang:latest AS build

WORKDIR /src

COPY go.mod go.sum ./

RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY main.go schema.sql ./

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/metrics-ingest .

FROM gcr.io/distroless/static-debian13:nonroot 
LABEL org.opencontainers.image.source="https://github.com/mefranklin6/AV-System-Metrics"
LABEL org.opencontainers.image.description="AV-System-Metrics self-hosted metrics ingest service"

WORKDIR /app
COPY --from=build /out/metrics-ingest /app/metrics-ingest
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app/metrics-ingest"]

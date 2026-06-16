# syntax=docker/dockerfile:1
FROM golang:latest AS build

WORKDIR /src

COPY . .

# Run tidy and build using Go cache mounts to keep it fast
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/metrics-ingest .

FROM gcr.io/distroless/static-debian13:nonroot 
WORKDIR /app
COPY --from=build /out/metrics-ingest /app/metrics-ingest
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app/metrics-ingest"]
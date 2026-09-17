# What I did change in the Dockerfile: 
# - I replaced the base images with their respective SHA256 digests for better security (e.g. Supply chain attack mitigation) and reproducibility.
# - I moved from "Copy .." to explicit copying of necessary files and directories. This avoides unnecessary files being included in the final image.
# - I have added the wizexercise.txt to the image and verifed its existence in the running container.
# - I have added a non-root user to run the application for better security.
# - I have added a health check to ensure the application is running correctly.
# - I moved to Chainguard base images for both build and release stages for better security and reproducibility.

# What Could be improved (something I might add into my story):
# re-org the project strcture to reduce image layers cuased by COPY command


# Public Chainguard images, pinned to immutable multi-platform digests.
FROM cgr.dev/chainguard/go:latest@sha256:e69d8becae614abc5037093bead1f40bd031dd3483657f0cbeaa7e2c9e044a66 AS build
ARG TARGETARCH

WORKDIR /go/src/tasky
COPY go.mod go.sum main.go wizexercise.txt ./
COPY assets ./assets
COPY auth ./auth
COPY controllers ./controllers
COPY models ./models
COPY database ./database
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -o /go/src/tasky/tasky


FROM cgr.dev/chainguard/wolfi-base:latest@sha256:1d95114038f76513a9ace6fca107d5582b08c65981f81f61cb56bf7fd2ef216d AS release

WORKDIR /app
COPY --from=build  /go/src/tasky/tasky .
COPY --from=build  /go/src/tasky/assets ./assets
COPY --from=build  /go/src/tasky/wizexercise.txt .
EXPOSE 8080

# Explicit IDs make permissions predictable and help Kubernetes enforce non-root execution.
RUN addgroup -S -g 10001 app \
    && adduser -S -u 10001 -G app app
USER 10001:10001

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q --spider -T 2 http://localhost:8080/ || exit 1

ENTRYPOINT ["/app/tasky"]


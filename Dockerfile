# What I did change in the Dockerfile: 
# - I replaced the base images with their respective SHA256 digests for better security (e.g. Supply chain attack mitigation) and reproducibility.
# - I moved from "Copy .." to explicit copying of necessary files and directories. This avoides unnecessary files being included in the final image.
# - I have added the wizexercise.txt to the image and verifed its existence in the running container.
# - I have added a non-root user to run the application for better security.
# - I have added a health check to ensure the application is running correctly.

# What Could be improved (something I might add into my story):
# move to distroless / hardened images to further reduce the attack surface and improve security.
# re-org the project strcture to reduce image layers cuased by COPY command


FROM golang:1.19@sha256:8f60d15fe7449b4d74ce54ba87ca912e09f9e05daa804f4d69a0c7b35f9e98b1 AS build

WORKDIR /go/src/tasky
COPY go.mod go.sum main.go wizexercise.txt ./
COPY assets ./assets
COPY auth ./auth
COPY controllers ./controllers
COPY models ./models
COPY database ./database
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /go/src/tasky/tasky


FROM alpine:3.17.0@sha256:af6a986619d570c975f9a85b463f4aa866da44c70427e1ead1fd1efdf6150d38 as release

WORKDIR /app
COPY --from=build  /go/src/tasky/tasky .
COPY --from=build  /go/src/tasky/assets ./assets
COPY --from=build  /go/src/tasky/wizexercise.txt .
EXPOSE 8080

RUN addgroup -S app && adduser -S app -G app
USER app

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1

ENTRYPOINT ["/app/tasky"]



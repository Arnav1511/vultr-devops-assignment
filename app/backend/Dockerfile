# syntax=docker/dockerfile:1

# --- build stage -------------------------------------------------------------
# $BUILDPLATFORM pins this stage to the CI runner's native architecture. Go then
# cross-compiles to $TARGETARCH itself, so the arm64 image is built without
# QEMU emulation — minutes faster than emulating the whole compiler.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src

# Copy go.mod first so the dependency layer stays cached until dependencies
# change, rather than being rebuilt on every source edit.
COPY go.mod ./
RUN go mod download
COPY . .

# CGO_ENABLED=0 -> fully static binary with no libc dependency, which is what
#                  allows the final stage to be `scratch`.
# -trimpath     -> no local build paths in the binary (reproducible builds).
# -s -w         -> strip symbol and debug tables to shrink the binary.
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/server .

# --- runtime stage -----------------------------------------------------------
# scratch: no shell, no package manager, no OS packages. Nothing for Trivy to
# flag and nothing for an attacker to use. Rejected alternative: distroless
# static, which adds CA certificates and tzdata this service does not need yet.
FROM scratch
COPY --from=build /out/server /server

# Numeric UID, not a name: scratch has no /etc/passwd, and Kubernetes can only
# verify runAsNonRoot against a numeric user.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/server"]

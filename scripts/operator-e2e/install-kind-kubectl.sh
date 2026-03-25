#!/usr/bin/env bash
# Install kind and kubectl into /usr/local/bin (requires sudo). Used by GitHub Actions prep.
# Env: KIND_VERSION (default 0.31.0), KUBECTL_VERSION (default 1.35.2), ARCH (default amd64).
set -euo pipefail

KIND_VERSION="${KIND_VERSION:-0.31.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.35.2}"
ARCH="${ARCH:-amd64}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL -o "$tmpdir/kind" "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x "$tmpdir/kind"
sudo mv "$tmpdir/kind" /usr/local/bin/kind

curl -fsSL -o "$tmpdir/kubectl" "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
chmod +x "$tmpdir/kubectl"
sudo mv "$tmpdir/kubectl" /usr/local/bin/kubectl

kind version
kubectl version --client=true

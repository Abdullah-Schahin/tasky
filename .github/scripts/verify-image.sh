#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE:?Digest-qualified image required}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_SERVER_URL:?}"
: "${RUNNER_TEMP:?}"
[[ "$IMAGE" =~ @sha256:[a-f0-9]{64}$ ]] || { echo "A SHA256 image digest is required" >&2; exit 1; }
identity="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/.github/workflows/app-ci-cd.yaml@refs/heads/main"
flags=(--certificate-identity "$identity"
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
  --certificate-github-workflow-sha "$GITHUB_SHA")
cosign verify "${flags[@]}" "$IMAGE" > "$RUNNER_TEMP/verified-signature.json"
cosign verify-attestation "${flags[@]}" --type spdxjson "$IMAGE" > "$RUNNER_TEMP/verified-sbom.json"
cosign verify-attestation "${flags[@]}" --type slsaprovenance1 "$IMAGE" > "$RUNNER_TEMP/verified-provenance.json"
# Inspect only payloads that passed cryptographic verification above.
jq -es --arg source "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" --arg sha "$GITHUB_SHA" --arg builder "$identity" '
  [ .[] | .payload | @base64d | fromjson | select(
    .predicateType == "https://slsa.dev/provenance/v1" and
    .predicate.runDetails.builder.id == $builder and
    .predicate.buildDefinition.externalParameters.ref == "refs/heads/main" and
    any(.predicate.buildDefinition.resolvedDependencies[];
      .uri == $source and .digest.gitCommit == $sha)
  ) ] | length > 0
' "$RUNNER_TEMP/verified-provenance.json" > /dev/null

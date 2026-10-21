#!/usr/bin/env bash

# Regression tests for optional cosign signing in cr.sh.
# Uses stubs for helm, gh, cosign and curl; no registry or network access.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CR="${SCRIPT_DIR}/../cr.sh"
WORK=$(mktemp -d)
trap 'if [[ "${KEEP:-0}" == "1" ]]; then echo "Kept test workspace: $WORK"; else rm -rf "$WORK"; fi' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

assert_contains() {
  local file="$1" needle="$2" message="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$message"
  else
    fail "$message (missing: $needle)"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" message="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$message (unexpected: $needle)"
  else
    pass "$message"
  fi
}

assert_executable() {
  local file="$1" message="$2"
  if [[ -x "$file" ]]; then
    pass "$message"
  else
    fail "$message (not executable: $file)"
  fi
}

STUBS="$WORK/bin"
REPO="$WORK/repo"
LOG="$WORK/stub.log"
OUT=""
mkdir -p "$STUBS" "$REPO/charts/demo"

cat >"$STUBS/helm" <<'STUB'
#!/usr/bin/env bash
echo "helm $*" >> "$STUB_LOG"
case "${1:-}" in
show)
  cat "${3}/Chart.yaml"
  ;;
package)
  src="${2:-}"
  shift 2
  dest=""
  while (($#)); do
    case "$1" in
    -d)
      dest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
    esac
  done
  mkdir -p "$dest"
  name=$(sed -n 's/^name: //p' "$src/Chart.yaml" | head -n1)
  version=$(sed -n 's/^version: //p' "$src/Chart.yaml" | head -n1)
  tar -czf "$dest/$name-$version.tgz" -C "$(dirname "$src")" "$(basename "$src")"
  ;;
registry)
  cat >/dev/null
  ;;
push)
  printf 'Pushed: registry.example.com/org/demo:1.0.0\n'
  printf 'Digest: sha256:1111111111111111111111111111111111111111111111111111111111111111\n'
  ;;
esac
STUB

cat >"$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "${1:-}" in
release)
  case "${2:-}" in
  ls) printf 'TITLE\tTYPE\tTAG NAME\n' ;;
  esac
  ;;
api)
  if [[ -n "${STUB_GH_DIGEST:-}" ]]; then
    printf '%s\n' "$STUB_GH_DIGEST"
  fi
  ;;
esac
STUB

cat >"$STUBS/cosign" <<'STUB'
#!/usr/bin/env bash
echo "cosign $*" >> "$STUB_LOG"
case "${1:-}" in
login)
  cat >/dev/null
  ;;
sign)
  if [[ "${STUB_COSIGN_FAIL:-0}" == "1" ]]; then
    echo "simulated cosign failure" >&2
    exit 1
  fi
  ;;
esac
STUB

cat >"$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
out=""
while (($#)); do
  case "$1" in
  -o | -sSLo)
    out="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done
if [[ -n "$out" ]]; then
  mkdir -p "$(dirname "$out")"
  cp "$(dirname "$0")/cosign" "$out"
fi
STUB

chmod +x "$STUBS/helm" "$STUBS/gh" "$STUBS/cosign" "$STUBS/curl"

cd "$REPO"
git init -q
git config user.email test@example.com
git config user.name "Test User"
git commit -q --allow-empty -m "root"

cat >charts/demo/Chart.yaml <<'CHART'
apiVersion: v2
name: demo
description: Demo chart
type: application
version: 1.0.0
appVersion: "1.0"
CHART

cat >charts/demo/values.yaml <<'VALUES'
replicaCount: 1
VALUES

git add charts/demo
git commit -q -m "add demo chart"

run_case() {
  local name="$1"
  shift
  local install="$WORK/install-$name"
  : >"$LOG"
  OUT="$WORK/out-$name.log"

  set +e
  (
    cd "$REPO"
    env \
      PATH="$STUBS:$PATH" \
      GITHUB_TOKEN=test \
      OCI_PASSWORD=secret \
      STUB_LOG="$LOG" \
      STUB_GH_DIGEST="${STUB_GH_DIGEST:-}" \
      STUB_COSIGN_FAIL="${STUB_COSIGN_FAIL:-0}" \
      DRY_RUN="${DRY_RUN:-false}" \
      bash "$CR" --charts-dir charts --oci-registry registry.example.com/org \
        --oci-username user --install-dir "$install" --skip-helm-install true \
        --oci-tag-pattern '{version}' "$@"
  ) >"$OUT" 2>&1
  local status=$?
  set -e
  return "$status"
}

# 1. Signing disabled: no cosign invocation at all.
if run_case disabled --cosign-sign false --skip-cosign-install true; then
  pass "signing disabled run succeeds"
else
  fail "signing disabled run failed"
fi
assert_not_contains "$LOG" "cosign " "signing disabled does not invoke cosign"
assert_contains "$OUT" "Pushed: registry.example.com/org/demo:1.0.0" "signing disabled preserves helm push output"

# 2. Keyless signing: login with stdin, sign by digest.
if run_case keyless --cosign-sign true --skip-cosign-install true; then
  pass "keyless signing run succeeds"
else
  fail "keyless signing run failed"
fi
assert_contains "$LOG" "cosign login registry.example.com -u user --password-stdin" "cosign logs in with stdin"
assert_contains "$LOG" "cosign sign --yes registry.example.com/org/demo:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" "cosign signs the pushed digest"

# 3. Key-based signing.
printf 'dummy key' >"$WORK/cosign.key"
if run_case keymode --cosign-sign true --skip-cosign-install true --cosign-key "$WORK/cosign.key"; then
  pass "key-based signing run succeeds"
else
  fail "key-based signing run failed"
fi
assert_contains "$LOG" "cosign sign --yes --key $WORK/cosign.key " "cosign receives --key"

# 4. Extra cosign arguments are forwarded as separate arguments.
if run_case extra --cosign-sign true --skip-cosign-install true --cosign-extra-args "--tlog-upload=false -a env=test"; then
  pass "extra args run succeeds"
else
  fail "extra args run failed"
fi
assert_contains "$LOG" "cosign sign --yes --tlog-upload=false -a env=test registry.example.com/org/demo:1.0.0@sha256:" "extra args are appended to cosign sign"

# 5. Custom OCI tag path repackages and still signs the pushed digest.
if run_case retag --cosign-sign true --skip-cosign-install true --oci-tag-pattern 'demo-{version}'; then
  pass "retagged chart run succeeds"
else
  fail "retagged chart run failed"
fi
assert_contains "$OUT" "Repackaging chart with custom OCI tag: demo-1.0.0" "retag path repackages the chart"
assert_contains "$LOG" "cosign sign --yes registry.example.com/org/demo:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" "retag path signs the pushed digest"

# 6. Cosign failure fails the run before creating a GitHub release.
STUB_COSIGN_FAIL=1
if run_case failure --cosign-sign true --skip-cosign-install true; then
  fail "cosign failure should fail the run"
else
  pass "cosign failure fails the run"
fi
STUB_COSIGN_FAIL=0
assert_not_contains "$LOG" "gh release create" "no GitHub release is created when signing fails"

# 7. Dry run prints the sign command without executing cosign or helm push.
DRY_RUN=true
if run_case dryrun --cosign-sign true --skip-cosign-install true; then
  pass "dry-run succeeds"
else
  fail "dry-run failed"
fi
DRY_RUN=false
assert_contains "$OUT" "cosign sign --yes registry.example.com/org/demo:1.0.0" "dry-run prints the cosign sign command"
assert_not_contains "$LOG" "cosign " "dry-run does not execute cosign"

# 8. Install path downloads, verifies and uses the pinned cosign binary.
STUB_GH_DIGEST="sha256:$(sha256sum "$STUBS/cosign" | cut -d' ' -f1)"
if run_case install --cosign-sign true; then
  pass "cosign install run succeeds"
else
  fail "cosign install run failed"
fi
STUB_GH_DIGEST=""
assert_contains "$LOG" "gh api repos/sigstore/cosign/releases/tags/v3.1.4" "install fetches the pinned release digest"
assert_executable "$WORK/install-install/cosign" "install places an executable cosign in the install dir"
assert_contains "$LOG" "cosign sign --yes registry.example.com/org/demo:1.0.0@sha256:" "installed cosign signs the chart"

# 9. Invalid boolean values are rejected.
if run_case badbool --cosign-sign maybe --skip-cosign-install true; then
  fail "invalid boolean should be rejected"
else
  pass "invalid boolean is rejected"
fi
assert_contains "$OUT" "expects 'true' or 'false'" "invalid boolean reports a clear error"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]

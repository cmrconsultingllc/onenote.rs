#!/usr/bin/env bash
# Validates the onenote_parser VCIMCO fix branch against the client's 28-section
# sample. Runs inside an Azure Container Instance (VCIMCO_AI_RG, image
# mcr.microsoft.com/devcontainers/rust:1-bookworm). Two steps:
#   1. `cargo test` the fix branch directly (compiles the patch + runs the new
#      synthetic-data unit tests, plus the existing suite).
#   2. Build one2html from git, patched via cargo's `[patch.crates-io]` so it
#      pulls `onenote_parser` from this branch instead of crates.io, then
#      render every `.one` section from the SAS-provided sample and write a
#      JSON report (section -> ok/fail, pages, ms).
#
# Required env:
#   SAS_URL              - secure env var; read-only SAS to the sample container
#                           (base URL + query string, e.g.
#                           https://<acct>.blob.core.windows.net/proving/sample?<sas>)
#   BRANCH  (optional)   - fix branch to validate (default below)
#   REPO    (optional)   - fork to clone (default below)
#   SECTION_FILTER (opt) - if set, only render `.one` files whose relative path
#                           contains this substring (used for the dedicated
#                           big-file run)
#   RENDER_TIMEOUT (opt) - per-section timeout in seconds passed to `timeout`
#                           (default 300; the big-file run overrides this)
#
# Confidentiality: this script only ever prints section relative paths (already
# in our inventory), byte sizes, timings, and parser error text. It never
# prints page/note content or titles. Do not azcopy the pre-existing
# `sample/out/` prefix back down -- it holds a prior run's rendered HTML
# (page titles as filenames) and is not needed here.
set -u

BRANCH="${BRANCH:-task/vcimco-parser-fix-20260908-152944}"
REPO="${REPO:-https://github.com/cmrconsultingllc/onenote.rs}"
RENDER_TIMEOUT="${RENDER_TIMEOUT:-300}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates jq git time >/dev/null

echo "== installing azcopy =="
curl -sL https://aka.ms/downloadazcopy-v10-linux | tar xz -C /tmp && cp /tmp/azcopy_linux_amd64_*/azcopy /usr/local/bin/azcopy

export PATH="$PATH:/usr/local/cargo/bin:$HOME/.cargo/bin"
echo "== installing nightly toolchain (rustc: $(rustc --version 2>&1)) =="
rustup toolchain install nightly --profile minimal 2>&1 | tail -3

echo "== cargo test onenote_parser @ ${BRANCH} =="
git clone --branch "$BRANCH" --depth 1 "$REPO" /work/src 2>&1 | tail -5
(
  cd /work/src
  cargo +nightly test -p onenote_parser 2>&1 | tee /tmp/cargo_test.log | tail -150
  echo "cargo_test_exit=${PIPESTATUS[0]}"
) | tee /tmp/cargo_test_wrapper.log
grep -q '^cargo_test_exit=0$' /tmp/cargo_test_wrapper.log && echo "== cargo test: PASS ==" || echo "== cargo test: FAIL (see above) =="

echo "== building one2html from git, patched to use ${REPO}@${BRANCH} =="
# No --locked: one2html ships a Cargo.lock pinning onenote_parser to a plain
# crates.io version, and --locked forces cargo to honor that lock verbatim,
# silently ignoring the [patch.crates-io] override below. Dropping --locked
# lets cargo re-resolve with the patch in effect.
t0=$(date +%s)
cargo +nightly install --git https://github.com/msiemens/one2html \
  --config "patch.crates-io.onenote_parser.git=\"${REPO}\"" \
  --config "patch.crates-io.onenote_parser.branch=\"${BRANCH}\"" \
  > /tmp/one2html_build.log 2>&1
build_status=$?
grep -E "^(error|warning: patch|  Installing|   Installed)" /tmp/one2html_build.log | tail -40
echo "one2html build: $(( $(date +%s) - t0 ))s, exit=${build_status}"
if ! command -v one2html >/dev/null 2>&1; then
  echo "FAIL: one2html did not build against ${BRANCH} (2.0 API break or other failure)"
  tail -80 /tmp/one2html_build.log
  exit 1
fi
echo "one2html version: $(one2html --version 2>&1 | head -1)"

base="${SAS_URL%%\?*}"; sas="${SAS_URL#*\?}"
echo "== confirming sample READY marker =="
code=$(curl -s -o /dev/null -w '%{http_code}' "$base/READY?$sas")
[ "$code" != "200" ] && { echo "FAIL: sample not present (HTTP $code)"; exit 1; }

mkdir -p /work/in /work/out
echo "== fetching .one/.onetoc2 sections only (never the pre-existing out/ tree) =="
azcopy copy "$base/*?$sas" /work/in --recursive --include-pattern "*.one" --output-level essential 2>&1 \
  | grep -E "Final Job Status|Number of File Transfers" || true
n_one=$(find /work/in -name '*.one' | wc -l)
echo "sections received: $n_one"

report=/work/out/_report.json
echo '{"sections":[]}' > "$report"
ok=0; fail=0; pages_total=0
while IFS= read -r -d '' f; do
  rel="${f#/work/in/}"
  if [ -n "${SECTION_FILTER:-}" ] && [[ "$rel" != *"$SECTION_FILTER"* ]]; then
    continue
  fi
  outdir="/work/out/rendered/${rel%.one}"
  mkdir -p "$outdir"
  bytes=$(stat -c %s "$f")
  t=$(date +%s%N)
  if err=$(timeout "$RENDER_TIMEOUT" one2html -i "$f" -o "$outdir" 2>&1); then
    status=ok; ok=$((ok+1))
  else
    status=fail; fail=$((fail+1))
    echo "FAIL $rel (${bytes} bytes) :: $(echo "$err" | tail -1 | cut -c1-300)"
  fi
  ms=$(( ($(date +%s%N) - t) / 1000000 ))
  pages=$(find "$outdir" -name '*.html' | wc -l)
  pages_total=$((pages_total+pages))
  jq --arg r "$rel" --arg s "$status" --argjson p "$pages" --argjson b "$bytes" --argjson ms "$ms" \
     --arg e "$(echo "${err:-}" | tail -1 | cut -c1-400)" \
     '.sections += [{"section":$r,"status":$s,"pages":$p,"bytes":$b,"render_ms":$ms,"error":(if $s=="fail" then $e else null end)}]' \
     "$report" > "$report.tmp" && mv "$report.tmp" "$report"
  echo "  $rel :: $status pages=$pages ms=$ms bytes=$bytes"
done < <(find /work/in -name '*.one' -print0)

jq --argjson ok "$ok" --argjson fail "$fail" --argjson pages "$pages_total" \
   --arg ver "$(one2html --version 2>&1 | head -1)" \
   '. + {"summary":{"sections_ok":$ok,"sections_failed":$fail,"pages_rendered":$pages,"one2html":$ver,"rendered_at":(now|todate)}}' \
   "$report" > "$report.tmp" && mv "$report.tmp" "$report"

echo "== SUMMARY: ok=$ok fail=$fail pages=$pages_total (of $n_one sections considered) =="
echo "== REPORT JSON =="
cat "$report"
echo
echo DONE

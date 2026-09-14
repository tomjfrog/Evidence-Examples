#!/usr/bin/env bash
#
# Provisions the JFrog Platform objects the Xray-evidence lab expects.
#
# Idempotent: every step checks for an existing object before creating it, so
# re-running is safe.
#
# Usage:
#   ./scripts/xray-evidence-lab-setup.sh [step ...]
#
# Steps (all of them run when none are named):
#   repos       local/remote/virtual npm + docker repos, and a generic repo
#   xray        add the repos to Xray indexing, create a policy and a watch
#   stages      project-scoped QA and STAGING promote stages
#   builds      add the lab build to the Xray build index (needs a published build)
#   apptrust    the hello-express application
#   categories  register the lab predicate types under the Security category
#   policy      Unified Policy rule + policy requiring SBOM evidence at QA entry
#
# Requires: jf CLI configured with an admin token for the target server.

set -euo pipefail

SERVER_ID="${SERVER_ID:-tomjpd2}"
PROJECT_KEY="${PROJECT_KEY:-evidenceexamples}"
APP_KEY="${APP_KEY:-hello-express}"
# Must match BUILD_NAME in .github/workflows/4-xray-evidence-lab.yml
BUILD_NAME="${BUILD_NAME:-hello-express-build}"
JF_HOST="${JF_HOST:-https://tomjpd2.jfrog.io}"

# Predicate type the workflow attaches its own Xray CycloneDX output under.
LAB_SBOM_PREDICATE="https://cyclonedx.org/bom/v1.6"
LAB_SARIF_PREDICATE="https://jfrog.com/evidence/xray-sarif/v1"

NPM_REMOTE="${PROJECT_KEY}-npm-remote"
NPM_LOCAL="${PROJECT_KEY}-npm-dev-local"
NPM_VIRTUAL="${PROJECT_KEY}-npm-virtual"
DOCKER_REMOTE="${PROJECT_KEY}-docker-remote"
DOCKER_LOCAL="${PROJECT_KEY}-docker-dev-local"
DOCKER_VIRTUAL="${PROJECT_KEY}-docker-virtual"
GENERIC_LOCAL="${PROJECT_KEY}-generic-local"

ALL_REPOS=("$NPM_REMOTE" "$NPM_LOCAL" "$NPM_VIRTUAL" "$DOCKER_REMOTE" "$DOCKER_LOCAL" "$DOCKER_VIRTUAL" "$GENERIC_LOCAL")
INDEXABLE_REPOS=("$NPM_REMOTE" "$NPM_LOCAL" "$DOCKER_REMOTE" "$DOCKER_LOCAL" "$GENERIC_LOCAL")

TOKEN="$(jf config export "$SERVER_ID" | base64 -d | python3 -c 'import sys,json; print(json.load(sys.stdin)["accessToken"])')"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# api <method> <path> [body]
# Results land in the globals API_STATUS and API_BODY. They are deliberately not
# written to stdout: wrapping this in $(...) would run it in a subshell and the
# status code would never make it back to the caller.
api() {
  local method="$1" path="$2" body="${3:-}" out
  if [[ -n "$body" ]]; then
    out=$(curl -sS -w $'\n%{http_code}' -X "$method" "${JF_HOST}${path}" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "$body")
  else
    out=$(curl -sS -w $'\n%{http_code}' -X "$method" "${JF_HOST}${path}" \
      -H "Authorization: Bearer ${TOKEN}")
  fi
  API_STATUS="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
}

# Artifactory answers 400, not 404, for a GET on an unknown repository key.
repo_exists() {
  api GET "/artifactory/api/repositories/$1"
  [[ "$API_STATUS" == "200" ]]
}

create_repo() {
  local key="$1" body="$2"
  if repo_exists "$key"; then
    info "$key already exists, updating config"
    api POST "/artifactory/api/repositories/${key}" "$body"
    [[ "$API_STATUS" =~ ^2 ]] || printf '    update warning %s (HTTP %s): %s\n' "$key" "$API_STATUS" "$API_BODY" >&2
    return 0
  fi
  api PUT "/artifactory/api/repositories/${key}?projectKey=${PROJECT_KEY}" "$body"
  if [[ "$API_STATUS" =~ ^2 ]]; then
    info "created $key"
  else
    printf '    FAILED %s (HTTP %s): %s\n' "$key" "$API_STATUS" "$API_BODY" >&2
    return 1
  fi
}

step_repos() {
  log "Repositories in project ${PROJECT_KEY}"

  create_repo "$NPM_REMOTE" "$(cat <<JSON
{ "key": "$NPM_REMOTE", "rclass": "remote", "packageType": "npm",
  "url": "https://registry.npmjs.org", "projectKey": "$PROJECT_KEY",
  "description": "Xray evidence lab - npm proxy, curation OFF so CVE-bearing deps resolve" }
JSON
)"

  create_repo "$NPM_LOCAL" "$(cat <<JSON
{ "key": "$NPM_LOCAL", "rclass": "local", "packageType": "npm",
  "projectKey": "$PROJECT_KEY",
  "description": "Xray evidence lab - published hello-express npm package (evidence subject)" }
JSON
)"

  create_repo "$NPM_VIRTUAL" "$(cat <<JSON
{ "key": "$NPM_VIRTUAL", "rclass": "virtual", "packageType": "npm",
  "projectKey": "$PROJECT_KEY",
  "repositories": ["$NPM_LOCAL", "$NPM_REMOTE"],
  "defaultDeploymentRepo": "$NPM_LOCAL",
  "description": "Xray evidence lab - npm resolution and deployment" }
JSON
)"

  create_repo "$DOCKER_REMOTE" "$(cat <<JSON
{ "key": "$DOCKER_REMOTE", "rclass": "remote", "packageType": "docker",
  "url": "https://registry-1.docker.io", "projectKey": "$PROJECT_KEY",
  "dockerApiVersion": "V2",
  "description": "Xray evidence lab - Docker Hub proxy for base image lineage" }
JSON
)"

  create_repo "$DOCKER_LOCAL" "$(cat <<JSON
{ "key": "$DOCKER_LOCAL", "rclass": "local", "packageType": "docker",
  "projectKey": "$PROJECT_KEY", "dockerApiVersion": "V2",
  "description": "Xray evidence lab - hello-express image (evidence subject)" }
JSON
)"

  create_repo "$DOCKER_VIRTUAL" "$(cat <<JSON
{ "key": "$DOCKER_VIRTUAL", "rclass": "virtual", "packageType": "docker",
  "projectKey": "$PROJECT_KEY",
  "repositories": ["$DOCKER_LOCAL", "$DOCKER_REMOTE"],
  "defaultDeploymentRepo": "$DOCKER_LOCAL",
  "description": "Xray evidence lab - Docker push/pull target" }
JSON
)"

  create_repo "$GENERIC_LOCAL" "$(cat <<JSON
{ "key": "$GENERIC_LOCAL", "rclass": "local", "packageType": "generic",
  "projectKey": "$PROJECT_KEY",
  "description": "Xray evidence lab - raw SARIF and CycloneDX scan reports" }
JSON
)"

  # This instance curates new remote repos by default, which would block the
  # CVE-bearing dependencies the lab depends on. `curated` is rejected by the
  # create call (PUT), so it has to be turned off with a follow-up update.
  log "Disabling curation on the remote repositories"
  for repo in "$NPM_REMOTE" "$DOCKER_REMOTE"; do
    api POST "/artifactory/api/repositories/${repo}" '{"curated":false}'
    api GET "/artifactory/api/repositories/${repo}"
    info "${repo}: curated=$(printf '%s' "$API_BODY" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("curated"))')"
  done
}

step_xray() {
  log "Xray indexing"
  # Indexing is opt-in per repo; Xray will not scan a repo it has not indexed.
  # The endpoint is a full-list PUT, so read the current list and merge the lab
  # repos into it. Sending only the lab repos would un-index everything else.
  api GET "/xray/api/v1/binMgr/default/repos"
  local payload
  payload=$(python3 - "$API_BODY" "${INDEXABLE_REPOS[@]}" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
want = set(sys.argv[2:])
indexed = list(d.get("indexed_repos") or [])
have = {r.get("name") for r in indexed}
# Take the entries from non_indexed_repos so type and pkg_type stay exact.
for r in (d.get("non_indexed_repos") or []):
    if r.get("name") in want and r.get("name") not in have:
        indexed.append({"name": r["name"], "type": r.get("type"), "pkg_type": r.get("pkg_type")})
print(json.dumps({"indexed_repos": indexed}))
PY
)
  api PUT "/xray/api/v1/binMgr/default/repos" "$payload"
  info "HTTP ${API_STATUS} ${API_BODY}"

  api GET "/xray/api/v1/binMgr/default/repos"
  python3 - "$API_BODY" "${INDEXABLE_REPOS[@]}" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
want = sys.argv[2:]
indexed = {r.get('name') for r in d.get('indexed_repos', [])}
print(f"    total indexed repos: {len(indexed)}")
for n in want:
    print(f"    {n}: {'indexed' if n in indexed else 'NOT INDEXED'}")
PY

  log "Xray policy and watch"
  # A watch is required for jf build-scan to report violations. Without one the
  # scan runs but returns nothing and any scan-based gate is silently a no-op.
  local policy_name="${PROJECT_KEY}-lab-security-policy"
  local watch_name="${PROJECT_KEY}-lab-watch"

  api GET "/xray/api/v2/policies/${policy_name}?projectKey=${PROJECT_KEY}"
  if [[ "$API_STATUS" == "200" ]]; then
    info "policy ${policy_name} already exists"
  else
    # projectKey must be a query parameter; without it the policy is created
    # globally rather than scoped to the project.
    api POST "/xray/api/v2/policies?projectKey=${PROJECT_KEY}" "$(cat <<JSON
{ "name": "$policy_name", "type": "security",
  "description": "Xray evidence lab - flags high/critical CVEs without blocking",
  "rules": [ { "name": "high-and-critical", "priority": 1,
               "criteria": { "min_severity": "High" },
               "actions": { "fail_build": false,
                            "block_download": { "active": false, "unscanned": false } } } ] }
JSON
)"
    info "policy HTTP ${API_STATUS} ${API_BODY}"
  fi

  # Project-scoped watches, matching the existing poc-* convention on this
  # instance. Naming the project's repos individually is rejected -- Xray does
  # not resolve project repo keys as watch resources -- so all-repos is used.
  create_watch "${watch_name}-repos" "$policy_name" \
    '[{"type":"all-repos","name":"All Repositories"}]'

  # jf build-scan only reports violations when a *build* watch covers the build,
  # which is a separate resource type from repositories. The project build-info
  # repo does not exist until the first build is published, so this may fail on
  # a first run; re-run this step after the pipeline has published a build.
  create_watch "${watch_name}-builds" "$policy_name" \
    "$(printf '[{"type":"all-builds","name":"All Builds","bin_mgr_id":"default","build_repo":"%s-build-info"}]' "$PROJECT_KEY")"
}

create_watch() {
  local name="$1" policy="$2" resources="$3"
  api GET "/xray/api/v2/watches/${name}"
  if [[ "$API_STATUS" == "200" ]]; then
    info "watch ${name} already exists"
    return 0
  fi
  # The project is scoped via the query parameter; Xray rejects a project_key
  # inside general_data even though it reads one back on GET.
  api POST "/xray/api/v2/watches?projectKey=${PROJECT_KEY}" "$(python3 - "$name" "$policy" "$resources" <<'PY'
import json, sys
name, policy, resources = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
print(json.dumps({
    "general_data": {"name": name, "description": "Xray evidence lab", "active": True},
    "project_resources": {"resources": resources},
    "assigned_policies": [{"name": policy, "type": "security"}],
}))
PY
)"
  if [[ "$API_STATUS" =~ ^2 ]]; then
    info "created watch ${name}"
  else
    info "watch ${name} FAILED (HTTP ${API_STATUS}): ${API_BODY}"
  fi
}

# Builds are indexed separately from repositories, and only become visible to
# Xray once one has been published -- so this step is a no-op until the pipeline
# has run at least once. Like the repo index, it is a full-list PUT and has to be
# merged rather than replaced.
step_builds() {
  log "Xray build indexing"
  api GET "/xray/api/v1/binMgr/default/builds?projectKey=${PROJECT_KEY}"
  if [[ ! "$API_STATUS" =~ ^2 ]]; then
    info "could not read the build index (HTTP ${API_STATUS}): ${API_BODY}"
    return 0
  fi

  local payload
  payload=$(python3 - "$API_BODY" "$BUILD_NAME" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
name = sys.argv[2]
indexed = list(d.get("indexed_builds") or [])
known = set(indexed) | {b for b in (d.get("non_indexed_builds") or [])}
if name not in known:
    print("")  # build not visible to Xray yet
else:
    if name not in indexed:
        indexed.append(name)
    print(json.dumps({"indexed_builds": indexed}))
PY
)
  if [[ -z "$payload" ]]; then
    info "build '${BUILD_NAME}' is not known to Xray yet; run the pipeline once, then re-run this step"
    return 0
  fi

  api PUT "/xray/api/v1/binMgr/default/builds?projectKey=${PROJECT_KEY}" "$payload"
  info "HTTP ${API_STATUS} ${API_BODY}"
}

step_stages() {
  log "Project-scoped promote stages"
  # The project starts with only the global DEV (promote) and PROD (release)
  # stages. QA and STAGING give the lab somewhere to exercise promotion gates.
  for stage in QA STAGING; do
    local scoped="${PROJECT_KEY}-${stage}"
    api POST "/access/api/v2/stages" "$(cat <<JSON
{ "name": "$scoped", "scope": "project", "project_key": "$PROJECT_KEY", "category": "promote" }
JSON
)"
    case "$API_STATUS" in
      2*)  info "created stage ${scoped}" ;;
      409) info "stage ${scoped} already exists" ;;
      *)   info "stage ${scoped} FAILED (HTTP ${API_STATUS}): ${API_BODY}" ;;
    esac
  done

  # Creating a stage does not attach it to anything; the project lifecycle has to
  # list it before a version can be promoted there.
  log "Promote-stage order: DEV -> QA -> STAGING -> PROD"
  api PATCH "/access/api/v2/lifecycle?project_key=${PROJECT_KEY}" "$(cat <<JSON
{ "promote_stages": ["DEV", "${PROJECT_KEY}-QA", "${PROJECT_KEY}-STAGING"] }
JSON
)"
  info "HTTP ${API_STATUS}"
  python3 - "$API_BODY" <<'PY' || info "$API_BODY"
import sys, json
for c in json.loads(sys.argv[1]).get("categories", []):
    names = [s["name"] for s in c["stages"]]
    print("    {}: {}".format(c["category"], " -> ".join(names)))
PY

  log "Assigning repositories to the DEV stage"
  for repo in "${ALL_REPOS[@]}"; do
    api POST "/artifactory/api/repositories/${repo}" '{"environments":["DEV"]}'
    info "${repo}: HTTP ${API_STATUS}"
  done

  api GET "/access/api/v2/stages?project_key=${PROJECT_KEY}"
  python3 - "$API_BODY" <<'PY' || info "$API_BODY"
import sys, json
for s in json.loads(sys.argv[1]):
    print("    {:32} scope={:8} category={:8} used_in={}".format(
        s["name"], s.get("scope", ""), s.get("category", ""), s.get("used_in_lifecycles")))
PY
}

step_apptrust() {
  log "AppTrust application ${APP_KEY}"
  api GET "/apptrust/api/v1/applications/${APP_KEY}"
  if [[ "$API_STATUS" == "200" ]]; then
    info "application ${APP_KEY} already exists"
  else
    jf apptrust app-create "$APP_KEY" \
      --server-id "$SERVER_ID" \
      --project "$PROJECT_KEY" \
      --application-name "Hello Express" \
      --desc "Xray-results-as-provenance lab: npm package + Docker image" \
      --business-criticality medium \
      --maturity-level experimental \
      --labels "lab=xray-evidence" || info "app-create returned non-zero; check output above"
  fi
  api GET "/apptrust/api/v1/applications/${APP_KEY}"
  printf '%s' "$API_BODY" | python3 -m json.tool 2>/dev/null | head -20 || info "$API_BODY"
}

step_categories() {
  log "Registering lab predicate types under the Security evidence category"
  # The categories config endpoint replaces the whole mapping, so read the
  # current config, merge the lab types in, then write it back. Without this the
  # hand-attached CycloneDX predicate lands in Custom instead of Security.
  local current merged
  api GET "/evidence/api/v1/config/categories/"
  current="$API_BODY"
  info "current: ${current}"

  merged=$(python3 - "$current" "$LAB_SBOM_PREDICATE" "$LAB_SARIF_PREDICATE" <<'PY'
import json, sys
cfg = json.loads(sys.argv[1])
cats = cfg.get("categories", cfg)
security = list(cats.get("Security", []))
for t in sys.argv[2:]:
    if t not in security:
        security.append(t)
cats["Security"] = security
print(json.dumps({"categories": cats}))
PY
)
  api PUT "/evidence/api/v1/config/categories/" "$merged"
  info "HTTP ${API_STATUS} ${API_BODY}"

  api GET "/evidence/api/v1/config/categories/"
  printf '%s' "$API_BODY" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("    Security:", json.dumps(d.get("categories",d).get("Security"), indent=2))' \
    || info "$API_BODY"
}

step_policy() {
  log "Unified Policy: require SBOM evidence at QA entry"
  local templates tpl_id
  api GET "/unifiedpolicy/api/v1/templates?limit=200"
  templates="$API_BODY"
  # The built-in evidence-existence template. Its display name is long and
  # parameterised, so match on the stable part; it takes a single predicateType.
  tpl_id=$(printf '%s' "$templates" | python3 -c '
import sys, json
d = json.load(sys.stdin)
items = d.get("items", d if isinstance(d, list) else [])
for t in items:
    name = (t.get("name") or "").lower()
    if "evidence slug" in name and "exist on evaluated resource" in name:
        print(t.get("id")); break
' 2>/dev/null || true)

  if [[ -z "$tpl_id" ]]; then
    info "could not locate the evidence-existence template"
    printf '%s' "$templates" | python3 -c '
import sys, json
d = json.load(sys.stdin)
items = d.get("items", d if isinstance(d, list) else [])
for t in items: print("    template:", t.get("id"), "-", t.get("name"))
' 2>/dev/null | head -40 || info "raw: ${templates:0:600}"
    return 0
  fi
  info "template id ${tpl_id}"

  local rule_name="${PROJECT_KEY}-lab-require-sbom-evidence"
  local rules rule_id
  api GET "/unifiedpolicy/api/v1/rules?limit=200"
  rules="$API_BODY"
  rule_id=$(printf '%s' "$rules" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', d if isinstance(d, list) else [])
for r in items:
    if r.get('name') == '''$rule_name''':
        print(r.get('id')); break
" 2>/dev/null || true)

  if [[ -z "$rule_id" ]]; then
    api POST "/unifiedpolicy/api/v1/rules" "$(python3 - "$rule_name" "$tpl_id" "$LAB_SBOM_PREDICATE" <<'PY'
import json, sys
name, tpl, predicate = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "name": name,
    "description": "SBOM evidence must exist on the evaluated resource",
    "template_id": tpl,
    "parameters": [{"name": "predicateType", "value": predicate}],
}))
PY
)"
    info "rule HTTP ${API_STATUS} ${API_BODY}"
    rule_id=$(printf '%s' "$API_BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
  else
    info "rule already exists: ${rule_id}"
  fi

  [[ -z "$rule_id" ]] && { info "no rule id, skipping policy"; return 0; }

  # Starts in warning mode. Flip to "block" and re-run the workflow with
  # attach_evidence=false to prove the gate actually stops a promotion.
  local policy_name="${PROJECT_KEY}-lab-sbom-required-at-qa-entry"
  local policies existing
  api GET "/unifiedpolicy/api/v1/policies?limit=200"
  policies="$API_BODY"
  existing=$(printf '%s' "$policies" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('items', d if isinstance(d, list) else [])
for p in items:
    if p.get('name') == '''$policy_name''':
        print(p.get('id')); break
" 2>/dev/null || true)

  if [[ -n "$existing" ]]; then
    info "policy already exists: ${existing}"
    return 0
  fi

  api POST "/unifiedpolicy/api/v1/policies" "$(python3 - "$policy_name" "$rule_id" "$APP_KEY" "${PROJECT_KEY}-QA" <<'PY'
import json, sys
name, rule_id, app_key, stage = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    "name": name,
    "description": "Warning-mode gate; flip mode to block for the negative-control run",
    "enabled": True,
    "mode": "warning",
    "action": {"type": "certify_to_gate", "stage": {"key": stage, "gate": "entry"}},
    "scope": {"type": "application", "application_keys": [app_key]},
    "rule_ids": [rule_id],
    "waiver_request_config": "manual",
}))
PY
)"
  info "policy HTTP ${API_STATUS} ${API_BODY}"
}

STEPS=("$@")
[[ ${#STEPS[@]} -eq 0 ]] && STEPS=(repos xray builds stages apptrust categories policy)

for s in "${STEPS[@]}"; do
  case "$s" in
    repos)      step_repos ;;
    xray)       step_xray ;;
    builds)     step_builds ;;
    stages)     step_stages ;;
    apptrust)   step_apptrust ;;
    categories) step_categories ;;
    policy)     step_policy ;;
    *) printf 'unknown step: %s\n' "$s" >&2; exit 1 ;;
  esac
done

log "Done"

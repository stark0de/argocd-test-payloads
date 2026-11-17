#!/usr/bin/env bash
# Read-only Argo CD inventory and RBAC audit. Runs with macOS Bash 3.2+.
set -u
set -o pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: bash argocd_audit.sh [--out DIR] [--include-manifests]

Environment: ARGOCD_SERVER, ARGOCD_AUTH_TOKEN, CF_ACCESS_TOKEN
Optional:    ARGOCD_BIN (default: ./argocd)

The script defines acd() internally. A shell alias/function from your interactive
Terminal cannot be inherited by a Bash script. No write, sync, exec, or delete
operation is performed. --include-manifests saves rendered manifests, which may
contain secrets. Output permissions are restricted to the current user.
EOF
}

INCLUDE_MANIFESTS=0
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OUT=$2; shift 2 ;;
    --include-manifests) INCLUDE_MANIFESTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo 'jq is required (brew install jq).' >&2; exit 2; }
ARGOCD_BIN=${ARGOCD_BIN:-./argocd}
[ -x "$ARGOCD_BIN" ] || { printf 'Argo CD CLI is not executable: %s\n' "$ARGOCD_BIN" >&2; exit 2; }
ARGOCD_SERVER=${ARGOCD_SERVER:-}
[ -n "$ARGOCD_SERVER" ] || { echo 'Set ARGOCD_SERVER to the hostname (without https://).' >&2; exit 2; }

if [ -z "${ARGOCD_AUTH_TOKEN:-}" ]; then
  read -r -s -p 'Paste argocd.token: ' ARGOCD_AUTH_TOKEN
  printf '\n'
fi
if [ -z "${CF_ACCESS_TOKEN:-}" ]; then
  read -r -s -p 'Paste CF_Authorization: ' CF_ACCESS_TOKEN
  printf '\n'
fi
[ -n "$ARGOCD_AUTH_TOKEN" ] && [ -n "$CF_ACCESS_TOKEN" ] || { echo 'Both tokens are required.' >&2; exit 2; }

# Keep the same acd name as the interactive shortcut. Flags follow the command.
acd() {
  "$ARGOCD_BIN" "$@" --server "$ARGOCD_SERVER" --grpc-web \
    --auth-token "$ARGOCD_AUTH_TOKEN" \
    --header "Cookie: CF_Authorization=${CF_ACCESS_TOKEN}"
}

if [ -z "$OUT" ]; then
  server_name=$(printf '%s' "$ARGOCD_SERVER" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  OUT="./argocd-audit-${server_name}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  printf 'Refusing to overwrite nonempty evidence folder: %s\n' "$OUT" >&2
  exit 2
fi
mkdir -p "$OUT"/{inventory,details/apps,details/projects,details/appsets,details/clusters,permissions,errors}
OUT=$(cd "$OUT" && pwd -P)
chmod 700 "$OUT"
STATUS="$OUT/command-status.tsv"
MATRIX="$OUT/permissions/matrix.tsv"
printf 'section\tentity\tcommand\texit_code\tstdout_file\tstderr_file\n' > "$STATUS"
printf 'resource\taction\tobject\tdecision\texit_code\traw_response\n' > "$MATRIX"

clean_field() { printf '%s' "$1" | tr '\t\r\n' '   '; }
safe_id() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

capture() {
  section=$1 entity=$2 file=$3; shift 3
  err="$OUT/errors/$(safe_id "$section|$entity|$file").stderr"
  if acd "$@" > "$file" 2> "$err"; then rc=0; else rc=$?; fi
  [ -s "$err" ] || rm -f "$err"
  cmd=$(printf '%s ' "$@")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$section")" "$(clean_field "$entity")" \
    "$(clean_field "$cmd")" "$rc" "$file" "$err" >> "$STATUS"
  return 0
}

check() {
  resource=$1 action=$2 object=$3
  if response=$(acd account can-i "$action" "$resource" "$object" 2>&1); then rc=0; else rc=$?; fi
  case "$response" in
    yes|Yes|YES) decision=allow ;;
    no|No|NO) decision=deny ;;
    *) decision=error ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$resource")" "$(clean_field "$action")" \
    "$(clean_field "$object")" "$decision" "$rc" \
    "$(clean_field "$response")" >> "$MATRIX"
}

check_actions() {
  resource=$1 object=$2; shift 2
  for action in "$@"; do check "$resource" "$action" "$object"; done
}

printf 'Started UTC: %s\nServer: %s\nCLI: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ARGOCD_SERVER" "$ARGOCD_BIN" > "$OUT/run-info.txt"
"$ARGOCD_BIN" version --client > "$OUT/inventory/client-version.txt" 2>&1 || true
capture inventory server "$OUT/inventory/server-version.txt" version
capture inventory identity "$OUT/inventory/identity.json" account get-user-info -o json
capture inventory applications "$OUT/inventory/applications.json" app list -o json
capture inventory projects "$OUT/inventory/projects.json" proj list -o json
capture inventory applicationsets "$OUT/inventory/applicationsets.json" appset list -o json
capture inventory repositories "$OUT/inventory/repositories.json" repo list -o json
capture inventory clusters "$OUT/inventory/clusters.json" cluster list -o json
capture inventory accounts "$OUT/inventory/accounts.json" account list -o json
capture inventory certificates "$OUT/inventory/certificates.json" cert list -o json
capture inventory gpgkeys "$OUT/inventory/gpgkeys.json" gpg list -o json
capture inventory repocreds "$OUT/inventory/repocreds.json" repocreds list -o json

# Official Argo CD RBAC resource/action catalogue. Wildcard queries are probes,
# not a substitute for concrete object checks below.
check_actions applications '*' get create update delete sync rollback override 'action/*' 'update/*' 'delete/*'
check_actions applicationsets '*' get create update delete
check_actions clusters '*' get create update delete
check_actions projects '*' get create update delete
check_actions repositories '*' get create update delete
check_actions write-repositories '*' get create update delete
check_actions accounts '*' get update
check_actions certificates '*' get create delete
check_actions gpgkeys '*' get create delete
check_actions logs '*' get
check_actions exec '*' create
check_actions extensions '*' invoke

if jq -e . "$OUT/inventory/projects.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end | .metadata.name // .name // empty' \
    "$OUT/inventory/projects.json" | sort -u | while IFS= read -r project; do
      [ -n "$project" ] || continue
      id=$(safe_id "$project")
      printf '%s\n' "$project" > "$OUT/details/projects/$id.id"
      capture projects "$project" "$OUT/details/projects/$id.json" proj get "$project" -o json
      check_actions projects "$project" get create update delete
      check_actions applications "$project/*" get create update delete sync rollback override 'action/*' 'update/*' 'delete/*'
      check_actions applicationsets "$project/*" get create update delete
      check_actions repositories "$project/*" get create update delete
      check_actions write-repositories "$project/*" get create update delete
      check_actions clusters "$project/*" get create update delete
      check logs get "$project/*"
      check exec create "$project/*"
    done
fi

if jq -e . "$OUT/inventory/applications.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end |
    [.metadata.name // "", .metadata.namespace // "", .spec.project // "default"] | @tsv' \
    "$OUT/inventory/applications.json" | sort -u | while IFS="$(printf '\t')" read -r app ns project; do
      [ -n "$app" ] || continue
      id=$(safe_id "$project|$ns|$app")
      printf 'project=%s\nnamespace=%s\napp=%s\n' "$project" "$ns" "$app" > "$OUT/details/apps/$id.id"
      if [ -n "$ns" ]; then
        capture apps "$project/$ns/$app" "$OUT/details/apps/$id.json" app get "$app" --app-namespace "$ns" -o json
        capture apps "$project/$ns/$app" "$OUT/details/apps/$id.resources.txt" app resources "$app" --app-namespace "$ns"
        capture apps "$project/$ns/$app" "$OUT/details/apps/$id.history.txt" app history "$app" --app-namespace "$ns"
        capture apps "$project/$ns/$app" "$OUT/details/apps/$id.actions.txt" app actions list "$app" --app-namespace "$ns"
        if [ "$INCLUDE_MANIFESTS" -eq 1 ]; then
          capture apps "$project/$ns/$app" "$OUT/details/apps/$id.manifests.yaml" app manifests "$app" --app-namespace "$ns"
        fi
      else
        capture apps "$project/$app" "$OUT/details/apps/$id.json" app get "$app" -o json
        capture apps "$project/$app" "$OUT/details/apps/$id.resources.txt" app resources "$app"
        capture apps "$project/$app" "$OUT/details/apps/$id.history.txt" app history "$app"
        capture apps "$project/$app" "$OUT/details/apps/$id.actions.txt" app actions list "$app"
        if [ "$INCLUDE_MANIFESTS" -eq 1 ]; then
          capture apps "$project/$app" "$OUT/details/apps/$id.manifests.yaml" app manifests "$app"
        fi
      fi
      # Check both object formats: project/app and project/namespace/app.
      for object in "$project/$app" "$project/$ns/$app"; do
        [ "$object" != "$project//$app" ] || continue
        check_actions applications "$object" get create update delete sync rollback override 'action/*' 'update/*' 'delete/*'
        check logs get "$object"
        check exec create "$object"
      done
    done
fi

if jq -e . "$OUT/inventory/applicationsets.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end |
    [.metadata.name // "", .metadata.namespace // ""] | @tsv' \
    "$OUT/inventory/applicationsets.json" | sort -u | while IFS="$(printf '\t')" read -r appset ns; do
      [ -n "$appset" ] || continue
      id=$(safe_id "$ns|$appset")
      printf 'namespace=%s\nappset=%s\n' "$ns" "$appset" > "$OUT/details/appsets/$id.id"
      if [ -n "$ns" ]; then
        capture appsets "$ns/$appset" "$OUT/details/appsets/$id.json" appset get "$ns/$appset" -o json
      else
        capture appsets "$appset" "$OUT/details/appsets/$id.json" appset get "$appset" -o json
      fi
      check_actions applicationsets "*/$appset" get create update delete
      if jq -e . "$OUT/inventory/projects.json" >/dev/null 2>&1; then
        jq -r 'if type=="array" then .[] else (.items // [])[] end | .metadata.name // .name // empty' \
          "$OUT/inventory/projects.json" | sort -u | while IFS= read -r project; do
            check_actions applicationsets "$project/$appset" get create update delete
          done
      fi
    done
fi

if jq -e . "$OUT/inventory/repositories.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end |
    [.repo // .url // "", .project // ""] | @tsv' \
    "$OUT/inventory/repositories.json" | sort -u | while IFS="$(printf '\t')" read -r repo project; do
      [ -n "$repo" ] || continue
      if [ -n "$project" ]; then object="$project/$repo"; else object=$repo; fi
      check_actions repositories "$object" get create update delete
      check_actions write-repositories "$object" get create update delete
    done
fi

if jq -e . "$OUT/inventory/clusters.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end |
    [.server // "", .project // ""] | @tsv' \
    "$OUT/inventory/clusters.json" | sort -u | while IFS="$(printf '\t')" read -r cluster project; do
      [ -n "$cluster" ] || continue
      if [ -n "$project" ]; then object="$project/$cluster"; else object=$cluster; fi
      id=$(safe_id "$object")
      printf '%s\n' "$object" > "$OUT/details/clusters/$id.id"
      capture clusters "$cluster" "$OUT/details/clusters/$id.json" cluster get "$cluster" -o json
      check_actions clusters "$object" get create update delete
    done
fi

if jq -e . "$OUT/inventory/accounts.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end | .name // .metadata.name // empty' \
    "$OUT/inventory/accounts.json" | sort -u | while IFS= read -r account; do
      [ -n "$account" ] || continue
      check_actions accounts "$account" get update
    done
fi

if jq -e . "$OUT/inventory/certificates.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end | .serverName // .hostname // empty' \
    "$OUT/inventory/certificates.json" | sort -u | while IFS= read -r host; do
      [ -n "$host" ] || continue
      check_actions certificates "$host" get create delete
    done
fi

if jq -e . "$OUT/inventory/gpgkeys.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end | .keyID // .keyId // .fingerprint // empty' \
    "$OUT/inventory/gpgkeys.json" | sort -u | while IFS= read -r key; do
      [ -n "$key" ] || continue
      check_actions gpgkeys "$key" get create delete
    done
fi

if jq -e . "$OUT/inventory/repocreds.json" >/dev/null 2>&1; then
  jq -r 'if type=="array" then .[] else (.items // [])[] end | .url // .repo // empty' \
    "$OUT/inventory/repocreds.json" | sort -u | while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      check_actions repositories "$repo" get create update delete
      check_actions write-repositories "$repo" get create update delete
    done
fi

# Views for triage. These contain decisions only; no active operation is run.
awk -F '\t' 'NR==1 || $4=="deny"' "$MATRIX" > "$OUT/permissions/denied.tsv"
awk -F '\t' 'NR==1 || $4=="error"' "$MATRIX" > "$OUT/permissions/errors.tsv"
awk -F '\t' 'NR==1 || ($4=="allow" && !($2=="get"))' "$MATRIX" > "$OUT/permissions/critical-allow.tsv"

printf 'Finished UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/run-info.txt"
printf 'Evidence folder: %s\n' "$OUT"
printf 'Permission decisions: '; tail -n +2 "$MATRIX" | cut -f4 | sort | uniq -c
printf 'Failed/unsupported inventory commands: '; awk -F '\t' 'NR>1 && $4!=0 {n++} END {print n+0}' "$STATUS"


#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Supabase Migration Tool
# Migrates schema, data, auth, storage, and edge functions
# between two Supabase projects.
# ─────────────────────────────────────────────────────────────

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP_DIR="$SCRIPT_DIR/dump"
STORAGE_DIR="$SCRIPT_DIR/storage_tmp"
LOG_FILE="$SCRIPT_DIR/migrate-$(date +%Y%m%d-%H%M%S).log"

# Phase tracking
PHASES=("Preflight" "Schema" "Data" "Storage" "Functions" "Verify")
declare -a PHASE_STATUS=("pending" "pending" "pending" "pending" "pending" "pending")
declare -a PHASE_TIME=("" "" "" "" "" "")
declare -a PHASE_DETAIL=("" "" "" "" "" "")

# CLI flags
DRY_RUN=false
SKIP_SCHEMA=false
SKIP_DATA=false
SKIP_AUTH=false
SKIP_STORAGE=false
SKIP_FUNCTIONS=false
NO_CONFIRM=false
NO_COLOR=false

# Runtime state
SPINNER_PID=""
NEEDS_RESTRICT_STRIP=false

# Color defaults (overwritten by setup_colors)
RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" NC=""

# ─────────────────────────────────────────────────────────────
# Color System
# ─────────────────────────────────────────────────────────────

setup_colors() {
  if [[ "${NO_COLOR:-}" == "1" ]] || [[ "$NO_COLOR" == "true" ]] || [[ ! -t 1 ]]; then
    NO_COLOR=true
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" NC=""
  else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
  fi
}

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────

setup_logging() {
  exec > >(tee -a "$LOG_FILE") 2>&1
}

log_info()    { echo -e "${CYAN}  ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}  ✓${NC} $*"; }
log_warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
log_error()   { echo -e "${RED}  ✗${NC} $*"; }
die()         { log_error "$*"; exit 1; }

step() {
  local n="$1"; shift
  echo ""
  echo -e "${BOLD}  [$n/${#PHASES[@]}] $*${NC}"
  echo -e "  $DIM$(printf '%.0s─' {1..50})$NC"
}

# ─────────────────────────────────────────────────────────────
# Spinner
# ─────────────────────────────────────────────────────────────

spinner_start() {
  if [[ "$NO_COLOR" == "true" ]] || [[ ! -t 1 ]]; then
    echo -e "  … $1"
    return
  fi
  local msg="$1"
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  (
    local i=0
    while true; do
      printf "\r  ${CYAN}%s${NC} %s" "${frames[$((i % ${#frames[@]}))]}" "$msg"
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
  local status="$1"; shift
  local msg="$*"
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
  case "$status" in
    ok)   echo -e "${GREEN}  ✓${NC} $msg" ;;
    fail) echo -e "${RED}  ✗${NC} $msg" ;;
    skip) echo -e "${DIM}  ⊘ $msg${NC}" ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Timer
# ─────────────────────────────────────────────────────────────

now_seconds() {
  python3 -c 'import time; print(f"{time.time():.3f}")'
}

timer_elapsed() {
  local start="$1"
  local end
  end=$(now_seconds)
  local elapsed
  elapsed=$(python3 -c "
e = $end - $start
if e < 60:
    print(f'{e:.1f}s')
else:
    m = int(e // 60)
    s = int(e % 60)
    print(f'{m}m{s:02d}s')
")
  echo "$elapsed"
}

# ─────────────────────────────────────────────────────────────
# Trap + Cleanup
# ─────────────────────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  # Restore cursor
  [[ -t 1 ]] && printf "\033[?25h" 2>/dev/null || true
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    log_error "Migration failed. Log saved to: $LOG_FILE"
  fi
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────
# Argument Parsing
# ─────────────────────────────────────────────────────────────

show_help() {
  cat <<'USAGE'

  Supabase Migration Tool

  Migrates schema, data, auth users, storage files, and edge functions
  between two Supabase projects.

  USAGE
      ./migrate.sh [OPTIONS]

  OPTIONS
      --dry-run          Show what would happen without executing
      --skip-schema      Skip schema migration phase
      --skip-data        Skip data migration phase
      --skip-auth        Skip auth user migration
      --skip-storage     Skip storage file migration
      --skip-functions   Skip edge function deployment
      --no-confirm       Skip interactive confirmations (CI mode)
      --no-color         Disable colored output
      --help, -h         Show this help message
      --version, -v      Print version

  EXAMPLES
      ./migrate.sh                          # Full interactive migration
      ./migrate.sh --dry-run                # Preview migration plan
      ./migrate.sh --no-confirm             # Non-interactive (CI mode)
      ./migrate.sh --skip-auth --skip-storage   # Schema + data only

  ENVIRONMENT
      Reads configuration from .env file in the script directory.
      See .env.example for required variables and instructions.

USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)        DRY_RUN=true ;;
      --skip-schema)    SKIP_SCHEMA=true ;;
      --skip-data)      SKIP_DATA=true ;;
      --skip-auth)      SKIP_AUTH=true ;;
      --skip-storage)   SKIP_STORAGE=true ;;
      --skip-functions) SKIP_FUNCTIONS=true ;;
      --no-confirm)     NO_CONFIRM=true ;;
      --no-color)       NO_COLOR=true ;;
      --help|-h)        show_help; exit 0 ;;
      --version|-v)     echo "supabase-migrate v$VERSION"; exit 0 ;;
      *)                die "Unknown option: $1 (use --help for usage)" ;;
    esac
    shift
  done
}

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

confirm() {
  if [[ "$NO_CONFIRM" == "true" ]]; then
    return 0
  fi
  read -rp "$(echo -e "  ${YELLOW}?${NC} $1 ${DIM}[y/N]:${NC} ")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

dry_run_exec() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "${DIM}[DRY RUN]${NC} Would execute: $*"
    return 0
  fi
  "$@"
}

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────

show_banner() {
  echo ""
  echo -e "${BOLD}  ┌─────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │${NC}   ___                  _                ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  / __|_  _ _ __  __ _ | |__  __ _ ___  ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  \\__ \\ || | '_ \\/ _\` || '_ \\/ _\` (_-<  ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}  |___/\\_,_| .__/\\__,_||_.__/\\__,_/__/  ${BOLD}│${NC}"
  echo -e "${BOLD}  │${NC}           |_|    ${CYAN}Migration Tool${NC}        ${BOLD}│${NC}"
  echo -e "${BOLD}  └─────────────────────────────────────────┘${NC}"
  echo -e "  ${DIM}v${VERSION}${NC}"
}

# ═════════════════════════════════════════════════════════════
# Phase 1: Preflight
# ═════════════════════════════════════════════════════════════

phase_preflight() {
  local phase_start
  phase_start=$(now_seconds)
  step 1 "Preflight Checks"

  # Load .env
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
    log_success "Loaded .env"
  else
    die "No .env file found. Copy .env.example to .env and fill in your credentials."
  fi

  # Validate required variables
  local required_vars=(
    SOURCE_DB_URL SOURCE_PROJECT_REF SOURCE_SERVICE_ROLE_KEY SOURCE_PROJECT_URL
    DEST_DB_URL DEST_PROJECT_REF DEST_SERVICE_ROLE_KEY DEST_PROJECT_URL
  )
  local missing=()
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required variables: ${missing[*]}"
  fi
  log_success "All 8 required variables set"

  # Check dependencies
  local deps=("psql" "pg_dump" "curl" "jq")
  local missing_deps=()
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_deps+=("$cmd")
    fi
  done
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing_deps[*]}"
  fi
  log_success "Dependencies: ${deps[*]}"

  # Check supabase CLI (optional)
  if command -v supabase &>/dev/null; then
    log_success "Supabase CLI available (for edge functions)"
  else
    log_warn "Supabase CLI not found - edge functions phase will be limited"
  fi

  # Detect pg_dump version for \restrict stripping
  local pg_dump_version
  pg_dump_version=$(pg_dump --version | grep -oE '[0-9]+' | head -1)
  if [[ "$pg_dump_version" -ge 18 ]]; then
    NEEDS_RESTRICT_STRIP=true
    log_info "pg_dump v${pg_dump_version} detected - will strip backslash-restrict commands"
  else
    log_info "pg_dump v${pg_dump_version}"
  fi

  # Test database connections
  if [[ "$DRY_RUN" == "false" ]]; then
    spinner_start "Testing source database connection..."
    if PGCONNECT_TIMEOUT=10 psql "$SOURCE_DB_URL" -c "SELECT 1;" &>/dev/null; then
      spinner_stop ok "Source database connected"
    else
      spinner_stop fail "Source database connection failed"
      die "Cannot connect to source database. Check SOURCE_DB_URL."
    fi

    spinner_start "Testing destination database connection..."
    if PGCONNECT_TIMEOUT=10 psql "$DEST_DB_URL" -c "SELECT 1;" &>/dev/null; then
      spinner_stop ok "Destination database connected"
    else
      spinner_stop fail "Destination database connection failed"
      die "Cannot connect to destination database. Check DEST_DB_URL."
    fi
  else
    log_info "${DIM}[DRY RUN]${NC} Would test database connections"
  fi

  # Config summary
  echo ""
  log_info "Configuration:"
  echo -e "       Source:  ${BOLD}${SOURCE_PROJECT_URL}${NC}"
  echo -e "       Dest:    ${BOLD}${DEST_PROJECT_URL}${NC}"
  echo ""
  local skip_list=""
  [[ "$SKIP_SCHEMA" == "true" ]]    && skip_list+="schema "
  [[ "$SKIP_DATA" == "true" ]]      && skip_list+="data "
  [[ "$SKIP_AUTH" == "true" ]]      && skip_list+="auth "
  [[ "$SKIP_STORAGE" == "true" ]]   && skip_list+="storage "
  [[ "$SKIP_FUNCTIONS" == "true" ]] && skip_list+="functions "
  if [[ -n "$skip_list" ]]; then
    log_warn "Skipping: $skip_list"
  fi
  [[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN - no changes will be made"

  # Confirm
  if [[ "$DRY_RUN" == "false" ]]; then
    echo ""
    if ! confirm "Proceed with migration?"; then
      echo "  Aborted."
      exit 0
    fi
  fi

  PHASE_STATUS[0]="done"
  PHASE_TIME[0]=$(timer_elapsed "$phase_start")
  PHASE_DETAIL[0]="All checks passed"
}

# ═════════════════════════════════════════════════════════════
# Phase 2: Schema
# ═════════════════════════════════════════════════════════════

phase_schema() {
  if [[ "$SKIP_SCHEMA" == "true" ]]; then
    PHASE_STATUS[1]="skipped"
    PHASE_DETAIL[1]="--skip-schema"
    return 0
  fi

  local phase_start
  phase_start=$(now_seconds)
  step 2 "Schema Migration"

  # Dump schema
  spinner_start "Dumping public schema from source..."
  if [[ "$DRY_RUN" == "true" ]]; then
    spinner_stop ok "[DRY RUN] Would dump schema"
  else
    mkdir -p "$DUMP_DIR"
    pg_dump "$SOURCE_DB_URL" \
      --schema=public \
      --schema-only \
      --no-owner \
      --no-privileges \
      --no-comments \
      -f "$DUMP_DIR/schema.sql" 2>/dev/null

    spinner_stop ok "Schema dumped to dump/schema.sql"
  fi

  # Post-process
  if [[ "$DRY_RUN" == "false" ]]; then
    spinner_start "Post-processing schema dump..."

    # Strip \restrict / \unrestrict (pg_dump >= 18)
    if [[ "$NEEDS_RESTRICT_STRIP" == "true" ]]; then
      sed -i.bak '/^\\restrict$/d; /^\\unrestrict$/d' "$DUMP_DIR/schema.sql"
    fi

    # Strip CREATE SCHEMA "public" (already exists on destination)
    sed -i.bak '/^CREATE SCHEMA.*"public"/d' "$DUMP_DIR/schema.sql"

    # Clean up backup files
    rm -f "$DUMP_DIR/schema.sql.bak"

    local obj_count
    obj_count=$(grep -c "^CREATE " "$DUMP_DIR/schema.sql" 2>/dev/null || echo "0")
    spinner_stop ok "Post-processed - ${obj_count} CREATE statements"
    PHASE_DETAIL[1]="${obj_count} objects created"
  else
    PHASE_DETAIL[1]="[DRY RUN]"
  fi

  # Restore schema
  if [[ "$DRY_RUN" == "false" ]]; then
    spinner_start "Restoring schema to destination..."
    psql "$DEST_DB_URL" \
      --single-transaction \
      --variable ON_ERROR_STOP=1 \
      -f "$DUMP_DIR/schema.sql" &>/dev/null

    spinner_stop ok "Schema restored to destination"
  fi

  PHASE_STATUS[1]="done"
  PHASE_TIME[1]=$(timer_elapsed "$phase_start")
}

# ═════════════════════════════════════════════════════════════
# Phase 3: Data
# ═════════════════════════════════════════════════════════════

phase_data() {
  if [[ "$SKIP_DATA" == "true" ]]; then
    PHASE_STATUS[2]="skipped"
    PHASE_DETAIL[2]="--skip-data"
    return 0
  fi

  local phase_start
  phase_start=$(now_seconds)
  step 3 "Data Migration"

  # Public data
  spinner_start "Dumping public data..."
  if [[ "$DRY_RUN" == "true" ]]; then
    spinner_stop ok "[DRY RUN] Would dump public data"
  else
    mkdir -p "$DUMP_DIR"
    pg_dump "$SOURCE_DB_URL" \
      --schema=public \
      --data-only \
      --no-owner \
      --no-privileges \
      -f "$DUMP_DIR/public_data.sql" 2>/dev/null
    spinner_stop ok "Public data dumped"
  fi

  # Auth data
  if [[ "$SKIP_AUTH" == "true" ]]; then
    log_info "Skipping auth data (--skip-auth)"
  else
    spinner_start "Dumping auth data..."
    if [[ "$DRY_RUN" == "true" ]]; then
      spinner_stop ok "[DRY RUN] Would dump auth data"
    else
      pg_dump "$SOURCE_DB_URL" \
        --schema=auth \
        --data-only \
        --no-owner \
        --no-privileges \
        --exclude-table=auth.schema_migrations \
        -f "$DUMP_DIR/auth_data.sql" 2>/dev/null
      spinner_stop ok "Auth data dumped"
    fi
  fi

  # Storage metadata
  if [[ "$SKIP_STORAGE" == "true" ]]; then
    log_info "Skipping storage metadata (--skip-storage)"
  else
    spinner_start "Dumping storage metadata..."
    if [[ "$DRY_RUN" == "true" ]]; then
      spinner_stop ok "[DRY RUN] Would dump storage metadata"
    else
      pg_dump "$SOURCE_DB_URL" \
        --schema=storage \
        --data-only \
        --no-owner \
        --no-privileges \
        --exclude-table=storage.migrations \
        -f "$DUMP_DIR/storage_data.sql" 2>/dev/null
      spinner_stop ok "Storage metadata dumped"
    fi
  fi

  # Post-process: strip \restrict / \unrestrict
  if [[ "$DRY_RUN" == "false" && "$NEEDS_RESTRICT_STRIP" == "true" ]]; then
    for f in "$DUMP_DIR/public_data.sql" "$DUMP_DIR/auth_data.sql" "$DUMP_DIR/storage_data.sql"; do
      if [[ -f "$f" ]]; then
        sed -i.bak '/^\\restrict$/d; /^\\unrestrict$/d' "$f"
        rm -f "${f}.bak"
      fi
    done
  fi

  # Combine and restore
  if [[ "$DRY_RUN" == "false" ]]; then
    spinner_start "Building combined data file..."

    local combined="$DUMP_DIR/combined_data.sql"
    {
      echo "SET session_replication_role = replica;"
      echo ""
      cat "$DUMP_DIR/public_data.sql"
      [[ "$SKIP_AUTH" != "true" && -f "$DUMP_DIR/auth_data.sql" ]] && cat "$DUMP_DIR/auth_data.sql"
      [[ "$SKIP_STORAGE" != "true" && -f "$DUMP_DIR/storage_data.sql" ]] && cat "$DUMP_DIR/storage_data.sql"
      echo ""
      echo "SET session_replication_role = DEFAULT;"
    } > "$combined"

    spinner_stop ok "Combined data file built"

    spinner_start "Restoring data to destination..."
    psql "$DEST_DB_URL" \
      --single-transaction \
      --variable ON_ERROR_STOP=1 \
      -f "$combined" &>/dev/null

    spinner_stop ok "Data restored to destination"

    # Count rows for summary
    local row_count
    row_count=$(grep -c "^INSERT\|^COPY" "$combined" 2>/dev/null || echo "0")
    PHASE_DETAIL[2]="${row_count} statements executed"
  else
    PHASE_DETAIL[2]="[DRY RUN]"
  fi

  PHASE_STATUS[2]="done"
  PHASE_TIME[2]=$(timer_elapsed "$phase_start")
}

# ═════════════════════════════════════════════════════════════
# Phase 4: Storage Files
# ═════════════════════════════════════════════════════════════

# Recursive file listing for storage buckets
list_files_recursive() {
  local bucket="$1"
  local prefix="$2"
  local project_url="$3"
  local service_key="$4"

  local response
  response=$(curl -s \
    -X POST \
    -H "apikey: $service_key" \
    -H "Authorization: Bearer $service_key" \
    -H "Content-Type: application/json" \
    -d "{\"prefix\": \"$prefix\", \"limit\": 1000}" \
    "$project_url/storage/v1/object/list/$bucket")

  # Items with an "id" field are files; items without are folders
  local files
  files=$(echo "$response" | jq -r '.[] | select(.id != null) | .name // empty' 2>/dev/null)

  local folders
  folders=$(echo "$response" | jq -r '.[] | select(.id == null) | .name // empty' 2>/dev/null)

  # Output files with their full prefix path
  for file in $files; do
    if [[ -n "$prefix" ]]; then
      echo "${prefix}${file}"
    else
      echo "$file"
    fi
  done

  # Recurse into folders
  for folder in $folders; do
    local new_prefix
    if [[ -n "$prefix" ]]; then
      new_prefix="${prefix}${folder}/"
    else
      new_prefix="${folder}/"
    fi
    list_files_recursive "$bucket" "$new_prefix" "$project_url" "$service_key"
  done
}

phase_storage() {
  if [[ "$SKIP_STORAGE" == "true" ]]; then
    PHASE_STATUS[3]="skipped"
    PHASE_DETAIL[3]="--skip-storage"
    return 0
  fi

  local phase_start
  phase_start=$(now_seconds)
  step 4 "Storage Migration"

  # List buckets
  spinner_start "Fetching buckets from source..."
  if [[ "$DRY_RUN" == "true" ]]; then
    spinner_stop ok "[DRY RUN] Would fetch bucket list"
    PHASE_STATUS[3]="done"
    PHASE_TIME[3]=$(timer_elapsed "$phase_start")
    PHASE_DETAIL[3]="[DRY RUN]"
    return 0
  fi

  local buckets_json
  buckets_json=$(curl -s \
    -H "apikey: $SOURCE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SOURCE_SERVICE_ROLE_KEY" \
    "$SOURCE_PROJECT_URL/storage/v1/bucket")

  local bucket_count
  bucket_count=$(echo "$buckets_json" | jq 'length' 2>/dev/null || echo "0")

  if [[ "$bucket_count" == "0" ]]; then
    spinner_stop skip "No storage buckets found"
    PHASE_STATUS[3]="skipped"
    PHASE_DETAIL[3]="No buckets found"
    PHASE_TIME[3]=$(timer_elapsed "$phase_start")
    return 0
  fi

  local bucket_names
  bucket_names=$(echo "$buckets_json" | jq -r '.[].name')
  spinner_stop ok "Found ${bucket_count} bucket(s)"

  mkdir -p "$STORAGE_DIR"
  local total_files=0

  for bucket in $bucket_names; do
    log_info "Processing bucket: ${BOLD}$bucket${NC}"

    # Get bucket metadata
    local is_public file_size_limit allowed_mime_types
    is_public=$(echo "$buckets_json" | jq -r --arg b "$bucket" '.[] | select(.name == $b) | .public')
    file_size_limit=$(echo "$buckets_json" | jq -r --arg b "$bucket" '.[] | select(.name == $b) | .file_size_limit // empty')
    allowed_mime_types=$(echo "$buckets_json" | jq -c --arg b "$bucket" '.[] | select(.name == $b) | .allowed_mime_types // empty')

    # Create bucket on destination
    local create_body="{\"id\": \"$bucket\", \"name\": \"$bucket\", \"public\": $is_public"
    if [[ -n "$file_size_limit" && "$file_size_limit" != "null" ]]; then
      create_body="$create_body, \"file_size_limit\": $file_size_limit"
    fi
    if [[ -n "$allowed_mime_types" && "$allowed_mime_types" != "null" && "$allowed_mime_types" != "" ]]; then
      create_body="$create_body, \"allowed_mime_types\": $allowed_mime_types"
    fi
    create_body="$create_body}"

    local create_response create_status
    create_response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "apikey: $DEST_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $DEST_SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" \
      -d "$create_body" \
      "$DEST_PROJECT_URL/storage/v1/bucket")

    create_status=$(echo "$create_response" | tail -1)
    if [[ "$create_status" == "200" || "$create_status" == "201" ]]; then
      log_success "Created bucket '$bucket'"
    else
      local create_body_text
      create_body_text=$(echo "$create_response" | sed '$d')
      if echo "$create_body_text" | grep -q "already exists" 2>/dev/null; then
        log_warn "Bucket '$bucket' already exists, continuing"
      else
        log_warn "Bucket creation (HTTP $create_status): $create_body_text"
      fi
    fi

    # List all files recursively
    local files_list
    files_list=$(list_files_recursive "$bucket" "" "$SOURCE_PROJECT_URL" "$SOURCE_SERVICE_ROLE_KEY")

    if [[ -z "$files_list" ]]; then
      log_warn "No files in bucket '$bucket'"
      continue
    fi

    local file_count
    file_count=$(echo "$files_list" | wc -l | tr -d ' ')
    log_info "Found $file_count file(s) in '$bucket'"

    # Download and upload each file
    local current=0
    while IFS= read -r file_path; do
      [[ -z "$file_path" ]] && continue
      current=$((current + 1))
      total_files=$((total_files + 1))

      # Create local directory structure
      local local_path="$STORAGE_DIR/$bucket/$file_path"
      mkdir -p "$(dirname "$local_path")"

      # Download
      curl -s \
        -H "apikey: $SOURCE_SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $SOURCE_SERVICE_ROLE_KEY" \
        -o "$local_path" \
        "$SOURCE_PROJECT_URL/storage/v1/object/$bucket/$file_path"

      # Upload
      local upload_response upload_status
      upload_response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "apikey: $DEST_SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $DEST_SERVICE_ROLE_KEY" \
        -F "file=@$local_path" \
        "$DEST_PROJECT_URL/storage/v1/object/$bucket/$file_path")

      upload_status=$(echo "$upload_response" | tail -1)
      if [[ "$upload_status" == "200" || "$upload_status" == "201" ]]; then
        log_success "[$current/$file_count] $bucket/$file_path"
      else
        log_warn "[$current/$file_count] Upload HTTP $upload_status: $bucket/$file_path"
      fi
    done <<< "$files_list"

    log_success "Bucket '$bucket' complete"
  done

  # Cleanup temp storage
  rm -rf "$STORAGE_DIR"
  log_info "Cleaned up temp storage directory"

  PHASE_STATUS[3]="done"
  PHASE_TIME[3]=$(timer_elapsed "$phase_start")
  PHASE_DETAIL[3]="${total_files} files in ${bucket_count} bucket(s)"
}

# ═════════════════════════════════════════════════════════════
# Phase 5: Edge Functions
# ═════════════════════════════════════════════════════════════

phase_functions() {
  if [[ "$SKIP_FUNCTIONS" == "true" ]]; then
    PHASE_STATUS[4]="skipped"
    PHASE_DETAIL[4]="--skip-functions"
    return 0
  fi

  local phase_start
  phase_start=$(now_seconds)
  step 5 "Edge Functions"

  local functions_dir="$SCRIPT_DIR/supabase/functions"

  if [[ ! -d "$functions_dir" ]]; then
    log_info "No local supabase/functions/ directory found"

    if command -v supabase &>/dev/null; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would attempt to download functions from source"
      else
        spinner_start "Attempting to download functions from source..."
        if supabase functions download --project-ref "$SOURCE_PROJECT_REF" 2>/dev/null; then
          spinner_stop ok "Functions downloaded"
        else
          spinner_stop skip "No functions to download"
          PHASE_STATUS[4]="skipped"
          PHASE_TIME[4]=$(timer_elapsed "$phase_start")
          PHASE_DETAIL[4]="No functions found"
          return 0
        fi
      fi
    else
      log_warn "Supabase CLI not installed - cannot download functions"
      PHASE_STATUS[4]="skipped"
      PHASE_TIME[4]=$(timer_elapsed "$phase_start")
      PHASE_DETAIL[4]="No CLI + no local functions"
      return 0
    fi
  fi

  if [[ ! -d "$functions_dir" ]]; then
    PHASE_STATUS[4]="skipped"
    PHASE_TIME[4]=$(timer_elapsed "$phase_start")
    PHASE_DETAIL[4]="No functions found"
    return 0
  fi

  local func_count=0
  local deployed=0

  for func_dir in "$functions_dir"/*/; do
    [[ -d "$func_dir" ]] || continue
    local func_name
    func_name=$(basename "$func_dir")
    func_count=$((func_count + 1))

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would deploy: $func_name"
      deployed=$((deployed + 1))
    else
      spinner_start "Deploying: $func_name"
      if supabase functions deploy "$func_name" --project-ref "$DEST_PROJECT_REF" 2>/dev/null; then
        spinner_stop ok "Deployed: $func_name"
        deployed=$((deployed + 1))
      else
        spinner_stop fail "Failed: $func_name"
      fi
    fi
  done

  if [[ $func_count -gt 0 ]]; then
    echo ""
    log_warn "Edge function secrets are NOT migrated automatically."
    log_warn "Set them with: supabase secrets set KEY=VALUE --project-ref $DEST_PROJECT_REF"
  fi

  PHASE_STATUS[4]="done"
  PHASE_TIME[4]=$(timer_elapsed "$phase_start")
  PHASE_DETAIL[4]="${deployed}/${func_count} deployed"
}

# ═════════════════════════════════════════════════════════════
# Phase 6: Verify
# ═════════════════════════════════════════════════════════════

phase_verify() {
  local phase_start
  phase_start=$(now_seconds)
  step 6 "Verification"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would compare row counts between source and destination"
    PHASE_STATUS[5]="done"
    PHASE_TIME[5]=$(timer_elapsed "$phase_start")
    PHASE_DETAIL[5]="[DRY RUN]"
    return 0
  fi

  spinner_start "Fetching row counts from source..."

  # Get all table counts from source in a single query
  local src_counts
  src_counts=$(psql "$SOURCE_DB_URL" -t -A -c "
    SELECT schemaname || '.' || tablename || '|' ||
           (xpath('/row/cnt/text()',
            query_to_xml('SELECT count(*) AS cnt FROM ' || schemaname || '.' || tablename, false, true, '')))[1]::text
    FROM pg_tables
    WHERE schemaname IN ('public', 'auth')
    ORDER BY schemaname, tablename;
  " 2>/dev/null || echo "")

  spinner_stop ok "Source counts fetched"

  if [[ -z "$src_counts" ]]; then
    log_warn "Could not fetch source table counts"
    PHASE_STATUS[5]="done"
    PHASE_TIME[5]=$(timer_elapsed "$phase_start")
    PHASE_DETAIL[5]="Could not verify"
    return 0
  fi

  spinner_start "Fetching row counts from destination..."

  local dst_counts
  dst_counts=$(psql "$DEST_DB_URL" -t -A -c "
    SELECT schemaname || '.' || tablename || '|' ||
           (xpath('/row/cnt/text()',
            query_to_xml('SELECT count(*) AS cnt FROM ' || schemaname || '.' || tablename, false, true, '')))[1]::text
    FROM pg_tables
    WHERE schemaname IN ('public', 'auth')
    ORDER BY schemaname, tablename;
  " 2>/dev/null || echo "")

  spinner_stop ok "Destination counts fetched"

  # Build comparison table
  echo ""
  printf "  ${BOLD}%-40s %10s %10s %s${NC}\n" "TABLE" "SOURCE" "DEST" "STATUS"
  printf "  %-40s %10s %10s %s\n" "$(printf '%.0s─' {1..40})" "──────────" "──────────" "──────"

  local mismatch_count=0

  # Compare line by line (no associative arrays - Bash 3 compatible)
  while IFS='|' read -r table src_c; do
    [[ -z "$table" ]] && continue
    # Find matching table in destination counts
    local dst_c
    dst_c=$(echo "$dst_counts" | grep "^${table}|" | cut -d'|' -f2)
    dst_c="${dst_c:-N/A}"
    local status_mark

    if [[ "$src_c" == "$dst_c" ]]; then
      status_mark="${GREEN}✓${NC}"
    else
      status_mark="${RED}✗${NC}"
      mismatch_count=$((mismatch_count + 1))
    fi

    printf "  %-40s %10s %10s $(echo -e "$status_mark")\n" "$table" "$src_c" "$dst_c"
  done <<< "$src_counts"

  echo ""
  if [[ $mismatch_count -eq 0 ]]; then
    log_success "All table row counts match"
    PHASE_DETAIL[5]="All counts match"
  else
    log_warn "${mismatch_count} table(s) with mismatched counts"
    PHASE_DETAIL[5]="${mismatch_count} mismatches"
  fi

  # Check storage buckets on destination
  if [[ "$SKIP_STORAGE" != "true" ]]; then
    echo ""
    log_info "Storage buckets on destination:"
    local dest_buckets
    dest_buckets=$(curl -s \
      -H "apikey: $DEST_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $DEST_SERVICE_ROLE_KEY" \
      "$DEST_PROJECT_URL/storage/v1/bucket")
    echo "$dest_buckets" | jq -r '.[] | "    - \(.name) (public: \(.public))"' 2>/dev/null || true
  fi

  PHASE_STATUS[5]="done"
  PHASE_TIME[5]=$(timer_elapsed "$phase_start")
}

# ═════════════════════════════════════════════════════════════
# Summary Table
# ═════════════════════════════════════════════════════════════

print_summary() {
  local total_start="$1"
  local total_time
  total_time=$(timer_elapsed "$total_start")

  echo ""
  echo -e "${BOLD}  ╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}  ║                      Migration Summary                      ║${NC}"
  echo -e "${BOLD}  ╠══════════════════════════════════════════════════════════════╣${NC}"
  printf "  ${BOLD}║${NC}  %-14s %-13s %-10s %-21s${BOLD}║${NC}\n" "Phase" "Status" "Time" "Details"
  printf "  ${BOLD}║${NC}  %-14s %-13s %-10s %-21s${BOLD}║${NC}\n" "──────────────" "─────────────" "──────────" "─────────────────────"

  for i in "${!PHASES[@]}"; do
    local phase_name="${PHASES[$i]}"
    local status="${PHASE_STATUS[$i]}"
    local time="${PHASE_TIME[$i]:--}"
    local detail="${PHASE_DETAIL[$i]:-}"
    local status_display

    case "$status" in
      done)    status_display="${GREEN}✓ Done${NC}   " ;;
      skipped) status_display="${DIM}⊘ Skipped${NC}" ; time="-" ;;
      failed)  status_display="${RED}✗ Failed${NC} " ;;
      *)       status_display="${DIM}· Pending${NC}" ; time="-" ;;
    esac

    printf "  ${BOLD}║${NC}  %-14s $(echo -e "$status_display")  %-10s %-21s${BOLD}║${NC}\n" "$phase_name" "$time" "$detail"
  done

  echo -e "${BOLD}  ╠══════════════════════════════════════════════════════════════╣${NC}"

  # Determine overall status
  local overall="Migration complete"
  for s in "${PHASE_STATUS[@]}"; do
    if [[ "$s" == "failed" ]]; then
      overall="Migration had errors"
      break
    fi
  done
  [[ "$DRY_RUN" == "true" ]] && overall="Dry run complete"

  printf "  ${BOLD}║${NC}  %-14s %-13s %-10s %-21s${BOLD}║${NC}\n" "Total" "" "$total_time" "$overall"
  echo -e "${BOLD}  ╚══════════════════════════════════════════════════════════════╝${NC}"
}

# ═════════════════════════════════════════════════════════════
# Post-Migration Checklist
# ═════════════════════════════════════════════════════════════

print_checklist() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  echo ""
  echo -e "  ${BOLD}Post-migration checklist:${NC}"
  echo ""
  echo "    □  Test login as an existing user (password hashes are preserved)"
  echo "    □  Verify RLS policies are active on destination"
  echo "    □  Access a stored file URL on the destination"
  echo "    □  Test edge function endpoints"
  echo "    □  Re-enable Realtime publications (Dashboard > Database > Replication)"
  echo "    □  Re-enable Database Webhooks (Dashboard > Database > Webhooks)"
  echo "    □  Set edge function secrets: supabase secrets set KEY=VALUE --project-ref $DEST_PROJECT_REF"
  echo "    □  Update client apps with new project URL and anon key"
  echo "    □  Monitor destination before cancelling source"
  echo ""
  echo -e "  ${DIM}Log saved to: $LOG_FILE${NC}"
  echo -e "  ${DIM}Dump files in: $DUMP_DIR${NC}"
  echo ""
}

# ═════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════

main() {
  parse_args "$@"
  setup_colors
  setup_logging
  show_banner

  local migration_start
  migration_start=$(now_seconds)

  phase_preflight

  phase_schema || { PHASE_STATUS[1]="failed"; PHASE_DETAIL[1]="Error"; true; }
  phase_data || { PHASE_STATUS[2]="failed"; PHASE_DETAIL[2]="Error"; true; }
  phase_storage || { PHASE_STATUS[3]="failed"; PHASE_DETAIL[3]="Error"; true; }
  phase_functions || { PHASE_STATUS[4]="failed"; PHASE_DETAIL[4]="Error"; true; }
  phase_verify || { PHASE_STATUS[5]="failed"; PHASE_DETAIL[5]="Error"; true; }

  print_summary "$migration_start"
  print_checklist
}

main "$@"

#!/bin/bash
#
# CMDBuild Developer Deploy Script
# =================================
# Detects which Java files changed, builds only the affected Maven modules,
# and hot-deploys the JARs into the running Docker container.
#
# Usage:
#   ./dev-deploy.sh                  # Build & deploy all changed modules
#   ./dev-deploy.sh dao/postgresql   # Build & deploy specific module
#   ./dev-deploy.sh --restart        # Build, deploy & restart Tomcat
#   ./dev-deploy.sh --full           # Full WAR rebuild with cohesive-cmdbuild-builder
#   ./dev-deploy.sh --status         # Show environment status
#
# The script works with the exploded webapp in ./webapp/ and the
# Docker Compose setup in ./docker-compose.yml.

set -euo pipefail

# Configuration - all paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/source"
WEBAPP_LIB="$SCRIPT_DIR/webapp/WEB-INF/lib"
WAR_BUILDER_DIR="$SCRIPT_DIR/war-builder"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"

# Load .env if present
[ -f "$SCRIPT_DIR/.env" ] && set -a && source "$SCRIPT_DIR/.env" && set +a

# Export UID/GID for docker-compose
export UID="$(id -u)"
export GID="$(id -g)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[dev]${NC} $*"; }
warn() { echo -e "${YELLOW}[dev]${NC} $*"; }
err()  { echo -e "${RED}[dev]${NC} $*" >&2; }

# ─── Module Map: source directory → artifact ID ───
declare -A MODULE_MAP
build_module_map() {
    if [ ! -d "$SRC_DIR" ]; then
        err "Source directory not found: $SRC_DIR"
        err "Run ./setup.sh first"
        exit 1
    fi
    while IFS='|' read -r dir aid; do
        MODULE_MAP["$dir"]="$aid"
    done < <(cd "$SRC_DIR" && python3 << 'PYEOF'
import os, xml.etree.ElementTree as ET
ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d != 'target']
    if 'pom.xml' in files and os.path.isdir(os.path.join(root, 'src', 'main', 'java')):
        try:
            tree = ET.parse(os.path.join(root, 'pom.xml'))
            a = tree.find('m:artifactId', ns)
            if a is not None:
                print(f"{root}|{a.text}")
        except: pass
PYEOF
    )
}

# ─── Find which modules have changed files ───
detect_changed_modules() {
    local changed_modules=()

    local changed_files
    changed_files=$(cd "$SRC_DIR" && git diff --name-only HEAD -- '*.java' 2>/dev/null)

    if [ -z "$changed_files" ]; then
        changed_files=$(cd "$SRC_DIR" && git diff --cached --name-only -- '*.java' 2>/dev/null)
    fi

    if [ -z "$changed_files" ]; then
        changed_files=$(cd "$SRC_DIR" && git diff --name-only -- '*.java' 2>/dev/null)
        local untracked
        untracked=$(cd "$SRC_DIR" && git ls-files --others --exclude-standard -- '*.java' 2>/dev/null)
        changed_files="$changed_files"$'\n'"$untracked"
    fi

    [ -z "$changed_files" ] && return

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        for mod_dir in "${!MODULE_MAP[@]}"; do
            clean_dir="${mod_dir#./}"
            if [[ "$file" == "$clean_dir/"* ]]; then
                local already=false
                for m in "${changed_modules[@]+"${changed_modules[@]}"}"; do
                    [ "$m" = "$mod_dir" ] && already=true && break
                done
                $already || changed_modules+=("$mod_dir")
                break
            fi
        done
    done <<< "$changed_files"

    printf '%s\n' "${changed_modules[@]+"${changed_modules[@]}"}"
}

# ─── Build a single Maven module ───
build_module() {
    local module_dir="$1"
    local clean_dir="${module_dir#./}"
    local artifact_id="${MODULE_MAP[$module_dir]:-unknown}"

    log "Building ${CYAN}$artifact_id${NC} ($clean_dir)"

    (cd "$SRC_DIR" && mvn package \
        -pl "$clean_dir" \
        -am \
        -Dmaven.test.skip=true \
        -q \
        2>&1) || {
        err "Build FAILED for $artifact_id"
        return 1
    }

    log "Build OK: ${CYAN}$artifact_id${NC}"
}

# ─── Deploy a built JAR to webapp ───
deploy_jar() {
    local module_dir="$1"
    local clean_dir="${module_dir#./}"
    local artifact_id="${MODULE_MAP[$module_dir]:-unknown}"

    local jar
    jar=$(find "$SRC_DIR/$clean_dir/target" -maxdepth 1 -name "*.jar" \
        -not -name "*-sources.jar" \
        -not -name "*-tests.jar" \
        -not -name "*-test-*.jar" \
        2>/dev/null | head -1)

    if [ -z "$jar" ]; then
        err "No JAR found for $artifact_id in $clean_dir/target/"
        return 1
    fi

    local jar_name
    jar_name=$(basename "$jar")

    if [ -f "$WEBAPP_LIB/$jar_name" ]; then
        local old_size new_size
        old_size=$(stat -c%s "$WEBAPP_LIB/$jar_name")
        new_size=$(stat -c%s "$jar")
        cp "$jar" "$WEBAPP_LIB/$jar_name"
        log "Deployed ${CYAN}$jar_name${NC} ($old_size -> $new_size bytes)"
    else
        cp "$jar" "$WEBAPP_LIB/"
        warn "Deployed NEW ${CYAN}$jar_name${NC} (was not in webapp)"
    fi
}

# ─── Restart Tomcat container ───
restart_container() {
    log "Restarting Tomcat..."
    $COMPOSE restart cmdbuild 2>/dev/null
    log "Waiting for CMDBuild to start..."

    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if $COMPOSE exec cmdbuild grep -q "READY" /usr/local/tomcat/logs/cmdbuild.log 2>/dev/null; then
            local ready_count
            ready_count=$($COMPOSE exec cmdbuild grep -c "READY" /usr/local/tomcat/logs/cmdbuild.log 2>/dev/null || echo 0)
            if [ "$ready_count" -gt 0 ]; then
                echo
                log "${GREEN}CMDBuild READY${NC}"
                return 0
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        printf "."
    done
    echo
    warn "Timeout waiting for READY (${max_wait}s). Check logs: docker compose logs -f"
}

# ─── Full WAR rebuild ───
full_rebuild() {
    if [ ! -d "$WAR_BUILDER_DIR" ]; then
        log "Cloning cohesive-cmdbuild-builder..."
        git clone https://github.com/genpat-it/cohesive-cmdbuild-builder.git "$WAR_BUILDER_DIR"
    fi

    log "Starting full WAR rebuild with cohesive-cmdbuild-builder..."

    local branch
    branch=$(cd "$SRC_DIR" && git branch --show-current)
    local repo="${GIT_REPO:-https://github.com/genpat-it/cohesive-cmdbuild}"
    local token="${GIT_TOKEN:-}"

    (cd "$WAR_BUILDER_DIR" && \
        GIT_REPO="$repo" \
        GIT_BRANCH="$branch" \
        GIT_TOKEN="$token" \
        ./build-war.sh)

    local war
    war=$(ls -t "$WAR_BUILDER_DIR/output/"cohesive-*.war 2>/dev/null | head -1)

    if [ -z "$war" ]; then
        err "WAR build failed - no output file"
        exit 1
    fi

    log "Extracting WAR to webapp..."
    $COMPOSE down 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/webapp"
    mkdir -p "$SCRIPT_DIR/webapp"
    (cd "$SCRIPT_DIR/webapp" && unzip -qo "$war")

    # Ensure PostgreSQL driver is in lib
    if [ -d "$SCRIPT_DIR/webapp/WEB-INF/lib_ext" ]; then
        cp "$SCRIPT_DIR/webapp"/WEB-INF/lib_ext/postgresql-*.jar \
           "$SCRIPT_DIR/webapp/WEB-INF/lib/" 2>/dev/null || true
    fi

    # Ensure bus dir exists
    mkdir -p "$SCRIPT_DIR/webapp/WEB-INF/conf/bus"

    log "Starting container..."
    docker volume rm cohesive-cmdbuild-dev_cmdbuild_logs cohesive-cmdbuild-dev_cmdbuild_work 2>/dev/null || true
    $COMPOSE up -d
    restart_container
}

# ─── Status ───
show_status() {
    echo
    echo -e "${CYAN}=== CMDBuild Dev Environment ===${NC}"
    echo -e "Root:      $SCRIPT_DIR"

    if [ -d "$SRC_DIR/.git" ]; then
        echo -e "Source:    $SRC_DIR"
        echo -e "Branch:    $(cd "$SRC_DIR" && git branch --show-current)"
    else
        echo -e "Source:    ${RED}not cloned${NC} (run ./setup.sh)"
    fi

    echo -e "Webapp:    $WEBAPP_LIB"
    echo

    local status
    status=$($COMPOSE ps --format '{{.Status}}' 2>/dev/null || echo "not running")
    echo -e "Container: $status"

    if [ -d "$SRC_DIR/.git" ]; then
        build_module_map
        local modules
        modules=$(detect_changed_modules)
        if [ -n "$modules" ]; then
            echo -e "\n${YELLOW}Changed modules:${NC}"
            while IFS= read -r mod; do
                local clean="${mod#./}"
                echo -e "  ${CYAN}${MODULE_MAP[$mod]:-?}${NC}  ($clean)"
            done <<< "$modules"
        else
            echo -e "\n${GREEN}No changed modules${NC}"
        fi
    fi
    echo
}

# ─── Main ───
main() {
    case "${1:-}" in
        --status|-s)
            show_status
            exit 0
            ;;
        --full|-f)
            full_rebuild
            exit 0
            ;;
        --restart|-r)
            local do_restart=true
            shift || true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [MODULE_DIR...]"
            echo
            echo "Options:"
            echo "  (no args)           Auto-detect changed modules, build & deploy JARs"
            echo "  MODULE_DIR          Build & deploy specific module(s), e.g. dao/postgresql"
            echo "  --restart, -r       Also restart Tomcat after deploying"
            echo "  --full, -f          Full WAR rebuild with cohesive-cmdbuild-builder"
            echo "  --status, -s        Show environment status and changed modules"
            echo "  --help, -h          Show this help"
            echo
            echo "Examples:"
            echo "  $0                          # Auto-detect & deploy changed modules"
            echo "  $0 dao/postgresql            # Build & deploy specific module"
            echo "  $0 -r auth/login core/all    # Build, deploy & restart"
            echo "  $0 --full                    # Full WAR rebuild"
            exit 0
            ;;
        *)
            local do_restart=false
            ;;
    esac

    if [ ! -d "$SRC_DIR" ]; then
        err "Source directory not found: $SRC_DIR"
        err "Run ./setup.sh first"
        exit 1
    fi

    cd "$SRC_DIR"
    build_module_map

    local modules=()

    if [ $# -gt 0 ] && [ "${1:0:1}" != "-" ]; then
        for arg in "$@"; do
            local clean="./$arg"
            clean="${clean%/}"
            if [ -n "${MODULE_MAP[$clean]:-}" ]; then
                modules+=("$clean")
            else
                err "Unknown module: $arg"
                err "Available: ${!MODULE_MAP[*]}"
                exit 1
            fi
        done
    else
        local detected
        detected=$(detect_changed_modules)
        if [ -n "$detected" ]; then
            while IFS= read -r mod; do
                modules+=("$mod")
            done <<< "$detected"
        fi
    fi

    if [ ${#modules[@]} -eq 0 ]; then
        warn "No changed modules detected. Nothing to build."
        warn "Specify a module explicitly: $0 dao/postgresql"
        exit 0
    fi

    local failed=0
    local start_time=$SECONDS

    for mod in "${modules[@]}"; do
        build_module "$mod" && deploy_jar "$mod" || ((failed++))
    done

    local elapsed=$((SECONDS - start_time))

    if [ $failed -gt 0 ]; then
        err "$failed module(s) failed"
        exit 1
    fi

    log "All ${#modules[@]} module(s) built and deployed in ${elapsed}s"

    if [ "${do_restart:-false}" = true ]; then
        restart_container
    else
        warn "JARs deployed. Restart with: $0 --restart"
    fi
}

main "$@"

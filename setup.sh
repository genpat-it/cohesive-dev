#!/bin/bash
#
# CMDBuild Development Environment - First-time Setup
# ====================================================
# Clones the source code, builds the WAR, extracts it, and starts the container.
#
# Prerequisites: Docker, JDK 17, Maven, Python 3, Git
#
# Configuration (env vars or .env file):
#   GIT_REPO     - Source repository URL (default: https://github.com/genpat-it/cohesive-cmdbuild)
#   GIT_BRANCH   - Branch to clone (default: main)
#   GIT_TOKEN    - Auth token for private repos (optional)
#   DB_URL       - PostgreSQL JDBC URL
#   DB_USER      - Database username
#   DB_PASS      - Database password
#
# Usage:
#   ./setup.sh                    # Interactive setup
#   GIT_BRANCH=develop ./setup.sh # Clone specific branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env if present
[ -f .env ] && set -a && source .env && set +a

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup]${NC} $*" >&2; }

# ─── Check prerequisites ───
check_prereqs() {
    local missing=()
    command -v docker >/dev/null    || missing+=("docker")
    command -v mvn >/dev/null       || missing+=("maven")
    command -v java >/dev/null      || missing+=("java (JDK 17)")
    command -v python3 >/dev/null   || missing+=("python3")
    command -v git >/dev/null       || missing+=("git")

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing prerequisites: ${missing[*]}"
        exit 1
    fi

    local java_ver
    java_ver=$(java -version 2>&1 | head -1 | grep -oP '"\K[^"]+' | cut -d. -f1)
    if [ "$java_ver" -lt 17 ] 2>/dev/null; then
        warn "Java 17+ recommended (detected: $java_ver)"
    fi

    log "All prerequisites found"
}

# ─── Clone source code ───
clone_source() {
    local repo="${GIT_REPO:-https://github.com/genpat-it/cohesive-cmdbuild}"
    local branch="${GIT_BRANCH:-main}"
    local token="${GIT_TOKEN:-}"

    if [ -d source/.git ]; then
        log "Source already cloned at ./source/"
        log "Current branch: $(cd source && git branch --show-current)"
        return 0
    fi

    log "Cloning ${CYAN}$repo${NC} (branch: ${CYAN}$branch${NC}) into ./source/"

    local clone_url="$repo"
    if [ -n "$token" ]; then
        # Insert token into URL for authentication
        clone_url="${repo/https:\/\//https:\/\/token:${token}@}"
    fi

    git clone --branch "$branch" --single-branch "$clone_url" source
    log "Source cloned successfully"
}

# ─── Clone war-builder ───
clone_war_builder() {
    if [ -d war-builder/.git ]; then
        log "war-builder already present at ./war-builder/"
        return 0
    fi

    log "Cloning cohesive-cmdbuild-builder into ./war-builder/"
    git clone https://github.com/genpat-it/cohesive-cmdbuild-builder.git war-builder
    log "war-builder cloned"
}

# ─── Build WAR ───
build_war() {
    log "Building WAR with cohesive-cmdbuild-builder..."

    local branch
    branch=$(cd source && git branch --show-current)

    # Point war-builder at our local source
    local repo="${GIT_REPO:-https://github.com/genpat-it/cohesive-cmdbuild}"
    local token="${GIT_TOKEN:-}"

    (cd war-builder && \
        GIT_REPO="$repo" \
        GIT_BRANCH="$branch" \
        GIT_TOKEN="$token" \
        ./build-war.sh)

    local war
    war=$(ls -t war-builder/output/cohesive-*.war 2>/dev/null | head -1)

    if [ -z "$war" ]; then
        err "WAR build failed - no output file found in war-builder/output/"
        exit 1
    fi

    log "WAR built: ${CYAN}$(basename "$war")${NC}"
    echo "$war"
}

# ─── Extract WAR ───
extract_war() {
    local war="$1"

    log "Extracting WAR to ./webapp/"
    rm -rf webapp
    mkdir -p webapp
    (cd webapp && unzip -qo "$SCRIPT_DIR/$war")

    # Copy PostgreSQL driver from lib_ext to lib
    if [ -d webapp/WEB-INF/lib_ext ]; then
        cp webapp/WEB-INF/lib_ext/postgresql-*.jar webapp/WEB-INF/lib/ 2>/dev/null || true
        log "PostgreSQL driver copied to WEB-INF/lib"
    fi

    # Create required directories
    mkdir -p webapp/WEB-INF/conf/bus

    log "Webapp extracted"
}

# ─── Setup database config ───
setup_database_conf() {
    if [ -f conf/database.conf ]; then
        log "conf/database.conf already exists"
        return 0
    fi

    local db_url="${DB_URL:-}"
    local db_user="${DB_USER:-}"
    local db_pass="${DB_PASS:-}"

    if [ -n "$db_url" ] && [ -n "$db_user" ] && [ -n "$db_pass" ]; then
        cat > conf/database.conf << EOF
db.url=$db_url
db.username=$db_user
db.password=$db_pass
db.admin.username=$db_user
db.admin.password=$db_pass
EOF
        log "conf/database.conf created from env vars"
    else
        cp conf/database.conf.example conf/database.conf
        warn "Created conf/database.conf from example template"
        warn "Edit conf/database.conf with your database connection details before starting!"
        echo
        echo -e "  ${CYAN}vi conf/database.conf${NC}"
        echo
        read -rp "Press Enter after editing database.conf (or Ctrl+C to abort)..."
    fi
}

# ─── Start container ───
start_container() {
    log "Starting Docker container..."

    # Export UID/GID for docker-compose
    export UID="$(id -u)"
    export GID="$(id -g)"

    # Clean up old volumes if they exist
    docker compose down 2>/dev/null || true
    docker volume rm cohesive-cmdbuild-dev_cmdbuild_logs cohesive-cmdbuild-dev_cmdbuild_work 2>/dev/null || true

    docker compose up -d

    log "Container started, waiting for CMDBuild to be READY..."

    local max_wait=180
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if docker compose exec cmdbuild grep -q "READY" /usr/local/tomcat/logs/cmdbuild.log 2>/dev/null; then
            echo
            log "${GREEN}CMDBuild is READY!${NC}"
            echo
            echo -e "  Open ${CYAN}http://localhost:8080/cmdbuild${NC} in your browser"
            echo -e "  Default login: ${CYAN}admin / admin${NC}"
            echo
            echo -e "  Daily workflow: ${CYAN}./dev-deploy.sh${NC}"
            echo -e "  Restart:        ${CYAN}./dev-deploy.sh -r${NC}"
            echo -e "  Full rebuild:   ${CYAN}./dev-deploy.sh -f${NC}"
            echo -e "  Status:         ${CYAN}./dev-deploy.sh -s${NC}"
            echo -e "  Logs:           ${CYAN}docker compose logs -f${NC}"
            echo
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        printf "."
    done

    echo
    warn "Timeout waiting for READY (${max_wait}s)"
    warn "Check logs: docker compose logs -f"
    warn "CMDBuild may still be initializing the database on first run."
}

# ─── Main ───
main() {
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}CMDBuild Dev Environment Setup${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo

    check_prereqs
    clone_source
    clone_war_builder

    local war
    war=$(build_war | tail -1)
    extract_war "$war"

    setup_database_conf
    start_container

    log "Setup complete!"
}

main "$@"

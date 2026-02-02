# cohesive-dev

Self-contained development environment for CMDBuild backend. Clone this repo and be ready to develop in minutes.

## Prerequisites

- **Docker** (with `docker compose`)
- **JDK 17+**
- **Maven 3.8+**
- **Python 3** (for module detection)
- **Git**
- Access to a **PostgreSQL** database with CMDBuild schema

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/genpat-it/cohesive-dev.git
cd cohesive-dev

# 2. Configure database connection
cp conf/database.conf.example conf/database.conf
vi conf/database.conf

# 3. Bootstrap everything (clone source, build WAR, start container)
./setup.sh
```

CMDBuild will be available at `http://localhost:8080/cmdbuild`.

### Using a Private Repository

If your source repo requires authentication, set these before running `setup.sh`:

```bash
export GIT_REPO=https://your-git-server/org/cmdbuild.git
export GIT_BRANCH=develop
export GIT_TOKEN=your-access-token
./setup.sh
```

Or create a `.env` file (git-ignored):

```bash
GIT_REPO=https://your-git-server/org/cmdbuild.git
GIT_BRANCH=develop
GIT_TOKEN=your-access-token
DB_URL=jdbc:postgresql://dbhost:5432/cmdbuild
DB_USER=postgres
DB_PASS=postgres
```

## How It Works

`setup.sh` automatically clones two repositories:

1. **CMDBuild source** (`./source/`) - the Java codebase you'll be working on
2. **[cohesive-war-builder](https://github.com/genpat-it/cohesive-war-builder)** (`./war-builder/`) - a Docker-based tool that compiles the full CMDBuild WAR file

The war-builder is used during initial setup and whenever you need a full rebuild (`dev-deploy.sh --full`). For daily development, `dev-deploy.sh` only rebuilds the changed Maven modules and copies the JARs directly — no full WAR rebuild needed.

## Daily Workflow

```bash
# Edit Java files in ./source/

# Auto-detect changes and deploy JARs (no restart needed for many changes)
./dev-deploy.sh

# Deploy and restart Tomcat
./dev-deploy.sh -r

# Deploy a specific module
./dev-deploy.sh dao/postgresql

# Check what's changed
./dev-deploy.sh -s

# Full WAR rebuild (when dependencies change, pom.xml edits, etc.)
./dev-deploy.sh -f
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Your machine                                       │
│                                                     │
│  ./source/          Maven source code (git clone)   │
│       │                                             │
│       │ mvn package -pl <module>                    │
│       ▼                                             │
│  module/target/*.jar                                │
│       │                                             │
│       │ cp → ./webapp/WEB-INF/lib/                  │
│       ▼                                             │
│  ./webapp/          Exploded WAR (mounted volume)   │
│       │                                             │
│ ┌─────┴──────────────────────────────────────────┐  │
│ │  Docker: tomcat:9.0-jdk17                      │  │
│ │  ./webapp → /usr/local/tomcat/webapps/cmdbuild │  │
│ │  network_mode: host (port 8080)                │  │
│ └────────────────────────────────────────────────┘  │
│                                                     │
│  PostgreSQL database (external, configured in       │
│  conf/database.conf)                                │
└─────────────────────────────────────────────────────┘
```

## Directory Layout

```
cohesive-dev/
├── README.md                  # This file
├── setup.sh                   # One-time bootstrap
├── dev-deploy.sh              # Daily build & deploy
├── docker-compose.yml         # Tomcat container config
├── conf/
│   ├── database.conf.example  # Template
│   └── database.conf          # Your config (git-ignored)
├── source/                    # CMDBuild source (git-ignored, created by setup.sh)
├── war-builder/               # cohesive-war-builder (git-ignored, created by setup.sh)
└── webapp/                    # Exploded WAR (git-ignored, created by setup.sh)
```

## Module Map

The dev-deploy script auto-discovers Maven modules by scanning `pom.xml` files. Common modules:

| Source Directory | Description |
|---|---|
| `dao/postgresql` | Database access layer (PostgreSQL) |
| `dao/core` | Core DAO interfaces |
| `core/all` | Core business logic |
| `auth/login` | Authentication |
| `ui/auto` | UI auto-generation |

Run `./dev-deploy.sh -s` to see all discovered modules and which ones have changes.

## Configuration

### Docker Resources

Override Tomcat JVM settings via `CATALINA_OPTS`:

```bash
export CATALINA_OPTS="-Xms512m -Xmx2g"
docker compose up -d
```

### Container User

The container runs as your host user (via `UID`/`GID` env vars) so file permissions work correctly. The scripts set these automatically.

## Troubleshooting

### Container won't start
```bash
docker compose logs -f          # Check Tomcat logs
docker compose ps               # Check container status
```

### "READY" never appears
- First-time startup can be slow while CMDBuild initializes the database schema
- Check `conf/database.conf` - is the database reachable from Docker (remember: `network_mode: host`)?
- Check PostgreSQL logs for connection errors

### Build fails
```bash
cd source
mvn package -pl dao/postgresql -am -Dmaven.test.skip=true
# Read the full Maven error output
```

### JAR deployed but changes not visible
Some changes require a Tomcat restart:
```bash
./dev-deploy.sh -r
```

### Full reset
```bash
docker compose down
docker volume rm cohesive-dev_cmdbuild_logs cohesive-dev_cmdbuild_work
rm -rf webapp
./dev-deploy.sh -f
```

## Related Projects

- [cohesive-war-builder](https://github.com/genpat-it/cohesive-war-builder) - Docker-based WAR build system
- [cohesive-cmdbuild](https://github.com/genpat-it/cohesive-cmdbuild) - CMDBuild source fork

## License

AGPL v3 - see [LICENSE](LICENSE)

# Supabase Migrator

Moves your entire Supabase project (schema, data, auth users, storage files, and edge functions) to another project in one shot.

I wrote this after dealing with all the gotchas that come up during a real migration (Docker requirements, pg_dump v18 quirks, permission errors, circular FKs, nested storage folders, etc.).

## What It Migrates

| Component | Details |
|-----------|---------|
| **Schema** | All tables, views, functions, triggers, indexes, and types in `public` schema |
| **Data** | All rows from `public`, `auth`, and `storage` schemas |
| **Auth Users** | Password hashes, metadata, and identities preserved |
| **Storage** | Buckets (with settings) and all files including nested folders |
| **Edge Functions** | Deployed from local `supabase/functions/` directory |

## Prerequisites

- **psql** and **pg_dump** - included with [PostgreSQL](https://www.postgresql.org/download/) or `brew install libpq`
- **curl** - pre-installed on macOS/Linux
- **jq** - `brew install jq` or [stedolan.github.io/jq](https://stedolan.github.io/jq/)
- **supabase CLI** - only needed for edge functions: `brew install supabase/tap/supabase`

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/KarimNasreddine/supabase-migrator.git
cd supabase-migrator

# 2. Configure credentials
cp .env.example .env
# Edit .env with your source and destination project details
# (see .env.example for where to find each value)

# 3. Run the migration
./migrate.sh
```

## CLI Flags

```
./migrate.sh [OPTIONS]

Options:
  --dry-run          Show what would happen without executing
  --skip-schema      Skip schema migration
  --skip-data        Skip data migration
  --skip-auth        Skip auth user migration
  --skip-storage     Skip storage file migration
  --skip-functions   Skip edge function deployment
  --no-confirm       Skip interactive confirmations (CI mode)
  --no-color         Disable colored output
  --help, -h         Show usage
  --version, -v      Print version
```

## Examples

```bash
# Preview the migration plan
./migrate.sh --dry-run

# Migrate everything non-interactively
./migrate.sh --no-confirm

# Migrate only schema and data (no auth, storage, or functions)
./migrate.sh --skip-auth --skip-storage --skip-functions

# Re-run just storage migration
./migrate.sh --skip-schema --skip-data --skip-auth --skip-functions
```

## What happens when you run it

1. **Preflight** - validates your `.env`, checks that `psql`/`pg_dump`/`curl`/`jq` are installed, and tests both DB connections
2. **Schema** - `pg_dump --schema-only` on public schema, cleans up the dump, restores in a single transaction
3. **Data** - dumps `public`, `auth`, and `storage` data separately, wraps the restore in `session_replication_role = replica` so circular FKs don't blow up
4. **Storage** - hits the Storage API to list buckets, recreates them on the destination, downloads and re-uploads every file (handles nested folders)
5. **Functions** - deploys edge functions from your local `supabase/functions/` directory
6. **Verify** - compares row counts on every table between source and destination

## Gotchas this handles for you

| Problem | What we do |
|---------|-----------|
| `supabase db dump` needs Docker running | Uses `pg_dump` directly, no Docker |
| pg_dump v18+ spits out `\restrict` / `\unrestrict` | Stripped automatically |
| `CREATE SCHEMA "public"` already exists on dest | Filtered out of the dump |
| `auth.schema_migrations` permission denied | Excluded from dump |
| `storage.migrations` permission denied | Excluded from dump |
| Circular FK constraints break data restore | `session_replication_role = replica` |
| `--clean` drops Supabase internal stuff | We don't use it |
| Files inside nested storage folders | Recursive listing with pagination |

## After migrating

- [ ] Test login as an existing user (password hashes are preserved)
- [ ] Verify RLS policies are active on the destination
- [ ] Access a stored file URL on the destination
- [ ] Test edge function endpoints
- [ ] Re-enable Realtime publications (Dashboard > Database > Replication)
- [ ] Re-enable Database Webhooks (Dashboard > Database > Webhooks)
- [ ] Set edge function secrets: `supabase secrets set KEY=VALUE --project-ref <ref>`
- [ ] Update client apps with the new project URL and anon key
- [ ] Monitor the destination for a few days before cancelling the source

## Logs

Every run writes a timestamped log file (`migrate-YYYYMMDD-HHMMSS.log`) with the full output.

## Troubleshooting

**"permission denied for table auth.schema_migrations"** - already excluded, but if you see this you might be on an older version of the script.

**pg_dump version mismatch** - if your pg_dump is newer than the server, it may emit `\restrict` commands. The script strips these.

**Storage upload returns 409** - file already exists on the destination. Safe to ignore.

**Edge functions won't deploy** - make sure the Supabase CLI is installed and your functions are in `supabase/functions/`.

## License

MIT

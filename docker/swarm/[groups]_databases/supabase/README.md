# Supabase Docker Swarm Deployment

This directory contains the complete Docker Swarm deployment configuration for Supabase - an open-source Firebase alternative.

## Components

The Supabase stack includes the following services:

1. **PostgreSQL (db)** - Core database with Supabase extensions
2. **Kong Gateway (kong)** - API Gateway for routing requests
3. **PostgREST (rest)** - Auto-generated REST API from PostgreSQL
4. **GoTrue (auth)** - Authentication and user management
5. **Realtime (realtime)** - Real-time data synchronization via WebSockets
6. **Storage (storage)** - S3-compatible object storage
7. **ImgProxy (imgproxy)** - Image transformation and optimization
8. **Postgres Meta (meta)** - Database metadata and management API
9. **Studio (studio)** - Web-based dashboard/UI
10. **Edge Functions (functions)** - Serverless functions using Deno runtime
11. **LogFlare (analytics)** - Analytics and logging (optional)
12. **Vector (vector)** - Log aggregation and forwarding (optional)

## Prerequisites

Before deploying, ensure you have:

- ✅ Docker Swarm cluster initialized
- ✅ Overlay networks created:
  - `db-internetwork`
  - `traefik-internetwork`
- ✅ Node labeled with `node.labels.database=master`
- ✅ Vault CLI installed and configured
- ✅ Environment variables set:
  - `VAULT_ADDR=https://vault.mcb-svc.work`
  - `VAULT_TOKEN=<your-vault-token>`

## Required Secrets in Vault

The following secrets must be created in Vault at `kubernetes/docker-secrets`:

### Required Secrets:
1. **supabase-postgres-password** - PostgreSQL superuser password
2. **supabase-jwt-secret** - JWT signing secret (base64 encoded, 64+ chars)
3. **supabase-anon-key** - JWT token with `anon` role
4. **supabase-service-role-key** - JWT token with `service_role` role
5. **supabase-smtp-password** - SMTP password for email notifications

### Generating JWT Keys

You need to generate JWT tokens using your JWT secret. Use one of these methods:

#### Method 1: Using Supabase JWT Generator
Visit: https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys

#### Method 2: Using JWT.io
1. Go to https://jwt.io
2. Select algorithm: **HS256**
3. Use your `supabase-jwt-secret` as the secret
4. Create two tokens with these payloads:

**Anonymous Key (anon):**
```json
{
  "role": "anon",
  "iss": "supabase",
  "iat": 1704067200,
  "exp": 2019427200
}
```

**Service Role Key (service_role):**
```json
{
  "role": "service_role",
  "iss": "supabase",
  "iat": 1704067200,
  "exp": 2019427200
}
```

### Storing Secrets in Vault

```bash
# Set JWT secret
vault kv put kubernetes/docker-secrets supabase-jwt-secret="<your-64-char-base64-secret>"

# Set PostgreSQL password
vault kv put kubernetes/docker-secrets supabase-postgres-password="<strong-password>"

# Set JWT tokens
vault kv put kubernetes/docker-secrets supabase-anon-key="<generated-anon-jwt>"
vault kv put kubernetes/docker-secrets supabase-service-role-key="<generated-service-role-jwt>"

# Set SMTP password
vault kv put kubernetes/docker-secrets supabase-smtp-password="<smtp-password>"
```

## Environment Variables

You can customize the deployment by setting these environment variables before running the script:

```bash
# API and Site URLs
export API_EXTERNAL_URL="https://api.supabase.mcb-svc.work"
export SITE_URL="https://supabase.mcb-svc.work"

# Signup Configuration
export DISABLE_SIGNUP="false"
export ENABLE_EMAIL_SIGNUP="true"
export ENABLE_EMAIL_AUTOCONFIRM="false"
export ENABLE_PHONE_SIGNUP="false"
export ENABLE_PHONE_AUTOCONFIRM="false"

# SMTP Configuration
export SMTP_ADMIN_EMAIL="admin@mcb-svc.work"
export SMTP_HOST="smtp.gmail.com"
export SMTP_PORT="587"
export SMTP_USER="noreply@mcb-svc.work"
export SMTP_SENDER_NAME="Supabase"

# Studio Configuration
export STUDIO_DEFAULT_ORGANIZATION="MCB Organization"
export STUDIO_DEFAULT_PROJECT="Default Project"

# Analytics (optional)
export LOGFLARE_API_KEY="your-logflare-api-key"
```

## Deployment

### Important Note

Supabase currently does not support Docker Swarm secrets via `_FILE` postfix variables. Therefore, this deployment uses **direct environment variable injection** from Vault instead of Docker secrets. All sensitive values are fetched from Vault and exported as environment variables before stack deployment.

### Step 1: Prepare Secrets

Ensure all required secrets are stored in Vault (see section above).

### Step 2: Run Deployment Script

```bash
# Make the script executable
chmod +x deploy_supabase.sh

# Run the deployment
./deploy_supabase.sh
```

The script will:
1. Remove existing stack and configs (not secrets, as we use environment variables)
2. Optionally clean up Docker resources on the remote node
3. Fetch secrets from Vault and export them as environment variables
4. Create Docker configs for Kong and Vector
5. Deploy the Supabase stack with environment variables injected

### Step 3: Verify Deployment

```bash
# Check stack status
docker stack ps supabase-stack

# Check service logs
docker service logs -f supabase-stack_db
docker service logs -f supabase-stack_kong
docker service logs -f supabase-stack_studio
```

## Access Points

After successful deployment:

- **Studio Dashboard**: https://supabase.mcb-svc.work (port 3000)
- **API Gateway**: https://api.supabase.mcb-svc.work (port 8000)
- **Analytics**: http://swarm-worker-sg.netbird.cloud:4000 (port 4000)

All services connect internally via `swarm-worker-sg.netbird.cloud` when using ingress mode.

## API Endpoints

Through Kong Gateway (https://api.supabase.mcb-svc.work):

- `/auth/v1/*` - Authentication endpoints
- `/rest/v1/*` - REST API for database
- `/realtime/v1/*` - Real-time subscriptions
- `/storage/v1/*` - Object storage
- `/functions/v1/*` - Edge functions
- `/pg/*` - Database metadata

## Resource Allocation

### Database (PostgreSQL)
- CPU: 0.5-4 cores
- Memory: 2-8GB
- Storage: Local volume `supabase-db-data`

### API Gateway (Kong)
- CPU: 0.25-2 cores
- Memory: 512MB-2GB

### Storage Service
- CPU: 0.125-1 core
- Memory: 256MB-1GB
- Storage: Local volume `supabase-storage-data`

### Studio
- CPU: 0.125-1 core
- Memory: 256MB-1GB

### Other Services
- PostgREST: 2 replicas, 256MB-1GB each
- Auth, Realtime, Functions: 256MB-1GB each
- Analytics, Meta, ImgProxy: 128MB-512MB each

## Persistent Volumes

All services use Docker-defined local volumes:

```yaml
volumes:
  supabase-db-data:        # PostgreSQL data
  supabase-storage-data:   # Object storage files
  supabase-functions:      # Edge function code
  supabase-logs:           # Application logs
```

## Placement Constraints

All services are constrained to run on nodes with:
```yaml
- node.labels.database == master
```

Ensure your target node has this label:
```bash
docker node update --label-add database=master <node-name>
```

## Networking

### External Networks
- `db-internetwork` - For database connectivity
- `traefik-internetwork` - For Traefik reverse proxy integration

### Exposed Ports (Ingress Mode)
- **8000** - Kong API Gateway
- **3000** - Studio Dashboard
- **4000** - Analytics/LogFlare

## Traefik Integration

The stack includes Traefik labels for automatic routing:

- **Kong**: `api.supabase.mcb-svc.work` → port 8000
- **Studio**: `supabase.mcb-svc.work` → port 3000

## Database Initialization

The Supabase PostgreSQL image includes pre-configured:
- PostgreSQL extensions (pgvector, pgjwt, etc.)
- Database schemas (auth, storage, realtime, etc.)
- Row-level security policies
- Default roles (anon, authenticated, service_role)

## Troubleshooting

### Check Service Status
```bash
docker stack ps supabase-stack --no-trunc
```

### View Service Logs
```bash
docker service logs -f supabase-stack_<service-name>
```

### Common Issues

1. **Services not starting**: Check if environment variables are properly exported
   ```bash
   # Verify Vault connection
   vault kv get kubernetes/docker-secrets
   ```

2. **Database connection errors**: Verify PostgreSQL is healthy and password is correct
   ```bash
   docker service logs supabase-stack_db
   ```

3. **Kong gateway errors**: Check Kong configuration
   ```bash
   docker config inspect kong-config
   ```

4. **JWT authentication errors**: Verify JWT secret and keys match
   - Ensure anon and service_role keys are signed with the same JWT secret
   - Check that all environment variables are properly set

### Reset and Redeploy

```bash
# Remove the stack
docker stack rm supabase-stack

# Remove all configs
docker config rm kong-config vector-config

# Redeploy (secrets will be fetched from Vault again)
./deploy_supabase.sh
```

## Updating

To update Supabase components:

1. Edit `docker-compose.yml` and update image tags
2. Run the deployment script:
   ```bash
   ./deploy_supabase.sh
   ```

Docker Swarm will perform a rolling update.

## Backup

### Database Backup
```bash
docker exec -it $(docker ps -q -f name=supabase-stack_db) \
  pg_dump -U postgres postgres > supabase_backup.sql
```

### Storage Backup
```bash
docker run --rm -v supabase-storage-data:/data \
  -v $(pwd):/backup alpine tar czf /backup/storage_backup.tar.gz /data
```

## Security Considerations

1. **JWT Secret**: Keep your JWT secret secure and never commit it to version control
2. **Service Role Key**: Only use service_role key on backend servers, never expose to clients
3. **SMTP Credentials**: Store securely in Vault
4. **PostgreSQL Password**: Use a strong password stored in Vault
5. **Network Isolation**: Use overlay networks to isolate services
6. **SSL/TLS**: Use Traefik with valid SSL certificates for external access

## References

- [Supabase Documentation](https://supabase.com/docs)
- [Self-Hosting Guide](https://supabase.com/docs/guides/self-hosting)
- [Docker Self-Hosting](https://supabase.com/docs/guides/self-hosting/docker)
- [Kong Gateway](https://docs.konghq.com/)
- [PostgREST](https://postgrest.org/)

## License

This deployment configuration follows your homelab setup. Supabase is licensed under Apache 2.0.

## Support

For issues specific to this deployment, check:
1. Docker service logs
2. Vault secret availability
3. Network connectivity between services
4. Node labels and constraints

For Supabase-specific issues, consult the official documentation.

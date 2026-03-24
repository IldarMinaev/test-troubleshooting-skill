# DBAAS Architecture Reference

## Overview

DBAAS (Database as a Service) provides a management layer on top of pgskipper-operator for multi-tenant database provisioning. Microservices request databases through the DBAAS API, which provisions them on physical PostgreSQL clusters.

## Components

### Aggregator

- Deployment: `dbaas-aggregator`
- Ports: 8080 (HTTP), 8443 (HTTPS)
- Swagger UI: `/swagger-ui`
- Central API for database lifecycle management

### Adapters

Each database type has an adapter that registers with the aggregator:
- PostgreSQL adapter registers physical database clusters
- Adapters handle the actual database creation/deletion on the cluster

## Authentication

- HTTP Basic authentication
- Roles: `dba_client`, `dbaas-db-editor`
- Credentials are typically stored in Kubernetes secrets

```bash
# Find DBAAS credentials
kubectl get secret -n <ns> -l app=dbaas-aggregator -o name
```

## Key API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v3/dbaas/{namespace}/databases/list` | GET | List databases in a namespace |
| `/api/v3/dbaas/physical_databases` | GET | List physical database clusters |
| `/api/v3/dbaas/{namespace}/databases/statuses` | GET | Database statuses in a namespace |
| `/api/v3/dbaas/{namespace}/databases` | POST | Create a new database |
| `/api/v3/dbaas/{namespace}/databases/{id}` | DELETE | Delete a database |

## API Usage Pattern

```bash
# Port-forward to aggregator
kubectl port-forward -n <ns> svc/dbaas-aggregator 8080:8080 &

# List databases (with basic auth)
curl -s -u <user>:<pass> http://localhost:8080/api/v3/dbaas/<namespace>/databases/list | jq .

# List physical databases
curl -s -u <user>:<pass> http://localhost:8080/api/v3/dbaas/physical_databases | jq .

# Get database statuses
curl -s -u <user>:<pass> http://localhost:8080/api/v3/dbaas/<namespace>/databases/statuses | jq .
```

## Common Concepts

- **Physical database**: The actual PostgreSQL cluster managed by pgskipper-operator
- **Logical database**: A database created within a physical cluster for a microservice
- **Ghost database**: A database that exists in PostgreSQL but not tracked by DBAAS
- **Lost database**: A database tracked by DBAAS but missing from PostgreSQL
- **Adapter registration**: Adapters register physical clusters with the aggregator

## Troubleshooting Indicators

- Aggregator pod not running → no database provisioning possible
- Adapter not registered → physical cluster not available for provisioning
- Ghost databases → data inconsistency between DBAAS and PostgreSQL
- Lost databases → DBAAS references removed or failed databases

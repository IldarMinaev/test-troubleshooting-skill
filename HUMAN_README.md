# Prepare lab

## PostgresSQL with PGSkipper Operator

```bash
cd /tmp
git clone git@github.com:Netcracker/pgskipper-operator.git
cd pgskipper-operator
# For latest
LATEST_TAG="$(git describe --tags "$(git rev-list --tags --max-count=1)")"
GIT_TAG=${LATEST_TAG}
IMAGE_PREFIX=ghcr.io/netcracker/
IMAGE_TAG=${LATEST_TAG}
PG_VERSION=17
PG_NAMESPACE=postgres
DBAAS_NAMESPACE=dbaas
DBAAS_SERVICE_NAME=dbaas-aggregator
POSTGRES_PASSWORD=MYrootPWD

git checkout ${GIT_TAG}

# PostgresSQL install
helm upgrade patroni-core ./operator/charts/patroni-core \
  --install \
  -n ${PG_NAMESPACE} \
  --create-namespace \
  --set='patroni.install=true'                     `# Install patroni service` \
  --set='patroni.replicas=2'                       `# Configure number of replicas` \
  --set='patroni.storage.type=provisioned'         `# Configure used storage provisioner` \
  --set='patroni.storage.size=2Gi'                 `# Size of PV requested` \
  --set='patroni.storage.storageClass=local-path'  `# Default in Rancher Desktop` \
  --set="postgresPassword=${POSTGRES_PASSWORD}"    `# Database superuser password` \
  --set='replicatorPassword=replicatorPWD'         `# Database replication password` \
  --set='tests.install=true'                       `# Install and run tests` \
  --set='tests.runTestScenarios=basic'             `# Configure tests scenarios` \
  --set="patroni.dockerImage=${IMAGE_PREFIX}pgskipper-docker-patroni-${PG_VERSION}:${IMAGE_TAG}" \
  --wait

# Check CR:
sleep 30
kubectl get patronicores -n postgres patroni-core -o jsonpath='{.status}' | jq -r .

# Check logs:
kubectl logs -n postgres integration-robot-tests
```
## DBAAS

```bash
cd /tmp/
git clone git@github.com:Netcracker/qubership-dbaas.git
cd qubership-dbaas
LATEST_TAG="$(git describe --tags "$(git rev-list --tags --max-count=1)")"
GIT_TAG=${LATEST_TAG}
IMAGE_PREFIX=ghcr.io/netcracker/
IMAGE_TAG=${LATEST_TAG}
DBA_PASSWORD=password

git checkout ${GIT_TAG}

helm upgrade dbaas-aggregator helm-templates/dbaas-aggregator/ \
  --install \
  -n dbaas \
  --create-namespace \
  --set='tests.install=true' \
  --set='PRODUCTION_MODE=false' \
  --set='NODE_SELECTOR_DBAAS_KEY=kubernetes.io/os' \
  --set='REGION_DBAAS=linux' \
  --set="DECLARATIVE_HOOK_IMAGE=${IMAGE_PREFIX}qubership-dbaas-validation-image:${IMAGE_TAG}" \
  --set="IMAGE_REPOSITORY=${IMAGE_PREFIX}qubership-dbaas" \
  --set="TAG=${IMAGE_TAG}" \
  --set="SERVICE_NAME=${DBAAS_SERVICE_NAME}" \
  --set="POSTGRES_HOST=pg-patroni.${PG_NAMESPACE}.svc.cluster.local" \
  --set='BACKUP_DAEMON_DBAAS_ACCESS_PASSWORD=password' \
  --set="DBAAS_CLUSTER_DBA_CREDENTIALS_PASSWORD=${DBA_PASSWORD}" \
  --set='DBAAS_TENANT_PASSWORD=password' \
  --set='DBAAS_DB_EDITOR_CREDENTIALS_PASSWORD=password' \
  --set='DISCR_TOOL_USER_PASSWORD=password' \
  --set='POSTGRES_DBAAS_USER=postgres' \
  --set="POSTGRES_DBAAS_PASSWORD=${POSTGRES_PASSWORD}" \
  --set='POSTGRES_DBAAS_DATABASE_NAME=dbaas' \
  --set='DBAAS_BACKUP_RESTORE_CHECK_ATTEMPTS=20' \
  --set='DBAAS_BACKUP_RESTORE_RETRY_DELAY_SECONDS=3' \
  --set='DBAAS_BACKUP_RESTORE_RETRY_ATTEMPTS=3' \
  --set='DBAAS_BACKUP_RESTORE_CHECK_INTERVAL=1m' \
  --set='DBAAS_BACKUP_RESTORE_CHECK_LOCK_TIMEOUT=PT10M' \
  --wait
```

## Postgres Supplementary services install

```
cd ../pgskipper-operator
LATEST_TAG="$(git describe --tags "$(git rev-list --tags --max-count=1)")"
GIT_TAG=${LATEST_TAG}
IMAGE_PREFIX=ghcr.io/netcracker/
IMAGE_TAG=${LATEST_TAG}
helm upgrade patroni-services ./operator/charts/patroni-services \
  --install \
  -n ${PG_NAMESPACE} \
  --create-namespace \
  --set="postgresPassword=${POSTGRES_PASSWORD}"         `# Database superuser password` \
  --set='metricCollector.install=true'                  `# Install and run metrics collector` \
  --set='backupDaemon.install=false'                    `# Install and run backup Daemon` \
  --set='tests.install=true'                            `# Install and run tests` \
  --set='tests.runTestScenarios=basic'                  `# Configure tests scenarios` \
  --set='backupDaemon.storage.storageClass=local-path'  `# Default in Rancher Desktop` \
  --set='dbaas.install=true' \
  --set="dbaas.aggregator.registrationAddress=http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080" \
  --set='dbaas.aggregator.registrationUsername=cluster-dba' \
  --set="dbaas.aggregator.registrationPassword=${DBA_PASSWORD}" \
  --wait

# Check CR:
sleep 30
kubectl get patroniservices -n postgres patroni-services -o jsonpath='{.status}' | jq -r .

# Check logs:
kubectl logs -n postgres supplementary-robot-tests
```

## Check:

```bash
DBAAS_NAMESPACE=dbaas
DBAAS_SERVICE_NAME=dbaas-aggregator
APP_NAMESPACE=test-app

DBA_PASSWORD=$(kubectl get secret -n ${DBAAS_NAMESPACE} dbaas-security-configuration-secret -o jsonpath='{.data.users\.json}' | base64 -d | jq -r '."cluster-dba".password')

echo ====== List registered Databases ======; kubectl exec -it -n ${DBAAS_NAMESPACE} deployments/dbaas-aggregator --\
  curl -sk -u cluster-dba:${DBA_PASSWORD} \
    "http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080/api/v3/dbaas/all/physical_databases" \
    | jq -r '
        .identified | to_entries[]
        | [.key, .value.type, .value.adapterAddress]
        | @tsv
      ' \
    | column -t -s $'\t' -N 'NAME,TYPE,ADAPTER_ADDRESS'

# Useful APIs:
# /api/v3/dbaas/all/physical_databases
# /api/v3/dbaas/debug/internal/lost


# List databases in namespace:
kubectl exec -n ${DBAAS_NAMESPACE} deployments/dbaas-aggregator --\
  curl -sk -u cluster-dba:${DBA_PASSWORD} \
    "http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080/api/v3/dbaas/${APP_NAMESPACE}/databases/list" \
    | jq -r '.[]|[.type, .namespace, .classifier.microserviceName, .name ]| @tsv'\
    | column -t -s $'\t' -N 'TYPE,NAMESPACE,MICROSERVICE,NAME'

# Create test database:
kubectl exec -n ${DBAAS_NAMESPACE} deployments/dbaas-aggregator --\
  curl -sk -u cluster-dba:${DBA_PASSWORD} \
    -X PUT \
    -H 'Content-Type: application/json' \
    "http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080/api/v3/dbaas/${APP_NAMESPACE}/databases" \
    -d '{
          "classifier": {
            "microserviceName": "test-service",
            "scope": "service",
            "namespace": "'${APP_NAMESPACE}'"
          },
          "type": "postgresql",
          "originService": "test-service"
        }' | jq -r .

# List all databases

kubectl exec -n ${DBAAS_NAMESPACE} deployments/dbaas-aggregator --\
  curl -sk -u cluster-dba:${DBA_PASSWORD} \
    "http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080/api/v3/dbaas/debug/internal/namespaces" \
    | jq -r '.[]' \
    | while read ns; do \
      kubectl exec -n ${DBAAS_NAMESPACE} deployments/dbaas-aggregator --\
        curl -sk -u cluster-dba:${DBA_PASSWORD} \
        "http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080/api/v3/dbaas/${ns}/databases/list"
      done \
      | jq -r '.[]|[.type, .namespace, .classifier.microserviceName, .name ]| @tsv' \
      | column -t -s $'\t' -N 'TYPE,NAMESPACE,MICROSERVICE,NAME'

```

## Clean up

Postgres:

```bash
helm uninstall patroni-core -n postgres
helm uninstall patroni-services -n postgres
kubectl delete namespace postgres
```

## Install test app
Test app

```bash
DBAAS_NAMESPACE=dbaas
DBAAS_SERVICE_NAME=dbaas-aggregator
APP_NAMESPACE=test-app
DBA_PASSWORD=$(kubectl get secret -n ${DBAAS_NAMESPACE} dbaas-security-configuration-secret -o jsonpath='{.data.users\.json}' | base64 -d | jq -r '."cluster-dba".password')

helm upgrade pg-load-generator ./test-app/helm/test-app \
  --install \
  -n ${APP_NAMESPACE} \
  --create-namespace \
  --set="workers.count=4" \
  --set="dbaas.url=http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080" \
  --set="dbaas.user=cluster-dba" \
  --set="dbaas.password=${DBA_PASSWORD}" \
  --wait
```

## Run test scenarios

```bash
export DBAAS_NAMESPACE=dbaas
export DBAAS_URL="http://dbaas-aggregator.${DBAAS_NAMESPACE}.svc.cluster.local:8080"
export DBAAS_USER=cluster-dba
export DBAAS_PASSWORD=$(kubectl get secret -n ${DBAAS_NAMESPACE} dbaas-security-configuration-secret -o jsonpath='{.data.users\.json}' | base64 -d | jq -r '."cluster-dba".password')
test-app/scenarios/deploy-scenario.sh deploy compound-issue
sleep 5
test-app/scenarios/deploy-scenario.sh logs compound-issue
```

## Configure AI Agent

### Get OpenAI compatible token

See instructions: <https://openrouter.ai/settings/keys>.

### Install AI agent

Opencode:

```bash
curl -fsSL https://opencode.ai/install | bash
```

### Install MCPs:

On Opencode:

```bash
cd /tmp/ && curl -LO "$(curl -s https://api.github.com/repos/containers/kubernetes-mcp-server/releases/latest | jq -r '.assets[]|select(.name|test("kubernetes-mcp-server-linux-amd64$"))|.browser_download_url')" && chmod +x ./kubernetes-mcp-server-linux-amd64 && mv ./kubernetes-mcp-server-linux-amd64 ~/.local/bin/kubernetes-mcp-server
```

Add to the file `opencode.json` (correct user name. use full path to kubeconfig.):

```json
{
  "mcp": {
    "kubernetes": {
      "type": "local",
      "enabled": true,
      "command": ["kubernetes-mcp-server", "--cluster-provider", "kubeconfig", "--kubeconfig", "/home/user/.kube/config"],
      "environment": {
        "KUBECONFIG": "/home/user/.kube/config"
      }
    }
  }
}
```

Install context7 MCP on claude:

```shell
claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp --api-key YOUR_API_KEY
```

### Install APM Skills manager

```bash
pip install uv
```

Install skills by APM skill manager

```bash
uv tool run --python 3.12 --from apm-cli apm install https://github.com/IldarMinaev/test-troubleshooting-skill
```

## Use prompt

```txt
Check status of postgres database in my rancher-desktop k8s cluster. Find any critical issue. Identify root cause of found issues. Propose solution to fix the issues.
```

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
  --set='patroni.replicas=2'                            `# Configure number of replicas` \
  --set='backupDaemon.install=false'                    `# Do not install and run backup Daemon, it not working` \
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

Build it first:

```bash
app/build.sh
```

Run deploy script:

```bash
app/update.sh
```

## Run test scenarios

View supported scenarios:

```bash
app/scenarios/manage-deployment.sh list
```

Run scenario:
```bash
export DBAAS_NAMESPACE=dbaas
export DBAAS_URL="http://dbaas-aggregator.${DBAAS_NAMESPACE}.svc.cluster.local:8080"
export DBAAS_USER=cluster-dba
export DBAAS_PASSWORD=$(kubectl get secret -n ${DBAAS_NAMESPACE} dbaas-security-configuration-secret -o jsonpath='{.data.users\.json}' | base64 -d | jq -r '."cluster-dba".password')

app/scenarios/manage-deployment.sh deploy month-end-processing
app/scenarios/manage-deployment.sh deploy parallel-import
app/scenarios/manage-deployment.sh deploy report-generation

sleep 5
app/scenarios/manage-deployment.sh logs report-generation
```

## Configure AI Agent

Get TroubleShooting Engineer workspace

```bash
cd /tmp
git clone https://github.com/IldarMinaev/engineer-workspace
cd engineer-workspace
./install.sh --agent=claude
```

## Use prompt

```txt
Check status of postgres database in my rancher-desktop k8s cluster. Find any critical issue. Identify root cause of found issues. Propose solution to fix the issues.
```

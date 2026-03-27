#!/bin/bash

cd "$(dirname "$0")"

DBAAS_NAMESPACE=dbaas
DBAAS_SERVICE_NAME=dbaas-aggregator
APP_NAMESPACE=inventory
DBA_PASSWORD=$(kubectl get secret -n ${DBAAS_NAMESPACE} dbaas-security-configuration-secret -o jsonpath='{.data.users\.json}' | base64 -d | jq -r '."cluster-dba".password')

kubectl delete ns $APP_NAMESPACE

helm upgrade inventory-service ./helm/inventory-service \
  --install \
  -n ${APP_NAMESPACE} \
  --create-namespace \
  --set="workers.count=4" \
  --set="dbaas.url=http://${DBAAS_SERVICE_NAME}.${DBAAS_NAMESPACE}.svc.cluster.local:8080" \
  --set="dbaas.user=cluster-dba" \
  --set="dbaas.password=${DBA_PASSWORD}" \
  --wait

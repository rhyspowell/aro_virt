#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

echo "==> [netapp] Starting Azure NetApp Files + Trident setup"
echo "    RESOURCEGROUP=${RESOURCEGROUP}"
echo "    LOCATION=${LOCATION}"
echo "    ANF_ACCOUNT_NAME=${ANF_ACCOUNT_NAME}"
echo "    VNET_NAME=${VNET_NAME}"
echo "    SUBNET_NAME=${SUBNET_NAME}"

# Register the NetApp provider
echo "==> [netapp] Registering Microsoft.NetApp provider (may take a while)..."
az provider register --namespace Microsoft.NetApp --wait
echo "    Provider registered."

# Create the NetApp account
echo "==> [netapp] Creating NetApp account: ${ANF_ACCOUNT_NAME}..."
az netappfiles account create --resource-group "$RESOURCEGROUP" --location "$LOCATION" --name "$ANF_ACCOUNT_NAME"
echo "    NetApp account created."

# Create the NetApp pool TODO: This line needs to be fixed for flex and throughput
echo "==> [netapp] Creating NetApp pool: ${POOL_NAME} (${POOL_SIZE_TiB} TiB, ${SERVICE_LEVEL})..."
az netappfiles pool create \
  --resource-group "$RESOURCEGROUP" \
  --location "$LOCATION" \
  --account-name "$ANF_ACCOUNT_NAME" \
  --pool-name "$POOL_NAME" \
  --size "$POOL_SIZE_TiB" \
  --service-level "$SERVICE_LEVEL" \
  --custom-throughput "$CUSTOM_THROUGHPUT" \
  --qos-type "$QOS_TYPE"
echo "    NetApp pool created."

echo "==> [netapp] Ensuring NetApp-delegated subnet ${SUBNET_NAME} on ${VNET_NAME}..."
if ! az network vnet subnet show \
  --resource-group "$RESOURCEGROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --output none 2>/dev/null; then
  echo "    Subnet not found; creating with prefix ${SUBNET_PREFIX}..."
  az network vnet subnet create \
    --resource-group "$RESOURCEGROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --address-prefixes "$SUBNET_PREFIX" \
    --delegations Microsoft.NetApp/volumes
  echo "    Subnet created."
else
  echo "    Subnet exists; updating delegation to Microsoft.NetApp/volumes..."
  az network vnet subnet update \
    --resource-group "$RESOURCEGROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --delegations Microsoft.NetApp/volumes
  echo "    Subnet updated."
fi

echo "==> [netapp] Checking OpenShift login..."
oc whoami
echo "    Logged in as: $(oc whoami)"

# Install the Trident operator TODO: This needs testing
echo "==> [netapp] Installing Trident operator subscription..."
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trident-operator
  namespace: openshift-operators
spec:
  source: certified-operators
  sourceNamespace: openshift-marketplace
  name: trident-operator
  channel: "stable"
EOF
echo "    Trident subscription applied."

# Create trident orchestrator
echo "==> [netapp] Creating TridentOrchestrator..."
cat << EOF | oc apply -f -
apiVersion: trident.netapp.io/v1
kind: TridentOrchestrator
metadata:
  name: trident
  namespace: openshift-operators
spec:
  namespace: trident
  IPv6: false
EOF
echo "    TridentOrchestrator applied."

# create secret for trident (clientID/clientSecret keys required by Trident)
# Azure only returns the secret *value* at create/reset time — it cannot be fetched later.
# Use --json-auth so we get clientId/clientSecret (value), not a credential keyId.
echo "==> [netapp] Waiting for trident namespace..."
until oc get namespace trident >/dev/null 2>&1; do
  echo "    trident namespace not ready yet..."
  sleep 5
done

echo "==> [netapp] Creating Azure AD service principal (trident-client-1)..."
SP_JSON=$(az ad sp create-for-rbac \
  --name "trident-client-1" \
  --role "Contributor" \
  --scopes "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}" \
  --json-auth)
CLIENT_ID=$(echo "$SP_JSON" | jq -r '.clientId // empty')
CLIENT_SECRET=$(echo "$SP_JSON" | jq -r '.clientSecret // empty')

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "ERROR: create-for-rbac did not return clientId/clientSecret." >&2
  echo "$SP_JSON" >&2
  exit 1
fi

echo "==> [netapp] Recreating anf-credentials secret in trident namespace..."
oc -n trident delete secret anf-credentials --ignore-not-found
oc -n trident create secret generic anf-credentials \
  --from-literal=clientID="$CLIENT_ID" \
  --from-literal=clientSecret="$CLIENT_SECRET"
echo "    Secret created."

# Recreate backend so it picks up the new secret (Failed backends keep stale auth errors)
echo "==> [netapp] Removing any existing TridentBackendConfig..."
oc -n trident delete tridentbackendconfig anf-backend-flex --ignore-not-found
sleep 5

echo "==> [netapp] Creating TridentBackendConfig (anf-backend-flex)..."
cat << EOF | oc apply -f -
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: anf-backend-flex
  namespace: trident
spec:
  version: 1
  storageDriverName: azure-netapp-files
  credentials:
      name: anf-credentials
  subscriptionID: ${SUBSCRIPTION_ID}
  tenantID: ${TENANT_ID}
  location: ${LOCATION}
  networkFeatures: Standard
  resourceGroups:
    - ${RESOURCEGROUP}
  netappAccounts:
    - ${RESOURCEGROUP}/${ANF_ACCOUNT_NAME}
  capacityPools:
    - ${RESOURCEGROUP}/${ANF_ACCOUNT_NAME}/${POOL_NAME}
  virtualNetwork: ${RESOURCEGROUP}/${VNET_NAME}
  subnet: ${RESOURCEGROUP}/${VNET_NAME}/${SUBNET_NAME}
  nfsMountOptions: nfsvers=3,nconnect=4
  defaults:
    unixPermissions: "0777"
    maxThroughput: "60"
    qosType: "Manual"
  labels:
    qos: manual60mbps
EOF
echo "    TridentBackendConfig applied."

# echo "==> [netapp] Waiting for ANF backend to be Bound (timeout: 300s)..."
# TIMEOUT=600
# ELAPSED=0
# while true; do
#   PHASE=$(oc get tridentbackendconfig anf-backend-flex -n trident -o jsonpath='{.status.phase}' 2>/dev/null || true)
#   BACKEND=$(oc get tridentbackend -n trident -o jsonpath='{.items[0].backendName}' 2>/dev/null || true)
#   if [[ "$PHASE" == "Bound" && -n "$BACKEND" ]]; then
#     echo "    ANF backend created successfully: ${BACKEND}"
#     oc get tridentbackendconfig anf-backend-flex -n trident
#     oc get tridentbackend -n trident
#     break
#   fi
#   MESSAGE=$(oc get tridentbackendconfig anf-backend-flex -n trident -o jsonpath='{.status.message}' 2>/dev/null || true)
#   if (( ELAPSED >= TIMEOUT )); then
#     echo "ERROR: Timeout waiting for ANF backend (phase: ${PHASE:-none}, message: ${MESSAGE:-none})" >&2
#     oc describe tridentbackendconfig anf-backend-flex -n trident 2>/dev/null | tail -20
#     exit 1
#   fi
#   echo "    Backend phase: ${PHASE:-pending}, message: ${MESSAGE:-waiting...} (${ELAPSED}s/${TIMEOUT}s)"
#   sleep 10
#   (( ELAPSED += 10 ))
# done

# Create storage class for trident
echo "==> [netapp] Creating StorageClass anf-flex..."
cat << EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: anf-flex
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    storageclass.kubevirt.io/is-default-virt-class: "true"
provisioner: csi.trident.netapp.io
parameters:
  backendType: "azure-netapp-files"
  selector: qos=manual60mbps
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
echo "    StorageClass applied."

# Need to patch the storage profile for RWX and volumemode
echo "==> [netapp] Patching storage profile for RWX and volumemode..."
oc patch storageprofile anf-flex --type='json' -p='[{"op": "replace", "path": "/spec/claimPropertySets", "value": [{"accessModes": ["ReadWriteMany"], "volumeMode": "Filesystem"}]}]'
echo "    Storage profile patched."

# create test pvc
echo "==> [netapp] Creating test PVC anf-test-pvc..."
cat << EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anf-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: anf-flex
EOF
echo "    Test PVC applied."

#  Create snapshots
echo "==> [netapp] Creating VolumeSnapshotClass anf-flex-volumesnapshot..."
cat << EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: anf-flex-volumesnapshot
driver: csi.trident.netapp.io
deletionPolicy: Delete
EOF
echo "    VolumeSnapshotClass applied."

echo "==> [netapp] Done. Azure NetApp Files + Trident setup complete."

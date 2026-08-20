#!/bin/bash

# Register the NetApp provider
az provider register --namespace Microsoft.NetApp --wait

RESOURCE_GROUP="ans-rhpowell-rg"
LOCATION="uksouth"
ANF_ACCOUNT_NAME="netappfiles"

# Create the NetApp account
az netappfiles account create --resource-group $RESOURCE_GROUP --location $LOCATION --name $ANF_ACCOUNT_NAME

# Create the NetApp pool
POOL_NAME="Standard"
POOL_SIZE_TiB=4
SERVICE_LEVEL="Standard"

# Create the NetApp pool TODO: This line needs to be fixed for flex and throughput
az netappfiles pool create --resource-group $RESOURCE_GROUP --location $LOCATION --account-name $ANF_ACCOUNT_NAME --pool-name $POOL_NAME --size $POOL_SIZE_TiB --service-level $SERVICE_LEVEL

# Create the NetApp subnet
VNET_NAME="ans-rhpowell-vnet"
SUBNET_NAME="ans-rhpowell-netapp"
SUBNET_PREFIX="10.0.2.0/24"

if ! az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --output none 2>/dev/null; then
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --address-prefixes "$SUBNET_PREFIX" \
    --delegations Microsoft.NetApp/volumes
else
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --delegations Microsoft.NetApp/volumes
fi

# Install the Trident operator TODO: This needs testing
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


# Create trident orchestrator
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

# create secret for trident (clientID/clientSecret keys required by Trident)
az ad sp create-for-rbac --name "trident-client" --role "Contributor" --scopes "/subscriptions/40e9c766-090f-476b-bf33-cc3f24d0b5f8/resourceGroups/ans-rhpowell-rg"

CLIENT_ID=$(az ad sp list --display-name "trident-client" --query "[0].appId" -o tsv)
CLIENT_SECRET=$(az ad sp credential reset --name "trident-client" --query "password" -o tsv)

oc -n trident create secret generic anf-credentials \
  --from-literal=clientID="$CLIENT_ID" \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | oc apply -f -

# create backend config for trident
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
  subscriptionID: 40e9c766-090f-476b-bf33-cc3f24d0b5f8
  tenantID: 64dc69e4-d083-49fc-9569-ebece1dd1408
  location: uksouth
  networkFeatures: Standard
  resourceGroups:
    - ans-rhpowell-rg
  netappAccounts:
    - ans-rhpowell-rg/netappfiles
  capacityPools:
    - ans-rhpowell-rg/netappfiles/Standard
  virtualNetwork: ans-rhpowell-rg/openshift-vnet
  subnet: ans-rhpowell-rg/openshift-vnet/ans-rhpowell-netapp
  nfsMountOptions: nfsvers=3,nconnect=4
  defaults:
    unixPermissions: "0777"
    maxThroughput: "60"
    qosType: "Manual"
  labels:
    qos: manual60mbps
EOF

echo "Waiting for ANF backend to be created..."
TIMEOUT=300
ELAPSED=0
while true; do
  PHASE=$(oc get tridentbackendconfig anf-backend-flex -n trident -o jsonpath='{.status.phase}' 2>/dev/null || true)
  BACKEND=$(oc get tridentbackend -n trident -o jsonpath='{.items[0].backendName}' 2>/dev/null || true)
  if [[ "$PHASE" == "Bound" && -n "$BACKEND" ]]; then
    echo "ANF backend created successfully: ${BACKEND}"
    oc get tridentbackendconfig anf-backend-flex -n trident
    oc get tridentbackend -n trident
    break
  fi
  MESSAGE=$(oc get tridentbackendconfig anf-backend-flex -n trident -o jsonpath='{.status.message}' 2>/dev/null || true)
  if (( ELAPSED >= TIMEOUT )); then
    echo "Timeout waiting for ANF backend (phase: ${PHASE:-none}, message: ${MESSAGE:-none})" >&2
    oc describe tridentbackendconfig anf-backend-flex -n trident 2>/dev/null | tail -20
    exit 1
  fi
  echo "Backend phase: ${PHASE:-pending}, message: ${MESSAGE:-waiting...}"
  sleep 10
  (( ELAPSED += 10 ))
done

# Create storage class for trident
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

# create test pvc
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

#  Create snapshots
cat << EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: anf-flex-volumesnapshot
driver: csi.trident.netapp.io
deletionPolicy: Delete
EOF
#!/usr/bin/env bash
set -euo pipefail

# Check for required tools
required_tools=(oc jq yq)
missing=()

for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "Missing required tools: ${missing[*]}" >&2
  echo "Install them and re-run this script." >&2
  exit 1
fi

# Create scratch directory
SCRATCH_DIR="$(pwd)/scratch"
if [[ ! -d "$SCRATCH_DIR" ]]; then
  mkdir -p "$SCRATCH_DIR"
fi

# its easier to install netapp before virt
./netapp.sh

# add machine set for virt
export SCRATCH_DIR
export ARO_BOOST_INSTANCE="Standard_D8s_v5"
export VIRT_MACHINESET_NAME="virt-machine-set"

for MACHINESET_NAME in $(oc get machineset -n openshift-machine-api -o json | jq -r '.items[].metadata.name'); do
VIRT_NAME=$(echo "${MACHINESET_NAME}" | sed "s/.*-worker/${VIRT_MACHINESET_NAME}/")
oc get machineset "${MACHINESET_NAME}" -n openshift-machine-api  -o yaml | \
yq e ".metadata.name = \"${VIRT_NAME}\" | \
        .spec.selector.matchLabels.\"machine.openshift.io/cluster-api-machineset\" = \"${VIRT_NAME}\" | \
        .spec.template.metadata.labels.\"machine.openshift.io/cluster-api-machineset\" = \"${VIRT_NAME}\" | \
        .spec.template.spec.providerSpec.value.vmSize = \"${ARO_BOOST_INSTANCE}\"" - >  "${SCRATCH_DIR}/${VIRT_NAME}.yaml"
oc apply -f "${SCRATCH_DIR}/${VIRT_NAME}.yaml"
done

# Install virt operators
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
EOF

echo "Waiting for OpenShift Virtualization operator to install..."
TIMEOUT=600
ELAPSED=0
while true; do
  PHASE=$(oc get csv -n openshift-cnv -l operators.coreos.com/hco-operatorhub.openshift-cnv -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  if [[ "$PHASE" == "Succeeded" ]]; then
    echo "OpenShift Virtualization operator installed."
    break
  fi
  if (( ELAPSED >= TIMEOUT )); then
    echo "Timeout waiting for OpenShift Virtualization operator (last phase: ${PHASE:-none})" >&2
    exit 1
  fi
  echo "Operator phase: ${PHASE:-pending}, waiting..."
  sleep 15
  (( ELAPSED += 15 ))
done

cat << EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  annotations:
    deployOVS: 'false'
  namespace: openshift-cnv
spec:
  enableCommonBootImageImport: true
  virtualMachineOptions:
    disableFreePageReporting: false
    disableSerialConsoleLog: false
  higherWorkloadDensity:
    memoryOvercommitPercentage: 100
  liveMigrationConfig:
    allowAutoConverge: false
    allowPostCopy: false
    completionTimeoutPerGiB: 150
    parallelMigrationsPerCluster: 5
    parallelOutboundMigrationsPerNode: 2
    progressTimeout: 150
  certConfig:
    ca:
      duration: 48h0m0s
      renewBefore: 24h0m0s
    server:
      duration: 24h0m0s
      renewBefore: 12h0m0s
  enableApplicationAwareQuota: false
  applicationAwareConfig:
    allowApplicationAwareClusterResourceQuota: false
    vmiCalcConfigName: DedicatedVirtualResources
  featureGates:
    downwardMetrics: false
    disableMDevConfiguration: false
    deployKubeSecondaryDNS: false
    alignCPUs: false
    persistentReservation: false
  workloadUpdateStrategy:
    batchEvictionInterval: 1m0s
    batchEvictionSize: 10
    workloadUpdateMethods:
      - LiveMigrate
  deployVmConsoleProxy: false
  uninstallStrategy: BlockUninstallIfWorkloadsExist
  resourceRequirements:
    vmiCPUAllocationRatio: 10
EOF
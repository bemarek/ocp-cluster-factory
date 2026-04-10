#!/bin/bash

# --- CONFIGURATION VARIABLES ---
REPO_URL="https://github.com/bemarek/ocp-cluster-factory.git"
TARGET_BRANCH="main"
NAMESPACE="openshift-gitops"

echo "=== Step 1: Installing GitOps Operator on Hub ==="
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "=== Waiting for the default ArgoCD instance to be initialized ==="
# After installation, GitOps Operator creates the openshift-gitops namespace and built-in ServiceAccount
while ! oc get sa openshift-gitops-argocd-application-controller -n ${NAMESPACE} >/dev/null 2>&1; do
  echo "Waiting for the ArgoCD controller ServiceAccount to be created..."
  sleep 10
done

echo "=== Step 2: Elevating ArgoCD privileges (granting cluster-admin role) ==="
# Grant permissions allowing ArgoCD to manage cluster-scoped objects on the Hub
oc adm policy add-cluster-role-to-user --rolebinding-name="openshift-gitops-cluster-admin" cluster-admin -z openshift-gitops-argocd-application-controller -n ${NAMESPACE}

echo "=== Step 3: Configuring Hub as the Principal for future Agents ==="
# Patch the default ArgoCD instance to enable the Principal component
oc patch argocd openshift-gitops -n ${NAMESPACE} --type=merge -p='{
  "spec": {
    "argoCDAgent": {
      "principal": {
        "enabled": true
      }
    }
  }
}'

echo "=== Step 4: Waiting for the Principal Route to be created by the Operator ==="
# We must wait for the Route because we need its hostname to generate the correct TLS certificate
while ! oc get route openshift-gitops-agent-principal -n ${NAMESPACE} >/dev/null 2>&1; do
  echo "Waiting for the Principal Route..."
  sleep 5
done

PRINCIPAL_DNS=$(oc get route openshift-gitops-agent-principal -n ${NAMESPACE} -o jsonpath='{.spec.host}')
PROXY_DNS="openshift-gitops-agent-principal-resource-proxy"

echo "=== Step 5: Generating PKI and mTLS certificates using OpenSSL ==="
# Create a temporary directory for our certificates
CERT_DIR=$(mktemp -d)

# 5.1 Generate Self-Signed CA
openssl genrsa -out ${CERT_DIR}/ca.key 2048
openssl req -x509 -new -nodes -key ${CERT_DIR}/ca.key -subj "/CN=ArgoCD-Agent-CA" -days 3650 -out ${CERT_DIR}/ca.crt

# 5.2 Generate Principal TLS Certificate signed by our CA
openssl genrsa -out ${CERT_DIR}/principal.key 2048
openssl req -new -key ${CERT_DIR}/principal.key -subj "/CN=argocd-principal" -out ${CERT_DIR}/principal.csr
openssl x509 -req -in ${CERT_DIR}/principal.csr -CA ${CERT_DIR}/ca.crt -CAkey ${CERT_DIR}/ca.key -CAcreateserial -out ${CERT_DIR}/principal.crt -days 3650 -extfile <(printf "subjectAltName=DNS:${PRINCIPAL_DNS}")

# 5.3 Generate Resource Proxy TLS Certificate signed by our CA
openssl genrsa -out ${CERT_DIR}/proxy.key 2048
openssl req -new -key ${CERT_DIR}/proxy.key -subj "/CN=${PROXY_DNS}" -out ${CERT_DIR}/proxy.csr
openssl x509 -req -in ${CERT_DIR}/proxy.csr -CA ${CERT_DIR}/ca.crt -CAkey ${CERT_DIR}/ca.key -CAcreateserial -out ${CERT_DIR}/proxy.crt -days 3650 -extfile <(printf "subjectAltName=DNS:${PROXY_DNS}")

# 5.4 Generate 4096-bit RSA Private Key for JWT authentication
openssl genpkey -algorithm RSA -out ${CERT_DIR}/jwt.key -pkeyopt rsa_keygen_bits:4096

echo "=== Step 6: Deploying PKI Secrets to the cluster ==="
# For satefy
oc delete secret argocd-agent-ca argocd-agent-principal-tls argocd-agent-resource-proxy-tls argocd-agent-jwt -n ${NAMESPACE} --ignore-not-found
# Create the required TLS and Opaque secrets in the control plane namespace
oc create secret tls argocd-agent-ca --cert=${CERT_DIR}/ca.crt --key=${CERT_DIR}/ca.key -n ${NAMESPACE}
oc create secret tls argocd-agent-principal-tls --cert=${CERT_DIR}/principal.crt --key=${CERT_DIR}/principal.key -n ${NAMESPACE}
oc create secret tls argocd-agent-resource-proxy-tls --cert=${CERT_DIR}/proxy.crt --key=${CERT_DIR}/proxy.key -n ${NAMESPACE}
oc create secret generic argocd-agent-jwt --from-file=jwt.key=${CERT_DIR}/jwt.key -n ${NAMESPACE}

# Clean up temporary certificate directory
rm -rf ${CERT_DIR}

echo "=== Step 7: Registering the local Hub cluster explicitly ==="
# Create a Secret to expose the local in-cluster environment to the Cluster generator
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster-secret
  namespace: ${NAMESPACE}
  labels:
    # Mandatory label for ArgoCD to recognize this secret as a cluster definition
    argocd.argoproj.io/secret-type: cluster
    # Custom label used by our local ApplicationSet selector
    environment: hub
type: Opaque
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
EOF

echo "=== Step 8: Deploying the ApplicationSet for the Hub configuration ==="
# Deploy the ApplicationSet that targets ONLY the local Hub cluster
oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hub-config-appset
  namespace: ${NAMESPACE}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - clusters:
      selector:
        matchLabels:
        # Use matchExpressions to target multiple clusters by labels
        matchExpressions:
          - key: environment
            operator: In
            values:
              - hub
  template:
    metadata:
      name: 'cfg-{{.name}}'
      namespace: ${NAMESPACE}
    spec:
      project: default
      source:
        repoURL: '${REPO_URL}'
        targetRevision: '${TARGET_BRANCH}'
        path: 'overlays/{{.name}}'
      destination:
        server: '{{.server}}'
        namespace: ${NAMESPACE}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF

echo "=== Step 9: Enabling GitOps console plugin ==="
# Patch the cluster Console operator to enable the gitops-plugin
oc patch console.operator cluster --type=merge -p '{"spec":{"plugins":["gitops-plugin"]}}'

echo "=== Hub Bootstrap process completed successfully! ==="
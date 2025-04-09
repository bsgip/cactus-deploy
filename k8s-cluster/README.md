# This is still **WIP / DRAFT**
TODO:
- Anything related to the Harness UI is yet to be decided
- Better namespace names
- Namespace for templates + guard against delete

## (1) Cluster creation
Getting started (Ubuntu 24.04):
0. Setup and harden using standard scripts.
1. Install microk8s on all nodes: https://microk8s.io/docs/getting-started
2. Make a k8suser on the control node, add them to `sudo` group.
3. QoL, so you don't have to keep typing `microk8s kubectl`, add the following to `/home/k8suser/.bashrc`:
```
alias k8s="microk8s kubectl"
source <(microk8s kubectl completion bash)
complete -o default -F __start_kubectl k8s
```
4. On the designated control plane node, run `microk8s add-node` and follow instructions returned to add other nodes (as workers) to the cluster.
5. Enable the following addons:
```
microk8s enable ingress dns
```
6. Enable the load balancer addon: `microk8s enable metallb`. It will ask for an IP range for the load balancer - since we only need one, assign a free static IP that you want to expose for your FQDN.

## (2) Preparing k8s manifests
microk8s/kubernetes has no out-of-the-box utility for configurable yaml manifests. We instead use a custom script which relies on `envsubst` to substitute variables.

1. Make a working directory `mkdir /home/k8suser/k8s-cluster/`.

2. Define a .env file with the following vars:
```
APP_ENVOY_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_RUNNER_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_ORCHESTRATOR_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_UI_IMAGE='<registry>/<image-name>:<tag>'
TEST_EXECUTION_FQDN='<subdomain>.<domain>.<tld>'
TEST_ORCHESTRATION_FQDN='<subdomain>.<domain>.<tld>'
CACTUS_ORCHESTRATOR_BASEURL='https://<svc_name>.<namespace>.svc.cluster.local'
CACTUS_ORCHESTRATOR_AUDIENCE='<oauth2-audience>'
```

2. The `templates-to-manifests.sh` script copies the `deploy-template` directory and applies environment variables to the Kubernetes manifest templates. Usage:
```
./templates-to-manfests.sh ./deploy-template /home/k8suser/k8s-cluster/deploy/ /home/k8suser/k8s-cluster/.env
```

## Cluster configuration (./cluster-setup)
1. Apply at-rest-encryption to the microk8s secret store. Run the `setup-encryption.sh` script.

2. We make three namespaces (1) for test execution resources (2) for test orchestration resources (3) for the template resources we clone:
```
1. microk8s kubectl create namespace test-execution
2. microk8s kubectl create namespace test-orchestration
3. microk8s kubectl create namespace teststack-templates
```
3. Create a privileged service account in the `test-orchestration` namespace. This account has permissions to create and destroy resources and is used by the harness-orchestrator/test-orchestration pods.
```
microk8s apply -f test-orchestration-service-account.yaml -n test-orchestration
```
4. Add private image registry to each namespace individually (kubectl approach):

(a) `test-execution` and `teststack-templates` namespaces:
```
microk8s kubectl create secret docker-registry acr-token --docker-server=<somereg.io> --docker-username="<token-name>" --docker-password="<token-pwd>" --namespace <namespace>

microk8s kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "acr-token"}]}' --namespace <namespace>
```
(b) `test-orchestration` namespace (NOTE: The only difference here is the service account name.):
```
microk8s kubectl create secret docker-registry acr-token --docker-server=<somereg.io> --docker-username="<token-name>" --docker-password="<token-pwd>" --namespace test-orchestration

microk8s kubectl patch serviceaccount pod-creator -p '{"imagePullSecrets": [{"name": "acr-token"}]}' --namespace test-orchestration
```
5. Create the ingress load-balancer service and ingress resources
```
microk8s kubectl apply -f ./ingress/load-balancer-svc.yml -n ingress
microk8s kubectl apply -f ./ingress/test-execution-ingress.yml -n test-execution
# TODO: microk8s kubectl apply -f ./ingress/user-interface-ingress.yml -n ?
```

6. Add custom CA secrets in the `test-execution` namespace. We need needs two secrets:
 1. For Ingress (contains the CA cert only).
 2. For signing client certificates (contains both the CA certificate and key).
```
k8s create secret generic -n test-execution tls-ca-certificate --from-file=ca.crt=<path-to-ca.crt>
k8s create secret tls tls-ca-cert-key-pair -n test-execution --cert <path-to-ca.crt> --key <path-to-unencrypted-ca.key>
```

7. Add server certificate/key secrets.
```
# for test-execution ingress
ingress/install-server-certs.sh --cert </path/to/cert.crt> --key </path/to/key.key> --namespace test-execution --ingress test-execution-ingress

ingress/install-server-certs.sh --cert </path/to/cert.crt> --key </path/to/key.key> --namespace test-orchestration --ingress user-interface-ingress
```
## K8s resource setup (./app-setup)
0. Create app secrets.
```
# This secret is the connection string the harness-orchestrator uses to connect to the db. NOTE: Alembic scripts are provided for running migrations under project-root/alembic/.
kubectl create secret generic orchestrator-db-secret --from-literal=ORCHESTRATOR_DATABASE_URL='<python-sqlalchemy-connstr>'

# UI secrets:
# Oauth2 and app related secrets
kubectl create secret generic -n test-orchestration cactus-ui-oauth2-client-id --from-literal=OAUTH2_CLIENT_ID='<oauth2-client-id>'
kubectl create secret generic -n test-orchestration cactus-ui-oauth2-client-secret --from-literal=OAUTH2_CLIENT_SECRET='<oauth2-client-secret>'
kubectl create secret generic -n test-orchestration cactus-ui-oauth2-domain --from-literal=OAUTH2_DOMAIN='<oauth2-domain>'
kubectl create secret generic -n test-orchestration cactus-ui-app-key --from-literal=APP_SECRET_KEY='<app-secret-key>'
```
1. We create the cactus-orchestrator service. This manages the on-demand creation and deletion of the full envoy 'test environment' stack.
```
microk8s kubectl apply -f cactus-orchestrator -n test-orchestration
```

2. Currently, we create 'template' resources that represent a complete envoy test environments. These are cloned when a client requests a new test environment. Create the template resources with:
```
microk8s kubectl apply -f envoy-environment -n teststack-templates
```
This README describes the end-to-end setup of the cactus orchestration platform using microk8s.

NOTE: All commands should be run on the control plan (head) node unless specified otherwise.

## (1) Cluster creation
Getting started (Ubuntu 24.04):
0. Setup and harden using standard scripts.
1. Make a k8suser ONLY on the control node, add that to `sudo` group.
2. QoL, so you don't have to keep typing `microk8s kubectl`, add the following to `/home/k8suser/.bashrc`:
```
alias k8s="microk8s kubectl"
source <(microk8s kubectl completion bash)
complete -o default -F __start_kubectl k8s
```
3. Install microk8s on all nodes: https://microk8s.io/docs/getting-started.
    1. For the control node follow the instruction to step 4 using the k8suser  
    2. For the worker nodes only install the software but dont set up the user (you will be using root instead, as these workes do not need to be touched again)
4. On the designated control plane node, run `microk8s add-node` and follow instructions returned to add other nodes (as workers) to the cluster. No further steps are needed on the worker nodes. You can check nodes are connected by running `microk8s kubectl get nodes` on the control plane node.
    1. step 4 needs to be repeated per worker node to generate a new token\
    2. on the control node check that the workers have been added `k8s get nodes`   
5. Enable the following addons on the control node:
```
microk8s enable cert-manager
microk8s enable ingress dns
```
6. Enable the IP advitiser addon: `microk8s enable metallb`. It will ask for an IP range for the load balancer - since we only need one, assign a free static IP that you want to expose for your FQDN. It will request a range, just provide a single value range e.g. 192.168.1.1-192.168.1.1

## (2) Preparing k8s manifests
microk8s/kubernetes has no out-of-the-box utility for configurable yaml manifests. We instead use a custom script which relies on `envsubst` to substitute variables.

1. Make a working directory `mkdir /home/k8suser/k8s-cluster/`.

2. Define a .env file with the following vars:
NOTE: For more information regarding the environment variables, refer to the associated repository.
```
# general
LETS_ENCRYPT_EMAIL='<sysadmin@example.com>'

# images
CACTUS_ENVOY_APP_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_TESTSTACK_INIT_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_RUNNER_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_ORCHESTRATOR_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_UI_IMAGE='<registry>/<image-name>:<tag>'
CACTUS_ENVOY_DB_IMAGE=postgres:15

# NOTE - changing from postgres:15 will require updating the postgresql-client version used in various Dockerfiles

# cactus-orchestrator (https://github/bsgip/cactus-orchestrator)
TEST_EXECUTION_FQDN='<subdomain>.<domain>.<tld>'
TEST_ORCHESTRATION_FQDN='<subdomain>.<domain>.<tld>'
JWTAUTH_JWKS_URL="<jwks-url>" # defined in authorisation server, e.g. Auth0
JWTAUTH_ISSUER="<issuer>" # defined in authorisation server, e.g. Auth0
JWTAUTH_AUDIENCE="<audience>" # defined in authorisation server, e.g. Auth0

# cactus-ui (https://github/bsgip/cactus-ui)
CACTUS_ORCHESTRATOR_BASEURL='https://cactus-orchestrator-service.test-orchestration.svc.cluster.local' # NB. format is https://<svc_name>.<namespace>.svc.cluster.local, update svc_name/namespace here if ever modified.
CACTUS_ORCHESTRATOR_AUDIENCE='<audience>' # defined in authorisation server, e.g. Auth0
CACTUS_PLATFORM_VERSION='v<x.x.x>'
CACTUS_PLATFORM_SUPPORT_EMAIL='<support@email>'
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
microk8s kubectl apply -f test-orchestration-service-account.yaml -n test-orchestration
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

microk8s kubectl patch serviceaccount pod-creator -p '{"imagePullSecrets": [{"name": "acr-token"}]}' --namespace test-orchestration # orchestrator app account
microk8s kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "acr-token"}]}' --namespace test-orchestration # default account, UI app uses this
```
5. Create the ingress load-balancer service and ingress resources
```
microk8s kubectl apply -f ./ingress/lets-encrypt-issuer.yaml -n test-execution
microk8s kubectl apply -f ./ingress/lets-encrypt-issuer.yaml -n test-orchestration
microk8s kubectl apply -f ./ingress/load-balancer-svc.yaml -n ingress
microk8s kubectl apply -f ./ingress/test-execution-ingress.yaml -n test-execution
microk8s kubectl apply -f ./ingress/user-interface-ingress.yaml -n test-orchestration
```

6. Add custom CA certificate and key files as a Kubernetes Secrets in the `test-execution` namespace. We need two secrets:
 1. For Ingress (contains the CA cert only) to validate the client certificate.
 2. For signing client certificates (contains both the CA certificate and key) in the orchestrator app when a new certificate is requested.
```
k8s create secret generic -n test-execution tls-ca-certificate --from-file=ca.crt=<path-to-ca.crt>
k8s create secret tls tls-ca-cert-key-pair -n test-execution --cert <path-to-ca.crt> --key <path-to-unencrypted-ca.key>
```

## K8s resource setup (./app-setup)
0. Create Kubernetes Secrets for the applications. NOTE: Refer to the specific applications repository for details regarding the variable being stored in the secret store.
```
# cactus-orchestrator (https://github.com/bsgip/cactus-orchestrator)
# This secret is the connection string the harness-orchestrator uses to connect to the db. The db is expected to be hosted externally to the cluster but accessible to it.
kubectl create secret generic orchestrator-db-secret --from-literal=ORCHESTRATOR_DATABASE_URL='<python-sqlalchemy-connstr>'

# cactus-ui (https://github.com/bsgip/cactus-ui)
# Oauth2 and app related secrets
microk8s kubectl create secret generic -n test-orchestration cactus-ui-oauth2-client-id --from-literal=OAUTH2_CLIENT_ID='<oauth2-client-id>'
microk8s kubectl create secret generic -n test-orchestration cactus-ui-oauth2-client-secret --from-literal=OAUTH2_CLIENT_SECRET='<oauth2-client-secret>'
microk8s kubectl create secret generic -n test-orchestration cactus-ui-oauth2-domain --from-literal=OAUTH2_DOMAIN='<oauth2-domain>'
microk8s kubectl create secret generic -n test-orchestration cactus-ui-app-key --from-literal=APP_SECRET_KEY='<app-secret-key>'
```
1. Create the cactus-teststack-imagepuller DaemonSet. This will ensure that all current/future nodes "pre pull" all docker images (improving first startup times)
```
microk8s kubectl apply -f cactus-teststack-imagepuller.yaml -n teststack-templates
```

2. We create the cactus-orchestrator service. This manages the on-demand creation and deletion of the full 'test environment' stack.
```
microk8s kubectl apply -f cactus-orchestrator.yaml -n test-orchestration
```

3. Currently, we create 'template' resources that represent a complete envoy test environments. These are cloned when a client requests a new test environment. Create the template resources with:
```
microk8s kubectl apply -f envoy-teststack.yaml -n teststack-templates
```

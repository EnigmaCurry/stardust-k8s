default:
	@echo "The default 'make' target does nothing."
	@echo "Available make targets: "
	@LC_ALL=C $(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | egrep -v -e '^[^[:alnum:]]' -e '^$@$$' | sort -u | awk -vORS=, '{ print }' | sed 's/,$$/\n/' | sed 's/,/, /g' | fmt

## Update all helm chart repositories
helm-update:
	helm repo add traefik https://helm.traefik.io/traefik
	helm repo add hashicorp https://helm.releases.hashicorp.com
	helm repo add harbor https://helm.goharbor.io
	helm repo add jetstack https://charts.jetstack.io
	helm repo add openfaas https://openfaas.github.io/faas-netes/
	helm repo update

kill-port-forwards:
	pkill -f "kubectl.*port-forward"

alpine:
	@echo This is a *temporary* container!
	source lib/k8s-util.sh
	kubectl run -n default --rm -i --tty tmp-alpine --image=alpine:3 --restart=Never -- /bin/sh

python:
	@echo This is a *temporary* container!
	source lib/k8s-util.sh
	kubectl run -n default --rm -i --tty tmp-python --image=python:3.9 --restart=Never

#####################################################################
## Fluentd (Router for Logs)
## kube-fluentd-operator assumes K8s nodes have systemd.
## If your K8s nodes do not have systemd (eg. KinD),
## create /var/log/journal on all the nodes.
## The directory just has to exist, it can be empty.
fluentd-system:
	kubectl apply -k src/kube-fluentd/base
	helm upgrade --install kfo --namespace fluentd-system https://github.com/vmware/kube-fluentd-operator/releases/download/v1.15.2/log-router-0.4.0.tgz --set rbac.create=true --set image.tag=v1.15.2 --set image.repository=vmware/kube-fluentd-operator --set datasource=crd --set adminNamespace=fluentd-system

.ONESHELL:
fluentd-system-config-s3-backup:
	@echo "Creating Fluentd S3 configuration. Please enter your S3 connection info:"
	@read -p "Enter S3 fully qualified endpoint domain: " S3_ENDPOINT
	@read -p "Enter S3 bucket name: " S3_BUCKET
	@read -p "Enter S3 Access Key: " S3_ACCESS_KEY
	@read -p "Enter S3 Secret Key: " S3_SECRET_KEY
	@read -p "Enter the cluster full domain name: " S3_BASE_DIRECTORY
	export S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_BASE_DIRECTORY
	cat src/kube-fluentd/template/fluentd-system-config-S3.yaml | envsubst '$$S3_ENDPOINT $$S3_BUCKET $$S3_ACCESS_KEY $$S3_SECRET_KEY $$S3_BASE_DIRECTORY' | kubectl apply -f -
.ONESHELL:
fluentd-system-config-s3-backup-global:
	@echo "Creating Fluentd S3 configuration. Please enter your S3 connection info:"
	@read -p "Enter S3 fully qualified endpoint domain: " S3_ENDPOINT
	@read -p "Enter S3 bucket name: " S3_BUCKET
	@read -p "Enter S3 Access Key: " S3_ACCESS_KEY
	@read -p "Enter S3 Secret Key: " S3_SECRET_KEY
	@read -p "Enter the cluster full domain name: " S3_BASE_DIRECTORY
	export S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_BASE_DIRECTORY
	cat src/kube-fluentd/template/fluentd-system-config-S3-global.yaml | envsubst '$$S3_ENDPOINT $$S3_BUCKET $$S3_ACCESS_KEY $$S3_SECRET_KEY $$S3_BASE_DIRECTORY' | kubectl apply -f -
fluentd-system-config-file-global:
	kubectl apply -f src/kube-fluentd/template/fluentd-system-config-file-global.yaml
fluentd-system-config-blank:
	kubectl apply -f src/kube-fluentd/template/fluentd-system-config-blank.yaml

fluentd-demo:
	kubectl apply -k src/kube-fluentd/demo

#####################################################################
## MetalLB
metallb-system:
	kubectl get ns metallb-system 2>/dev/null || kubectl create -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
	kubectl -n metallb-system get secret memberlist 2>/dev/null || kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$$(openssl rand -base64 128)"
metallb-kind-sys:
	kubectl apply -k src/metallb/kind-sys

#####################################################################
## Prometheus / Grafana / Alertmanager (metrics and monitoring)
## kube-promethues gets installed to `monitoring` namespace, because its hard-coded that way.
prometheus-system:
	kubectl apply -k src/kube-prometheus/setup
	until kubectl get servicemonitors --all-namespaces ; do date; sleep 1; echo ""; done
	kubectl apply -k src/kube-prometheus/base
prometheus-system-destroy:
	kubectl delete -k src/kube-prometheus/base
	kubectl delete -k src/kube-prometheus/setup
prometheus-system-dashboard:
	kubectl --namespace monitoring port-forward svc/prometheus-k8s 9090 &
	sleep 1 && xdg-open http://localhost:9090
prometheus-system-grafana:
	kubectl --namespace monitoring port-forward svc/grafana 3000 &
	sleep 1 && xdg-open http://localhost:3000
prometheus-system-alert-manager:
	kubectl --namespace monitoring port-forward svc/alertmanager-main 9093 &
	sleep 1 && xdg-open http://localhost:9093

#####################################################################
## Consul
consul-system:
	helm upgrade --install -f src/consul/base/consul-values.yaml consul hashicorp/consul --namespace consul-system --create-namespace
	kubectl apply -k src/consul/base
consul-system-gossip-keygen:
	kubectl create -n consul-system secret generic consul-gossip-encryption-key --from-literal=key=$(kubectl -n consul-system exec -it consul-server-0 -- consul keygen)
consul-demo:
	kubectl apply -f src/consul/demo/consul-demo-namespace.yaml
	kubectl apply -k src/consul/demo
consul-system-dashboard:
	kubectl -n consul-system port-forward svc/consul-ui 18500:443 &
	sleep 1 && xdg-open https://localhost:18500/
consul-debug-volume:
	source lib/k8s-util.sh
	run_with_pvc consul-system alpine:3 data-consul-system-consul-server-0 /bin/sh
consul-fix-permissions:
	source lib/k8s-util.sh
	pvc_fix_perms consul-system data-consul-system-consul-server-0 100 0700

#####################################################################
## cert-manager
cert-manager-system:
	helm install cert-manager jetstack/cert-manager --namespace cert-manager-system --create-namespace --set installCRDs=true

## DigialOcean ACME DNS provider
## Use this as a template for any DNS provider supported by cert-manager:
## https://cert-manager.io/docs/configuration/acme/dns01/
.ONESHELL:
cert-manager-issuer-digitalocean-dns:
	@echo "Creating cert-manager ACME DNS01 Challenge Provider for DigitalOcean."
	@read -p "Your email address ACME_EMAIL: " ACME_EMAIL
	@read -p "Use production ACME CA server? (Y/n)" USE_PROD_CA_SERVER
	if [ "$${USE_PROD_CA_SERVER,,}" = "n" ]; then
		ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
	else
		ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
	fi
	@echo ""
	@read -p "Enter your DigitalOcean API token: " DO_AUTH_TOKEN
	@echo "Configuration recorded:"
	@echo "ACME_EMAIL=$${ACME_EMAIL}"
	@echo "ACME_CA_SERVER=$${ACME_CA_SERVER}"
	@echo "DO_AUTH_TOKEN=$${DO_AUTH_TOKEN}"
	@echo ""
	@read -p "Is this correct? (y/N) " ACME_CORRECT
	export ACME_EMAIL ACME_CA_SERVER DO_AUTH_TOKEN ACME_ZONE NAMESPACE
	if [ "$${ACME_CORRECT,,}" = "y" ]; then
		kubectl create -n cert-manager-system secret generic digitalocean-dns --from-literal=access-token=$${DO_AUTH_TOKEN}
		cat src/cert-manager/template/clusterissuer-digitalocean-dns.yaml | envsubst '$$ACME_EMAIL $$ACME_CA_SERVER' | kubectl apply -f -
	else
		@echo "Try again later then."
	fi

#####################################################################
## Traefik Proxy
#####################################################################
## This creates a whoami service and Ingress to request a wildcard certificate
## Traefik will find this if the Ingress provider is turned on:
##  --providers.kubernetesingress=true
traefik-system-wildcard-DNS-challenge:
	@echo "This example uses a wildcard certificate, used for the entire cluster."
	@echo "Enter the root wildcard DNS name for the cluster (eg *.example.com) :"
	@read -p "DNS_ZONE: " DNS_ZONE
	@echo "Enter the whoami-ingress sub-domain (eg whoami.example.com)"
	@read -p "WHOAMI_DOMAIN: " WHOAMI_DOMAIN
	export DNS_ZONE WHOAMI_DOMAIN
	kubectl apply -k src/traefik/whoami-ingress/base
	cat src/traefik/whoami-ingress/template/whoami-ingress.yaml | envsubst '$$WHOAMI_DOMAIN $$DNS_ZONE' | kubectl apply -f -
traefik-system-init-consul:
	helm upgrade --install -f src/traefik/base/traefik-consul-values.yaml --namespace traefik-system --create-namespace traefik traefik/traefik
traefik-system-init:
	helm upgrade --install -f src/traefik/base/traefik-values.yaml --namespace traefik-system --create-namespace traefik traefik/traefik
traefik-system-debug-volume:
	source lib/k8s-util.sh
	run_with_pvc traefik-system alpine:3 traefik /bin/sh
traefik-system-fluentd:
	kubectl apply -f src/traefik/base/traefik-fluentd-config.yaml
traefik-system-copy-consul-certs:
	kubectl apply -f src/traefik/base/traefik-namespace.yaml
	kubectl get secret consul-ca-cert -n consul-system -o yaml | sed 's/namespace: consul-system/namespace: traefik-system/' | kubectl apply -n traefik-system -f -
.ONESHELL:
traefik-system-whoami:
	@echo "Enter the domain for the whoami service (eg. whoami.example.com): "
	@read -p "WHOAMI_DOMAIN: " WHOAMI_DOMAIN
	@echo "Enter a one-word name to be reported by the whoami service (eg `test`): "
	@read -p "WHOAMI_NAME: " WHOAMI_NAME
	export WHOAMI_DOMAIN WHOAMI_NAME
	cat src/traefik/whoami-ingressroute/template/whoami.yaml | envsubst '$$WHOAMI_NAME' | kubectl apply -f -
	cat src/traefik/whoami-ingressroute/template/whoami-ingress.yaml | envsubst '$$WHOAMI_DOMAIN $$WHOAMI_NAME' | kubectl apply -f -
traefik-system-dashboard:
	UNIT=deploy/traefik
	if kubectl -n traefik-system get daemonset/traefik; then UNIT=daemonset/traefik; fi
	kubectl -n traefik-system port-forward $${UNIT} 9000:9000 &
	sleep 1 && xdg-open http://localhost:9000/dashboard/
traefik-system-dashboard-2:
	UNIT=deploy/traefik
	if kubectl -n traefik-system get daemonset/traefik; then UNIT=daemonset/traefik; fi
	kubectl -n traefik-system port-forward $${UNIT} 9001:9000 &
	sleep 1 && xdg-open http://localhost:9001/dashboard/
traefik-kind-sys:
	kubectl apply -k src/traefik/kind-sys
traefik-hub-init:
	helm upgrade --install hub hub/hub --namespace hub-agent
traefik-hub-get-endpoints:
	@echo "Endpoints: "
	kubectl -n traefik-system get svc | grep LoadBalancer | tr -s ' ' | cut -d ' ' -f 4 | sed 's/,/:443;/g' | sed -e 1's/$$/:443&/'
.ONESHELL:
traefik-hub-demo-acls:
	AUTH_USERS=()
	MORE_USERS=y
	while [ "$${MORE_USERS,,}" = "y" ]
	do
		@read -p "Enter the username: " USERNAME
		@read -p "Enter the password: " PASSWORD
		export USERNAME PASSWORD
		AUTH_USERS+=($$(kubectl run -n traefik-system --rm -i --tty tmp-htpasswd --image=httpd --restart=Never -- htpasswd -nbB $${USERNAME} $${PASSWORD} | head -1))
		@read -p "Enter more users (y/N)? " MORE_USERS
	done
	printf -v JOINED_USERS '%s,' "$${AUTH_USERS[@]}"
	BASIC_AUTH_USERS=$$(echo $$JOINED_USERS | sed 's/,$$//')
	export BASIC_AUTH_USERS
	cat src/traefik/hub/template/acp-basicauth.yaml | envsubst '$$BASIC_AUTH_USERS' | kubectl apply -f -
	kubectl -n traefik-system get accesscontrolpolicies.hub.traefik.io whoami-test -o yaml

#####################################################################
## Harbor Docker Registry Proxy Cache
harbor-system-init-cluster-ip:
	helm upgrade --install -f src/harbor/base/harbor-clusterip-values.yaml harbor harbor/harbor --namespace harbor-system --create-namespace
harbor-system-init-ingress:
	@read -p "Enter the Harbor domain name: " HARBOR_DOMAIN
	helm upgrade --install --set expose.type=ingress --set expose.ingress.hosts.core=$$HARBOR_DOMAIN --set expose.ingress.hosts.notary=notary.$$HARBOR_DOMAIN --set externalURL=https://$$HARBOR_DOMAIN --set expose.tls.certSource=secret --set expose.tls.secret.secretName=harbor-tls --set expose.tls.secret.notarySecretName=harbor-notary-tls --set 'expose.ingress.annotations.cert-manager\.io/cluster-issuer=digitalocean-dns' harbor harbor/harbor --namespace harbor-system --create-namespace
harbor-fix-volume-permissions:
	source lib/k8s-util.sh
	pvc_fix_perms harbor-system data-harbor-redis-0 999 0700
	pvc_fix_perms harbor-system database-data-harbor-database-0 999 0700
	pvc_fix_perms harbor-system data-harbor-trivy-0 10000 0700
harbor-system-dashboard:
	kubectl -n harbor-system port-forward svc/harbor 8088:443 &
	sleep 1 && xdg-open https://localhost:8088/


#####################################################################
## OpenFaaS
.ONESHELL:
openfaas-system:
	@read -p "Enter the OpenFaaS gateway domain OPENFAAS_DOMAIN: " OPENFAAS_DOMAIN
	kubectl apply -k src/openfaas/base
	helm upgrade openfaas --install openfaas/openfaas --namespace openfaas-system --set functionNamespace=openfaas-fn --set ingress.enabled=true --set ingress.hosts[0].host=$${OPENFAAS_DOMAIN} --set ingress.hosts[0].serviceName=gateway --set ingress.hosts[0].servicePort=8080 --set ingress.hosts[0].path=/ --set ingress.pathType=Prefix --set generateBasicAuth=true --set ingress.annotations="{}"
	@echo "OpenFaaS admin password: $$(kubectl -n openfaas-system get secret basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode)"

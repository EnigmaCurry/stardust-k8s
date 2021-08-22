# Stardust K8s

A Kubernetes cluster configuration, featuring:

 * One `Makefile` to wrap all of the installation procedures.
 * Hybrid configuration methods:
   * Prefer to install applications from well-maintained Helm charts directly
     from external vendors. (eg. 
     [Traefik Proxy](https://github.com/traefik/traefik-helm-chart),
     [Consul](https://github.com/hashicorp/consul-helm),
     [Harbor](https://github.com/goharbor/harbor-helm),
     [cert-manager](https://cert-manager.io/docs/installation/helm/)). This
     helps to ensure that upgrades will follow vendor recommended configuration
     changes.
   * Use
     [Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
     for everything else in this repository. We like using Helm only when
     someone else is maintaining it.
 * [MetalLB](https://metallb.org/)
   * DHCP server and Load Balancer for bare metal Kubernetes installations.
   * Provides the K8s Service `LoadBalancer` type to get external IP addresses
     automatically.
   * If you are using a hosted Kubernetes platform you don't need to install
     this.
 * [Traefik Proxy](https://traefik.io/traefik/) ingress controller.
   * Let's Encrypt DNS-01 challenge for a wildcard domain name.
   * Valid browser-trusted TLS certificates, even on a private LAN.
 * [Consul Connect](https://www.consul.io/docs/connect) service mesh.
   * Lock down service-to-service interactions, with Consul Intentions.
   * Traefik Proxy can provide public ingress into your service mesh.
 * [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) a
   Prometheus Operator, monitoring of all Namespaces and Pods with Grafana
   dashboard.
   * Monitor CPU, Memory, Disk, and Network across your entire cluster.
 * [kube-fluentd-operator](https://github.com/vmware/kube-fluentd-operator)
   Fluentd Operator, aggregates logs with per-namespace `FluentdConfig` CRD
   configuration.
   * DONE: Push logs to S3.
   * TODO: Push logs to your external log aggregator (ELK).
   * TODO: Call webhook on specifc log regex.

## Setup

You will need:

 * A Kubernetes cluster
 * An Internet domain name that you control the DNS for, in order to complete
   ACME DNS01 Challenge.
   * Your DNS host needs to have an API supported by
[lego](https://go-acme.github.io/lego/dns/).
 * A workstation computer with the Bash shell.

Your workstation needs the following tools installed:

 * The Bash shell.
 * git
 * [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
   installed and configured for the cluster.
 * [helm](https://helm.sh/docs/intro/install/)
 * To open the dashboard links, install
   [xdg-open](https://man.archlinux.org/man/xdg-open.1).

Clone the repository to your workstation:

```
git clone https://github.com/EnigmaCurry/stardust-k3s.git \
  ${HOME}/git/vendor/enigmacurry/stardust-k3s
  
cd ${HOME}/git/vendor/enigmacurry/stardust-k3s
```

## Installation

Install only the pieces that you want. Some peices depend on others, and this
presents roughly the order that you should consider installing them in:

### MetalLB

Install MetalLB only if your cluster does not already support load balancing
(aka. Services of type `LoadBalancer`). If you are running on a managed
Kubernetes platform from a hosting provider (eg. EKS, GKE, DOKS, basically any
K8s you didn't install yourself), you do not require MetalLB, as the provider
usually sets this up for you. 

K3s has a [builtin LoadBalancer called
klipper](https://rancher.com/docs/k3s/latest/en/networking/#service-load-balancer),
but only supports using a single Host IP address. This means that with Klipper
you can only bind one service to a given port simultaneously. You can run
multiple Services, but they have to be on different ports. You can install and
use MetalLB instead to expand to multiple IP addresses, and therefore you can
use the same port. If you want to use MetalLB with K3s, make sure to start the
server with the `--disable servicelb` to disable Klipper.

Kind (Kubernetes in Docker) requires MetalLB. The configuration here is mostly
copied from the [Kind LoadBalancer
documentation](https://kind.sigs.k8s.io/docs/user/loadbalancer/).

Find the Docker network IP range:

```
docker network inspect -f '{{.IPAM.Config}}' kind
```

You will see something similar to:

```
[{172.18.0.0/16  172.18.0.1 map[]} {fc00:f853:ccd:e793::/64  fc00:f853:ccd:e793::1 map[]}]
```

This indicates that the kind docker network is running on the `172.18.0.0/16`
subnet.

An example is included in the `src/metallb/kind-sys` directory. Edit
`src/metallb/kind-sys/mettallb-configmap.yaml` and add a new IP address pool in
the same range as the docker network:

```
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 172.18.255.10-172.18.255.250
```

This reserves a pool of 240 IP addresses from `172.18.255.10` to
`172.18.255.250`.

Now install MetalLB:

```
make metallb-system
make metallb-kind-sys
```

### Consul

Consul creates a service mesh, so that you can create an access control policy
between all service-to-service communication.

```
make consul-system
```

Deploy the demo, which starts a whoami server inside the service mesh. Edit the
deployment in [src/consul/demo/consul-demo-whoami.yaml](), which has a
`consul.hashicorp.com/service-tags` annotation containing the Traefik router
rule. Edit the rule for your domain name, then make `consul-demo`:

The first time you start Consul, ACLs and gossip encryption will be turned off.

#### Harden consul for production

Generate a new gossip key:

```
make consul-system-gossip-keygen
```

Edit the [src/consul/base/consul-values.yaml]() find the commented out
 production values for `acls` and `gossipEncryption` and uncomment them.

Redeploy consul:

```
make consul-system
```

#### Make the demo

The demo is an instance of [whoami](https://github.com/traefik/whoami) that you
install inside the service mesh, used for testing connections and Intentions.

```
make consul-demo
```

Load the dashboard (`xdg-open` should load the URL in your browser
automatically):

```
make consul-system-dashboard
```

### Traefik Proxy 

Traefik Proxy provides ingress to your services. 

Traefik Proxy requests TLS certificates from Let's Encrypt. You must choose to
use the ACME TLS or DNS challenge. 

The DNS challenge is preferred as it can be used both in clusters exposed to the
Internet as well as for private clusters behind a firewall. The TLS challenge
requires port 443 to be open publicly from the Internet. DNS challenge can
generate a wildcard certificate (`*.example.com`) whereas TLS challenge can only
make certificates for specfic domain names.

#### Traefik Proxy with ACME DNS Challenge

If you deployed Consul, Traefik needs the Consul CA certificate, which can be
copied from the `consul-system` namespace into the `traefik-system` namespace:

```
make traefik-system-copy-consul-certs
```

Create the `traefik-acme-secret` to store your ACME DNS-01 challenge
configuration. This will setup Traefik for a wildcard domain name TLS
certificate (eg. `*.example.com`).

```
make traefik-system-acme-dns-secret
```

This will interactively ask you some questions, which you must fill in:

 * `ACME_DOMAIN` this is the wildcard DNS domain name for your new cluster.
   Traefik will be issued a single TLS certificate for this entire (sub-)domain.
   Example: `*.example.com`.
 * `ACME_EMAIL` this is your own email address, used to register with Let's
   Encrypt. Example: `you@example.com`.
 * `ACME_CA_SERVER` this the endpoint URL for the ACME provider. Let's Encrypt
   has two different endpoints, one for staging, and one for production. Choose
   the one you want, depending on if you want browser trusted certificates,
   choose the production one, or if you are testing choose the staging one:
   * Let's Encrypt STAGING: `https://acme-staging-v02.api.letsencrypt.org/directory`
   * Let's Encrypt PRODUCTION: `https://acme-v02.api.letsencrypt.org/directory`
 * `ACME_DNSCHALLENGE_PROVIDER` this the ACME DNS provider code name. Find your
   [DNS provider](https://go-acme.github.io/lego/dns/), find the `Code` name to
   enter (eg. Digital Ocean code is `digitalocean`).
 * You must enter all the variable names and values for your particular DNS
   provider (eg. Digital Ocean requires the `DO_AUTH_TOKEN` variable and value).

Once you confirm all the details, the `traefik-acme-secret` will be created on
the cluster, in the `traefik-system` namespace.

If you installed Consul, install Traefik Proxy this way:

```
make traefik-system-init-consul-dns-challenge
```

If you did not install Consul, install Traefik Proxy this way:

```
make traefik-system-init-dns-challenge
```

#### Traefik Proxy with ACME TLS Challenge

If you are deploying to a cluster exposed to the internet, you do not have to
use the DNS ACME challenge, but can use TLS ACME challenge instead. The TLS
challenge is easier to configure, but does not include support for a wildcard
certificate. Each domain name will have a unique certficate.

```
make traefik-system-acme-tls-secret
```

This will interactively ask you some questions, which you must fill in:

 * `ACME_EMAIL` this is your own email address, used to register with Let's
   Encrypt. Example: `you@example.com`.
 * `ACME_CA_SERVER` this the endpoint URL for the ACME provider. Let's Encrypt
   has two different endpoints, one for staging, and one for production. Choose
   the one you want, depending on if you want browser trusted certificates,
   choose the production one, or if you are testing choose the staging one:
   * Let's Encrypt STAGING: `https://acme-staging-v02.api.letsencrypt.org/directory`
   * Let's Encrypt PRODUCTION: `https://acme-v02.api.letsencrypt.org/directory`

Once you confirm all the details, the `traefik-acme-secret` will be created on
the cluster, in the `traefik-system` namespace.


#### Use the Traefik dashboard

The traefik dashboard is useful to show you all of the routes in your cluster
and to debug any misconfigurations.

Open the Traefik dashboard:

```
make traefik-system-dashboard
```

### Prometheus and Grafana

[kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) can
monitor all of the computing and network resources in your Kubernetes cluster.

```
make prometheus-system
```

Open the Grafana dashboard:

```
make prometheus-system-grafana
```

On the left-hand side of the screen, find the `Dashboard` icon, which looks like
four squares in a grid. Click on `Manage`, then `Default`, and you will see a
list of all of the included dashboards. Click on the `Kubernetes / Computer
Resources / Cluster` to start, and you can drill down into namespaces and pods.

### Fluentd

Fluentd will aggregate and backup your container logs and/or forward them to an
analysis engine.

If you choose to backup logs to S3 (AWS, Wasabi, DigitalOcean Spaces, etc.), you
will need to first create an S3 bucket and a IAM user that can read/write to the
bucket. You can also write to files in a local volume.

#### Creating an S3 bucket and IAM user on Wasabi

Here are instructions for creating an IAM user and S3 bucket on
[wasabi](https://wasabi.com/):
 
 * Create bucket: go to Buckets -> Create Bucket.
  * Bucket name: something like `fluentd-logs` but this must be globally unique
    amongst all users, so make something else up.
  * Choose an appropriate geographical region.
  * Create the bucket.
  
 * Create the policy: go to Policies -> Create Policy.
  * Enter the policy name: `cluster.example.com` (use the full domain name of
    your own cluster)
  * Enter the policy document:
  
```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "arn:aws:s3:::"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::fluentd-logs"
    },
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::fluentd-logs/cluster.example.com/*",
        "arn:aws:s3:::fluentd-logs/cluster.example.com"
      ]
    }
  ]
}
```
  * Change all occurences of `fluentd-logs` with the actual name of your S3
    bucket.
  * Change all occurences of `cluster.example.com` with the actual domain name
    of your cluster.
  * Create the policy.
  

 * Create IAM user: go to Users -> Create User.
  * Username: `cluster.example.com` (use the full domain of your cluster)
  * Type of access: programmagic.
  * No group is necessary, as the policy is intended for only a single client.
  * Attach the policy with the same name: `cluster.example.com` (the one you
    created earlier for your cluster domain name.)
  * Create the user.
  * Click Copy to clipboard, the access and secret keys.
  * Open a text editor in a temporary buffer, and paste the keys.

#### Install fluentd-system

Now that you have an S3 bucket, and an IAM user with access and secret keys, you
can install fluentd:

```
make fluentd-system
```

#### Configure fluentd-system

There are several configuration templates provided in the
[src/kube-fluentd/template]() directory. You can choose the type of config you
want to install:

 * `make fluentd-system-config-blank` this will create a blank configuration,
   logging nothing.
 * `make fluentd-system-config-file-global` this will setup file logging for all
   pods in all namespaces.
 * `make fluentd-system-config-s3-backup-global` this will setup S3 backup
   globally for all pods in all namespaces.
 * `make fluentd-system-config-s3-backup` this will setup S3 backup as a plugin
   that any namespace can use in their own `FluentdConfig`.

If you choose one of the S3 options, it will interactively ask you for your
endpoint connection details:

 * The `S3 fully qualified endpoint domain` should start with `https://` and the
   domain is specific to your S3 host provider and the particular
   datacenter/region. For Wasabi, [see this
   list](https://wasabi-support.zendesk.com/hc/en-us/articles/360015106031-What-are-the-service-URLs-for-Wasabi-s-different-storage-regions-)
   (Example: For Wasabi, if the bucket region is `us-east-2`, the endpoint url
   is: `https://s3.us-east-2.wasabisys.com`. For Digital Ocean Spaces if the
   region is `nyc1` the endpoint is `https://nyc1.digitaloceanspaces.com`).
 * Enter the same bucket name you created.
 * Enter the access key you copied, note that the prefix `access-key= ` is not
   part of the key itself, and there are no spaces in the key.
 * Enter the secret key you copied, note that the prefix `secret-key= ` is not
   part of the key itself, and there are no spaces in the key.


### Harbor

[Harbor](https://goharbor.io/) is a self-hosted docker container registry and
proxy cache.

By default, most Kubernetes clusters are configured to pull container images
from [Docker Hub](https://hub.docker.com/). Docker imposes rate limits on the
images pulled from their servers. Since each node in your cluster needs to pull
the images it uses, if you have a large cluster, you will be affected by the
rate limits. To counteract this, you can deploy Harbor as a [Proxy
Cache](https://goharbor.io/docs/2.3.0/administration/configure-proxy-cache/).
You may also wish to pull private images, stored inside your local Harbor
library.

This configuration assumes you want to run a public (or LAN local) Harbor
instance, exposing ingress from outside the cluster. This allows for clients
outside your cluster to also take advantage of the proxy cache.

Choose a domain name for Harbor to use, and setup DNS to point this name to the
Traefik service external IP address.

Install Harbor, it will ask you to enter the domain name:

```
make harbor-system-init-ingress
```

You need to immediately change the admin password. Open the harbor dashboard, by
opening the domain name in your browser. Log in with the user `admin` and the
initial password `Harbor12345`. Click `admin` in the upper right corner, then
`Change Password`.

Follow the Harbor documentation to [Configure Proxy
Cache](https://goharbor.io/docs/2.3.0/administration/configure-proxy-cache/).
Make a private proxy cache project.

You can configure your cluster to use the proxy cache as its primary registry,
this setup differs for each Kubernetes platform:

 * [K3s Private Registry
   Configuration](https://rancher.com/docs/k3s/latest/en/installation/private-registry/)

In Harbor, under Administration, click `Robot Accounts`. Create a new Robot
account for each cluster node, or external client you need to give access to the
proxy cache. Give it a name (it will be prepended with `robot$` automatically).
You can choose an expiration time, and link it to your proxy_cache project.

On all of the K3s servers and workers, create the file
`/etc/rancher/k3s/registries.yaml`:

```
mirrors:
  docker.io:
    endpoint:
      - "https://harbor.example.com"
configs:
  "harbor.example.com":
    auth:
      username: robot$your-robot-username
      password: xxxxx-your-password-here
```

Restart the k3s service on all nodes:

```
systemctl restart k3s
```

To configure external docker servers to use the proxy cache, edit
`/lib/systemd/system/docker.service`, add the following argument to the
`dockerd` command found there: `--registry-mirror=https://harbor.example.com`



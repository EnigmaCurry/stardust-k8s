# Stateless Traefik and Distributed TLS

When you run a cluster, you usually want to run multiple instances of your
Ingress Controller (Traefik) for load balancing. You also need to use TLS and
use the same certificate on each instance. Traefik can do ACME for itself, but
it cannot share these certificates with other instances, so this feature cannot
be used in a distributed cluster role. It is much better to run Traefik without
any volume, and thereby you can run many identical stateless replicas. In this
conifguration, Traefik ACME is turned off. You declare your service `Ingress`
objects, and use cert-manager instead to run ACME and create `Certificate`
objects in your cluster (cert-manager *does* work in a distributed fashion).
Traefik will automatically load the certificates from the `Ingress` objects. By
using a wildcard domain (`*.example.com`) you can re-use this certificate in
Traefik `IngressRoute` objects as well. 

Install Traefik as a DaemonSet (runs a replica on every node) with no ACME
configured, using only Traefik Default (self-signed) Certificates:

```
make traefik-system-init-tls-default-daemonset
```

Install cert-manager:

```
make cert-manager-system
```

Create a `ClusterIssuer` that uses the DNS-01 ACME challenge type. This example
uses DigitalOcean DNS (to use this, your domain must be hosted on DigitalOcean
DNS, or you can modify this make target for your own DNS provider):

```
make cert-manager-issuer-production-digitalocean-dns 
```

You will be asked for the following info:

 * `ACME_ZONE` - the root DNS zone the cluster manages (eg. `example.com` or
   `k.example.com`)
 * `ACME_EMAIL` - your email address to register via ACME.
 * `DO_AUTH_TOKEN` - The DigitalOCean authentication token to use the DNS api
   and complete the DNS-01 challenge.

Deploy a service that uses `Ingress` to request a certificate and expose to the
network via Traefik:

```
make whoami-ingress-wildcard-DNS-challenge
```

You will be asked for the following info:

 * `DNS_ZONE` - the wildcard certificate domain to create (eg. `*.example.com`)
 * `WHOAMI_DOMAIN` - the domain you want to use for the whoami service. (must be
   a subdomain of the domain you chose for the issuer `ACME_ZONE`.)

Open the Traefik dashboard to check the route is created:

```
make traefik-system-dashboard
```

Test curl:

```

```

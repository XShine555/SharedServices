# Public edge

`edge/` is the only part that publishes ports 80 and 443: one nginx that
terminates TLS, and certbot that renews Let's Encrypt certificates (webroot).

```sh
docker compose --env-file .env.prod -f edge/compose.yml up -d
```

## What it serves

`edge/templates/` holds this stack's own vhosts, rendered by the nginx image
at start:

- `ZITADEL_EXTERNAL_DOMAIN`: identity (Zitadel and the login UI).
- `S3_EXTERNAL_DOMAIN`: object storage (presigned URLs straight from browsers).
- `EDGE_CERT_NAME`: the certificate (certbot `--cert-name`) that covers both;
  defaults to the identity hostname.

No domain is hard-coded. Anything else that wants a public hostname drops its
own vhost in `edge/vhosts.d/*.conf` (git-ignored) and reloads nginx:

```sh
docker exec edge-nginx nginx -s reload
```

Its upstreams are reached by container name over `infra-net`.

## Administration is allow-listed

The Zitadel console and management APIs (`/ui/console`, `/management`,
`/admin`, `/system`, `/debug`, `/auth/v1`) answer 403 unless the client is on
loopback, a private range or an address listed in
`edge/snippets/admin-allow.conf`. Add your own public IP there (or use a VPN)
before using the console in production. A vhost in `vhosts.d/` can include the
same snippet to protect its own admin routes. Sign-in endpoints are rate
limited.

## First certificate

nginx refuses to start while a certificate listed in a vhost does not exist,
so issue the first one before starting the edge, with port 80 free:

```sh
docker compose --env-file .env.prod -f edge/compose.yml run --rm -p 80:80 \
  --entrypoint certbot certbot certonly --standalone \
  --cert-name <EDGE_CERT_NAME> -d <identity host> -d <s3 host>
```

Then start the edge. Renewals use the webroot method. Prefer one certificate
per consumer vhost, so a missing certificate affects only that vhost.

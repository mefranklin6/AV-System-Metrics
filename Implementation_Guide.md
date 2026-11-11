# Implementation Guide: Analytics API and Metrics Visualizer rollout

This is the ordered checklist for releasing the optional Analytics API and
the Metrics Visualizer, and for turning them on at a site. Steps 1 to 3 are
done once by the repository maintainer. Steps 4 to 11 are done by each site's
server administrator.

Everything under `Self_Hosted/` that is merged to `main` reaches production
installs on their next update. The Analytics API is off by default
(`ENABLE_ANALYTICS_API=false`), and with it off the update only adds the
`analytics-db-disable` job, which changes nothing on an install that never
enabled the API.

## Maintainer (once)

1. **Merge to `main`.** Make sure the pull request checks passed: the
   Self-Hosted GHCR workflow (Go tests, shell tests, Compose integration test)
   and the Visualizer App workflow (`flutter analyze`, `flutter test`, web
   build).
2. **Let CI publish the `analytics-api` image.** The push to `main` runs
   `.github/workflows/self-hosted-ghcr.yml`, which publishes
   `ghcr.io/mefranklin6/av-system-metrics/analytics-api` with the tags `main`,
   `latest`, and `sha-<commit>`.
3. **Make the new package public and link it to the repository.** A new
   container package under a personal account is private, so operators'
   `docker compose pull` of `analytics-api` fails until this is done. On
   GitHub open **Your profile > Packages > analytics-api > Package
   settings**:
   - under **Danger Zone**, choose **Change visibility > Public**;
   - under **Manage Actions access** (or **Connect repository**), link it to
     `AV-System-Metrics`.

   The first run of the publish job ends with the error "cannot be pulled
   without credentials. Make the GHCR package public and link it to this
   repository" because the package is still private. After making it public,
   re-run the failed job; it must pass before you announce the release.
   Check from any machine that is not signed in to GHCR:

   ```sh
   docker logout ghcr.io
   docker pull ghcr.io/mefranklin6/av-system-metrics/analytics-api:main
   ```

   Optional: push a tag `visualizer-v<version>` to publish ready-to-run
   Windows and web builds of the Metrics Visualizer as a GitHub Release
   (`.github/workflows/visualizer-app-release.yml`).

## Site administrator

4. **Update the server** with a freshly downloaded updater, as in
   [Updating the System](Self_Hosted/README.md#updating-the-system):

   ```sh
   AVSM_REF=main
   curl -fsSL "https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted/update.sh" -o update.latest.sh
   bash update.latest.sh --ref "$AVSM_REF" && rm -f update.latest.sh
   ```

   The updater adds the new `ANALYTICS_*` settings to `.env` with the API
   turned off.
5. **Generate secrets**: one token per person or app for
   `ANALYTICS_API_TOKEN` (`openssl rand -hex 32` each) and one
   `ANALYTICS_DB_PASSWORD` (`openssl rand -hex 24`).
6. **Enable the API** in `.env` (`ENABLE_ANALYTICS_API=true`, the token list,
   the database password, and `ANALYTICS_CORS_ORIGINS` if the web Visualizer
   will be used), then apply it with the updater or
   `docker compose up -d --remove-orphans`. See
   [Enabling](Self_Hosted/README.md#enabling).
7. **Check the API on the server**: `curl -fsS http://127.0.0.1:8081/health`
   and the `/api/v1/info` request with a token, and confirm the logs show
   `analytics provisioning complete` and `passed the read-only self-check`.
8. **Set up the TLS reverse proxy and firewall.** Use the
   [reverse proxy examples](Self_Hosted/analytics_api/README.md#reverse-proxy-examples)
   (nginx, Caddy, IIS). Allow only the proxy, or trusted reporting
   workstations, to reach the API. Control processors never need it.
9. **Distribute tokens**: give each person the proxy's HTTPS address and
   their own token, through a channel suitable for passwords.
10. **Connect the app**: in the Metrics Visualizer, **Data source > Connect
    to the Analytics API**, enter the address and token, then **Test
    connection** and **Load data**. For the web build, host it as described
    in [Hosting the web build](visualizer_app/metrics_visualizer/README.md#hosting-the-web-build).
11. **Verify end to end**: the Visualizer shows the expected rooms and
    period, the proxy's access log shows the requests without the
    `Authorization` header, a wrong token gets `401` or `403`, and the API is
    not reachable from a network that should not have access.

To revoke one person's access, remove their token from `ANALYTICS_API_TOKEN`
and run `docker compose up -d --remove-orphans`. To turn the API off, see
[Disabling](Self_Hosted/README.md#disabling).

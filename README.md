# TheHireHub Status

Public status page for [thehirehub.ai](https://www.thehirehub.ai) → **https://status.thehirehub.ai**

- **Monitoring:** [Upptime](https://upptime.js.org) — GitHub Actions check every service every 5 minutes and record results in `history/`.
- **Page:** our own static site in `site/`, built by `scripts/build-data.sh` and deployed to GitHub Pages by `.github/workflows/pages.yml` every 10 minutes.
- **Incidents:** GitHub issues labelled `status` (auto-opened on downtime). Add the `maintenance` label for planned work.

Services are configured in `.upptimerc.yml`.

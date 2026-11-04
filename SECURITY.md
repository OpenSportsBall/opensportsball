# Security

OpenSportsBall runs a live service that holds families' accounts and game
footage of children, so security reports matter a lot to us. Thank you for
looking.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub:
[Report a vulnerability](https://github.com/OpenSportsBall/opensportsball/security/advisories/new)
(the repository's **Security** tab → **Report a vulnerability**). Only the
maintainers see it.

Include what you found, how to reproduce it, and what an attacker could do
with it. We'll acknowledge the report within a few days, keep you posted
while we fix it, and credit you in the advisory unless you'd rather we
didn't.

For the processing pipeline, report in the
[opensportsball-processing](https://github.com/OpenSportsBall/opensportsball-processing/security/advisories/new)
repository instead. If you're not sure which one, use this one.

## Scope

In scope: this repository's code (the phone app, website, API and AWS
infrastructure) and the service it runs at opensportsball.com, including
anything that could expose another family's account, recordings or
personal data.

Please test only against your own account and recordings, and don't run
denial-of-service tests or automated scans against the live service.
Self-host a copy (see `infra/README.md`) if you need room to experiment.

## Supported versions

Only the latest code on `main` and the currently deployed service get
security fixes.

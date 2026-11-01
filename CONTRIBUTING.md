# Contributing to Open Inference Fabric

Thank you for helping. Contributions of every size are welcome: a typo, a test on your hardware, a new guide, a patch.

## Ways to help

- **Test on your hardware.** Run the guides on NVIDIA, AMD or mixed GPU servers and report what breaks, with the
  output (remove IP addresses, host names and secrets first).
- **Review the upstream work.** Our Run:ai and KAI Scheduler pull requests and issues are listed in
  [docs/UPSTREAM.md](docs/UPSTREAM.md). Reviews and test results on those help them land.
- **Pick a task.** [TASKS.md](TASKS.md) lists the work; issues labelled `good first issue` are a good start.
- **Improve the docs.** Every step has a guide in [docs/guides](docs/guides/).

## Before you write code

1. Read [docs/RULES.md](docs/RULES.md) and [docs/SDLC.md](docs/SDLC.md).
2. Open an issue (or comment on one) saying what you plan to do. Larger changes need a short plan first, and a new
   architectural decision needs an ADR in [docs/DECISIONS.md](docs/DECISIONS.md).
3. Work on one task per pull request.

## Rules that matter most

- **No secrets, real IP addresses or host names** in any tracked file, screenshot or log. CI runs gitleaks.
- **Pin versions** in `versions.env`; no `latest` tags.
- **Every host change is reversible** by `oif uninstall`.
- **Every step has a guide**, written from a tested run, in `docs/guides/`.

## Checks

Run before you push:

```bash
tests/run.sh
```

CI runs the same checks, plus the Go builds and tests, the patch checks and gitleaks. Tasks that need real machines
also have a lab script in [tests/lab](tests/lab/); say in the pull request which ones you ran and paste their summary.

## Sign your commits (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/), as the Run:ai and KAI Scheduler projects
do. Add a sign-off line to every commit:

```bash
git commit -s -m "Short description of the change"
```

This adds `Signed-off-by: Your Name <you@example.com>`, which certifies that you wrote the change or have the right
to submit it under the project's licence (Apache-2.0).

## Pull requests

- Explain what changed, why, and how you tested it.
- Update `TASKS.md`, the guide for the step and, if a decision was made, `docs/DECISIONS.md`.
- Keep the pull request small enough to review in one sitting.

## Code of conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

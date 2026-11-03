# T-003 — Continuous Integration (guide 15)

**Status:** Done (first green run 2026-11-01)  
**Repo:** [openinferencefabric/oif](https://github.com/openinferencefabric/oif)  
**Related:** Guide 15 · `.github/workflows/ci.yml` · `tests/run.sh` · `tests/check-patches.sh` · `versions.env`

---

## 1. What T-003 delivers

| Capability | Description |
|------------|-------------|
| **Four parallel CI jobs** | On every push and pull request: static checks + unit tests, Go tests for the AMD share plugin, patch applicability against pinned upstream sources, and full-history secret scanning. |
| **Pinned tooling** | shellcheck, yamllint, gitleaks, promtool and the Go build image versions and checksums live in `versions.env`. GitHub actions are pinned by commit. |
| **Local parity** | The same checks that need no GPU or lab can be run on a workstation with `tests/run.sh` and `tests/check-patches.sh`. |
| **Template-safe YAML** | Join templates quote placeholders so they remain valid YAML as written; yamllint enforces this. |
| **Secret hygiene** | gitleaks scans the full history; the unit tests' two fake kubeadm values are allow-listed by exact match only. |

Lab tests (`tests/lab/`) remain manual because they require the hybrid-gpu-lab GPUs.

---

## 2. Workflow

```
Push / PR
    │
    ▼
.github/workflows/ci.yml  (concurrency: cancel-in-progress)
    ├─ static     → install shellcheck + yamllint from versions.env → tests/run.sh
    ├─ go         → docker run GO_BUILD_IMAGE → gofmt / vet / test on images/oif-amd-share
    ├─ patches    → tests/check-patches.sh (download pinned Run:ai + KAI source, git apply)
    └─ secrets    → checkout full history → gitleaks (rules in .gitleaks.toml)
```

| Job | Checks | Runtime (approx.) |
|-----|--------|-------------------|
| static | shellcheck (oif, installer, tests, build scripts), yamllint, Python syntax, unit tests (rules, dashboards, links, render) | ~1 min |
| go | gofmt -l, go vet, go test on oif-amd-share | ~30 s |
| patches | 8 patches apply cleanly to pinned upstream tags | ~1 min (first run; cached after) |
| secrets | gitleaks over entire git history | ~30 s |

All four jobs run in parallel. A red result blocks merge.

### Design notes

- No GPU or cluster required; suitable for every PR.
- Checksums and digests prevent supply-chain drift.
- Failed promtool download is now a hard failure in CI (previously a silent skip).
- Actions pinned by commit SHA with version comment for readability.

---

## 3. Key source files

| Path | Role |
|------|------|
| `.github/workflows/ci.yml` | Four-job workflow; tools installed from `versions.env`; actions pinned by commit |
| `tests/run.sh` | shellcheck, yamllint, Python compile, unit tests (`test_rules.sh`, `test_dashboards.sh`, `test_links.sh`, `test_render.sh`) |
| `tests/check-patches.sh` | Downloads pinned Run:ai and KAI source, verifies checksums, applies every patch with `git apply` |
| `.gitleaks.toml` | Default rules + exact-value allow-list for the two fake kubeadm strings used in unit tests |
| `.yamllint` | Template-friendly rules (line-length and document-start disabled; truthy check-keys false for workflow `on:`) |
| `versions.env` | `SHELLCHECK_*`, `YAMLLINT_VERSION`, `GITLEAKS_*`, `PROMETHEUS_*`, `GO_BUILD_IMAGE`, `RUNAI_*`, `KAI_*` |
| `docs/guides/15-ci.md` | Operator guide: what runs, how to run locally, failure diagnosis |

---

## 4. Verification

**First CI run (2026-11-01, branch `ci/t003`):** all four jobs green.

Workstation pre-checks that landed in the same change set:

- shellcheck v0.11.0: clean (now includes build scripts).
- yamllint: 37 files pass after quoting `${JOIN_CA_HASH}` in the two join templates.
- gitleaks: 5 historical findings, all the unit-test fake kubeadm token/key; those two exact values allow-listed; a planted key in the same file is still detected.
- Patch check: all 8 patches apply; a single changed context line produces a clear file:line failure.
- Dashboard and link unit tests: pass; planted non-`oif:*` series and broken links fail as expected.

---

## 5. Summary

| | |
|---|---|
| **Outcome** | Every push and PR is gated by static analysis, unit tests, patch applicability and secret scanning |
| **Mechanism** | Four parallel GitHub Actions jobs; tools and upstream sources pinned in `versions.env` |
| **Safety** | Checksums, full-history gitleaks, template-safe YAML, hard failure on missing promtool |
| **Proof** | First run green 2026-11-01; local `tests/run.sh` + `tests/check-patches.sh` parity |
| **Next** | Project 1.4 Topology & Intent (T-130+); lab tests remain owner-driven |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*

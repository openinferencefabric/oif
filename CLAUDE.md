# Instructions for AI coding assistants

Before changing anything in this repository:

1. Read `docs/SDLC.md`, `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/DESIGN.md`, `docs/RULES.md`, `TASKS.md`, `docs/DECISIONS.md` and `docs/MEMORY.md`.
2. Work on exactly one task from `TASKS.md`. Mark it `[~]` (optionally with your name, e.g. Claude). Explain the plan first; do not write code until the plan is agreed.
3. Follow `docs/RULES.md` and `docs/SDLC.md`. In particular: no secrets, real IP addresses or host names in tracked files; pin versions in `versions.env`; every host change must be reversible by `oif uninstall`.
4. Run the checks in `tests/` (and relevant lab scripts) and report: files changed, what was implemented, tests run, remaining issues.
5. After the task, write or update its install and deployment guide in `docs/guides/`, then update `TASKS.md`, `docs/MEMORY.md` and, if a decision was made, `docs/DECISIONS.md`.
6. Do not reverse an ADR silently. If the task needs a new architectural decision, propose or request an ADR first.
7. Prefer implementing code and tests; leave design-only and presentation work clearly noted for the human owner or the architecture/docs agent.

## How to write the code

Adapted from [Karpathy-inspired guidelines](https://github.com/multica-ai/andrej-karpathy-skills) (MIT). They bias
toward caution over speed; for a typo or an obvious one-liner, use judgment.

**Think before coding.** The plan of rule 2 states your assumptions. When a request can be read two ways, present
both instead of picking one silently. When a simpler approach exists, say so; push back when warranted. When
something is unclear, stop and ask.

**Simplicity first.** The minimum code that solves the task, nothing speculative:
- no features, options or settings beyond what the task asks;
- no abstraction for code used once;
- no error handling for cases that cannot happen (the cases that can happen still print the cause and the command to
  inspect it, RULES.md);
- if 200 lines could be 50, rewrite it. Would a senior engineer call it overcomplicated? Then simplify before committing.

**Surgical changes.** Every changed line traces to the task:
- do not "improve" adjacent code, comments or formatting, and do not refactor what is not broken;
- match the existing style (the stage, manifest and test helpers in `installer/lib` and `tests/unit/lib.sh`);
- remove what your own change made unused; mention unrelated dead code in the report, do not delete it.

**Goal-driven execution.** Turn the task into checks before writing code:
- a bug: first a unit test (`tests/unit/`) that reproduces it, then the fix that makes it pass;
- a feature: the tests of its acceptance criteria; a refactor: the tests pass before and after;
- the plan lists each step with how it is verified (`1. step -> verify: check`), including the lab check the owner
  runs; a task is not done until those checks pass.

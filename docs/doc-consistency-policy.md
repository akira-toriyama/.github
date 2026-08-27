# Documentation consistency policy (fleet-wide)

The rule for every repo in this account: **documentation must not drift — from
the code it describes, or from itself.** A doc that has gone stale is not
neutral; it is worse than no doc, because a reader trusts it. This policy says
where truth lives, how little to write, and why translations are not kept.

It is language-neutral, and it is the canonical statement — each repo's
`CLAUDE.md` points here rather than restating it.
[furrow](https://github.com/akira-toriyama/furrow) is the **reference
implementation**: its `README.md` is a thin skeleton over `docs/architecture.md`
(the canonical mechanism), `docs/glossary.md` (the vocabulary), and
`docs/non-goals.md` (the decision record) — each fact has one home and the rest
point to it.

## Principles

1. **Code-first.** The source of truth is the code and the CLI (`--help`,
   including a cobra command's `Short` / `Long` / `Example`). A doc is either a
   pointer to that truth or the prose the code cannot carry — a rationale, a
   decision record, an architecture map. It is never a hand-kept copy of a fact
   the binary already states, and where a copy is unavoidable it is **generated**
   and drift-guarded, not typed by hand.
2. **Reduce before you copy.** The same fact lives in exactly one place; every
   other mention is a pointer to it. Two copies drift; one cannot.
3. **Translations are not stored.** The canonical text is one language. A reader
   who wants another asks their tooling to translate on demand — a stored
   translation (a `README.ja.md`, a checked-in parallel file) is just another
   copy that rots against the original. Existing stored translations are
   **deleted**, not maintained.

   **Exception — declared review copies** (ruled 2026-08-25). A repo may, by
   explicit per-repo decision, keep a **non-canonical translation for a human
   reader**, provided its opening lines are a header declaring the terms: the
   original is canonical, the copy is updated **only on the user's
   instruction** (never in the same change as the original), and it may
   therefore **lag** — staleness is tolerated, declared, and pinned to the
   base commit of the original it renders. Invention is not tolerated: a copy
   that states a rule its original does not is a defect, however fresh it is.
   A declared copy is not a canonical surface, so the language matrix below
   does not judge it. The reference shape is the header on the `*.ja.md`
   files in `projects` (an HTML comment naming the original, the base commit,
   and the no-co-update rule).
4. **Stale docs are a cost, not a gap.** Anything that *can* drift is either
   bound by a machine guard (a drift check, a generated block) or removed. A
   check that keeps a claim honest is worth more than the claim written twice.
5. **Few, high-value docs.** Prefer a short doc a reader finishes to a long one
   they skim.

## The language matrix

The line is **public / shared → English; private / personal → the author's
language.** The test is not "is it committed?" but "is this surface public or
private?"

| Surface | Language |
|---|---|
| Everything committed to a repo — `README.md`, code comments (incl. CLI `--help`: cobra `Short` / `Long` / `Example`), `docs/*.md`, `CLAUDE.md` / `AGENTS.md`, this `.github` repo's `docs/`, **commit messages and PR descriptions** | **English** |
| A private, personal task board (furrow's task titles and bodies) | the author's language |

A reader who prefers another language reads the English docs through on-demand
translation; that translation is never committed back. furrow's task board is
private/personal, so its prose may be the author's language; a public repo's
docs and its commit messages are shared, so they are English.

## Rollout

Immediately actionable: the repos that still carry a `README.ja.md` delete it and
thin the `README.md` toward the shape above (principles 1–2). The ban is
machine-held by the fleet-distributed `repo-policy` gate, which judges **by
path first** — a tracked basename containing `.ja.` fails the PR unless the
file's first ten lines carry the declared-review-copy header (principle 3's
exception): the gate greps that head for the declaration's load-bearing words
— 和訳, 正本, 基準 — and reads nothing else of the content. Should a file whose
*canonical* language is Japanese ever be wanted, name it outside that pattern
(e.g. `docs/design-jp/…`) — the gate reads names and a declared head, never the
body, on purpose. Deeper code-first
cleanup is **opportunistic** — done as each repo is touched, not as a separate
campaign — so a repo is never blocked on a full rewrite to drop a stale
translation. Each repo's `CLAUDE.md` gains a one-line pointer to this policy as
it is touched.

This is a per-repo, self-contained change (a repo's own docs affect no other
repo), so it is ordinary work under
[`fleet-change-policy.md`](fleet-change-policy.md) — ship it normally, one PR per
repo.

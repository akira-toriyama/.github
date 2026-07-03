---
# Fixture consumed by the hub's self-test (smoke-design-md-lint). design-md-lint.yml
# is pointed at this file via `paths:` and runs `@google/design.md lint`, so the smoke
# proves the reusable actually runs the linter (YAML token parse + `{...}` ref
# resolution), not just that the job started. Kept lint-clean (0 errors, 0 warnings)
# on purpose; the gate only fails on `error` findings (broken-ref). Frontmatter must
# stay the first line — a leading blank/comment makes the parser miss the tokens.
tokens:
  color:
    primary: "#0b57d0"
    on-primary: "#ffffff"
---

# Design

## Overview

Self-test fixture for the reusable design.md lint.

## Colors

- Primary: {tokens.color.primary}
- On primary: {tokens.color.on-primary}

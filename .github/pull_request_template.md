## What this changes

<!-- One paragraph. What was wrong, or what is now possible. -->

## Why this way

<!-- The design decision, and the alternative you rejected. If the shape of the
     change is not obvious, this is the section a reviewer reads first. -->

## How it was verified

<!-- The commands you ran and what they said. `--self-test` at minimum; say which
     of the new checks fail without your change, because that is what makes them
     worth keeping. -->

```
--self-test
```

## Checklist

- [ ] `swift build` is clean, with no new warnings
- [ ] `--self-test` passes, and the new checks fail without this change
- [ ] No new entries in `Package.swift` — Bud depends on the system SDK only
- [ ] Comments explain why, and any comment the change made untrue is gone
- [ ] If this touches something the README or SECURITY.md describes, they are updated

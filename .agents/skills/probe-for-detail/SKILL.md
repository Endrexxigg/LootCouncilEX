---
name: probe-for-detail
description: >
  Turn loosely-described feature requests into documented todo.md entries plus an
  exhaustive numbered list of clarifying questions — ask instead of assume. Use
  when the user describes one or more new features/ideas to capture and
  interrogate before any implementation (a bulleted feature dump, "add these to
  the todo and ask me questions", or an explicit /probe-for-detail).
---

# Probe for detail

The user describes features loosely **on purpose** — filling the gaps is your job,
but with *questions*, not assumptions. Standing instruction for this workflow:
**anything you would normally assume or default, ask instead.** A wrong assumption
costs rework; a question costs one line. Do not start implementing.

## Workflow

1. **Split the request** into discrete features. Keep the user's own wording as
   the anchor for each — don't paraphrase away details ("blend in with the ui but
   still be visible" carries intent a summary would lose).
2. **Ground every feature in the code it touches** before writing a single
   question. Read (or send Explore agents through) the files involved: current
   sizes and anchors, existing handlers, what data capture actually stores,
   existing settings keys. A question that cites reality ("the window is fixed at
   W×H today — is that the minimum?") gets a faster, surer answer than a generic
   one — and many would-be questions dissolve because the code already answers
   them.
3. **Document each feature in `todo.md`** (repo root; already .pkgmeta-ignored so
   it never ships in the CurseForge zip). Per feature: a status line
   (`awaiting answers` → `specced` → `in progress` → `shipped vX.Y.Z`), the ask
   distilled faithfully from the user's words, grounding notes (what the code
   says today), then the open questions. Questions live in the todo **and** in
   chat with identical numbering, so answers can be recorded later without
   re-deriving anything.
4. **Produce the question list in chat**, grouped per feature, and tell the user
   how to answer (by number, terse, out of order is fine).
5. **Stop.** No implementation, no scaffolding. Commit the todo/skill changes per
   repo git rules and say you're waiting on answers.

## Question craft

- **Number with a per-feature letter prefix** (`W1…`, `S1…`) so answers can be
  terse and out of order ("S3 prefix-only, T5 no, rest defaults").
- **Two tiers per feature**, both genuinely asked:
  - **Decisions** — real forks in the design. Open questions, or 2–4 concrete
    options; give your recommendation and the *why* in a clause when you have
    one. A skipped Decision question is **not** consent — re-ask before building
    that part.
  - **Defaults — veto if wrong** — the small stuff you'd normally just pick
    (capitalization, key behaviors, hover delays, empty states). One line each,
    phrased as the default you'll apply. Silence = consent **for this tier
    only**.
- **Concrete beats abstract.** "Esc: clear the box, or just close the
  suggestions?" — not "how should cancellation work?".
- **Coverage checklist** — walk each feature through these dimensions and ask
  about the ones that apply:
  - entry/trigger UX; idle / hover / active / empty visual states
  - keyboard and mouse paths, including exit / cancel / reset
  - empty, missing, malformed data (old-schema records, partial captures)
  - persistence: what's remembered, at what scope (per-char vs account-wide)
  - interactions with existing features (scope, filters, other panes, and the
    other requested features)
  - performance at realistic data sizes
  - edge cases the data model implies (realm suffixes, name collisions, pets)
  - what is explicitly **out of scope** for v1
- **End with a cross-cutting section**: build order / priority, gating, and
  anything shared between features.
- Don't pad. Every question must either change what gets built or lock a
  default. If the code already answers it, it is not a question — it's a
  grounding note.

## After the answers

1. Record each answer in `todo.md` under its feature: convert answered questions
   into a `Decisions:` list (keep the numbers); leave unanswered Decision
   questions flagged open.
2. If an answer contradicts the code, another answer, or a known constraint,
   surface the conflict — don't silently pick a side.
3. Only then plan/implement, feature by feature, under normal repo rules
   (luacheck + tests, version bump, one logical change per commit).

# Issue tracker: Tracked local Markdown

Issues and specs for this repository live as version-controlled Markdown under
`plans/`. Committed artifacts travel with Git, so they remain available across
worktrees and portable between GitHub and Forgejo.

Existing standalone files directly under `plans/` remain valid. The conventions
below apply to new feature work created or consumed by engineering skills.

## Conventions

- One feature per directory: `plans/<feature-slug>/`
- The spec is `plans/<feature-slug>/spec.md`.
- Implementation issues are one file per ticket at
  `plans/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`. Do not combine
  all tickets into one file.
- Triage state is recorded as a `Status:` line near the top of each issue file.
  See `triage-labels.md` for the role strings.
- Comments and conversation history append to the bottom of the issue file under
  a `## Comments` heading.
- Include issue and spec files in the feature branch's commits so other worktrees
  and Git forges receive them.

## When a skill says "publish to the issue tracker"

Create the appropriate spec or issue file under `plans/<feature-slug>/`, creating
the feature and `issues/` directories when needed.

## When a skill says "fetch the relevant ticket"

Read the referenced file under `plans/<feature-slug>/issues/`. The user will
normally provide its path or ticket number.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `plans/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `plans/<effort>/issues/NN-<slug>.md`, numbered from `01`, with
  the question in the body. A `Type:` line records the ticket type
  (`research`/`prototype`/`grilling`/`task`); a `Status:` line records
  `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked
  when every file it lists is `resolved`.
- **Frontier**: scan `plans/<effort>/issues/` for files that are open, unblocked,
  and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set
  `Status: resolved`, then append a context pointer (gist + link) to the map's
  Decisions-so-far in `map.md`.

# Governance

Apex Control is a small project with a simple structure. This page says who
decides what, how a change gets in, and what happens if the maintainer goes away
(the questions [PRD-37](docs/prd/PRD-37-project-docs-compatibility-community.md)
asks a project to answer before anyone depends on it).

## Roles

- **Maintainer**: [@Rikearon](https://github.com/Rikearon). Reviews and merges
  pull requests, cuts releases, and has the final say on direction. Today there
  is one maintainer.
- **Contributors**: anyone who opens an issue, a discussion or a pull request.
  You keep the copyright to your work and license it as described in
  [CONTRIBUTING.md](CONTRIBUTING.md).

Sustained, careful contributors may be invited to become maintainers. There is
no application process; the invitation comes from an existing maintainer, and
being one means reviewing other people's changes to code that writes to real
hardware.

## How decisions are made

- **Everyday changes** are decided in the pull request: a maintainer reviews, and
  merges when it is correct, verified where it touches hardware, and documented.
- **Larger changes** start as a [PRD](docs/prd/) or a discussion so the reasoning
  is written down before the code. The PRD's **Status** line records where the
  feature stands.
- **Protocol claims are decided by evidence, not opinion.** A claim goes into
  [docs/PROTOCOL.md](docs/PROTOCOL.md) when it has been shown to hold on
  hardware, and says how sure it is.
- **Disagreements** are settled by discussion first. If that does not converge,
  the maintainer decides and writes down why.

The project follows its [Code of Conduct](CODE_OF_CONDUCT.md). Conduct reports go
through the private channel described there; a report about a maintainer goes to
GitHub's abuse report form instead, so that it does not reach the person it concerns.

## Releases

Releases are made by a maintainer by pushing a version tag; CI builds the
artefacts from that tag. The steps are in
[docs/MAINTAINING.md](docs/MAINTAINING.md). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), and every release has
an entry in [CHANGELOG.md](CHANGELOG.md).

## Continuity

What someone depending on this project should know:

- **The code and the documentation are freely licensed** (MIT, and CC BY 4.0 for
  `docs/PROTOCOL.md` and the Code of Conduct). Anyone can fork them, and nothing
  here depends on a server, an account or a key that only the maintainer holds,
  other than the GitHub repository itself. Contributors keep the copyright to
  their own work; there is no copyright assignment and no contributor licence
  agreement.
- **There is currently no Developer ID certificate, update channel or Homebrew
  tap.** Releases are ad-hoc signed and not notarized. Creating any of those
  would put a secret in someone's hands, so the question of who holds it, and what
  happens if they step away, has to be answered here *before* it is created
  ([PRD-32](docs/prd/PRD-32-distribution-signing-updates.md) raises the same
  point).
- **If the maintainer becomes unavailable**, the project can be continued by a
  fork. Adding co-maintainers reduces the risk; if you would like to be one, start
  by contributing.

This page describes how the project works today. Changes to it go through a pull
request like any other.

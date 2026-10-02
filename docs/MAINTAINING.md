# Maintaining

For the maintainer: how the repository is published and configured, how to cut a
release, and what is deliberately not done yet. Contributors do not need this page.

## Repository settings

These live on GitHub, not in git. Apply them straight after the first push, in one
sitting, in this order. Each command is real `gh` syntax, but they change your
repository, so read them before running them.

```bash
REPO=Rikearon/apex-control
```

### 1. Reporting and outside contributors

These two commands turn on private vulnerability reporting and make GitHub ask you to
approve the workflow runs of every outside contributor. `SECURITY.md` and
`CODE_OF_CONDUCT.md` send reports to the reporting form, which does not exist until
the repository is public; reporters need a GitHub account. The default fork policy,
and the "new to GitHub" one, stop asking once someone has had a change merged, and a
typo fix is enough.

```bash
gh api -X PUT repos/$REPO/private-vulnerability-reporting
gh api -X PUT repos/$REPO/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
```

### 2. The repository itself

In order, the commands below set:

- **Topics.** (The description was set when the repository was created.)
- **Discussions on, wiki off.** Discussions is where `SUPPORT.md` and the issue forms
  send questions; the docs live in the repository.
- **Squash merges only, titled after the pull request.** Squash merges keep the
  history readable. `gh repo edit` cannot set the squash commit title, and GitHub's
  default is the commit's own title for a one-commit pull request, so the API call makes
  it always the pull request title (Conventional Commits).
- **Only actions pinned to a full commit SHA.** Every action in the workflows already
  is, and `make check` enforces it; this makes GitHub enforce it too.
- **Immutable releases.** Once published, a release's assets and tag cannot be changed
  or deleted. See "Releasing" for what that means when a release goes wrong.
- **Dependabot alerts.**

```bash
gh repo edit $REPO \
  --add-topic macos --add-topic swift --add-topic swiftui --add-topic steelseries \
  --add-topic apex-pro --add-topic keyboard --add-topic hid --add-topic rgb \
  --add-topic rapid-trigger --add-topic oled
gh repo edit $REPO --enable-discussions --enable-wiki=false
gh repo edit $REPO --enable-squash-merge --enable-merge-commit=false \
  --enable-rebase-merge=false --delete-branch-on-merge
gh api -X PATCH repos/$REPO -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=PR_BODY
gh api -X PUT repos/$REPO/actions/permissions -F enabled=true -f allowed_actions=all \
  -F sha_pinning_required=true
gh api -X PUT repos/$REPO/immutable-releases
gh api -X PUT repos/$REPO/vulnerability-alerts
```

The two issue forms for hardware reports use labels GitHub does not create by default:

```bash
gh label create hardware --repo $REPO --color 5319e7 --description "A keyboard model, firmware or hardware report"
gh label create protocol --repo $REPO --color 0e8a16 --description "The HID protocol and docs/PROTOCOL.md"
```

Keep the token every workflow run receives read-only by default, and do not let
workflows create or approve pull requests (each workflow also declares its own
permissions):

```bash
gh api -X PUT repos/$REPO/actions/permissions/workflow -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```

### 3. Security scanning

Code scanning uses GitHub's default setup, so there is no workflow file; it analyses
the Swift code and the workflows themselves. Secret scanning gets push protection, and
Dependabot opens pull requests for security advisories that affect the pinned actions.

```bash
gh api -X PATCH repos/$REPO/code-scanning/default-setup -f state=configured \
  -f query_suite=default
gh api -X PATCH repos/$REPO --input - <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                           "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
gh api -X PUT repos/$REPO/automated-security-fixes
```

### 4. Watch the first CI run

The push to `master` started CI, which runs the workflows, the Xcode 16.0 build and
the Intel build for real for the first time. Watch it (`gh run watch`, or the Actions
tab) and fix anything it finds in a pull request. Pushing a branch on its own starts nothing, because CI runs on pushes to
`master` and on pull requests: to try a change to the workflows, open a draft pull
request from it.

### 5. Protect `master` and the release path

A required status check must have run in the repository in the last seven days, so
wait for the run from step 4 to finish. Then create the ruleset:

```bash
gh api -X POST repos/$REPO/rulesets --input - <<'JSON'
{
  "name": "master",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false, "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [{ "context": "CI", "integration_id": 15368 }] } }
  ]
}
JSON
```

It blocks force pushes and deletion, requires a pull request, and requires the status
check named **CI** (the one job that summarises the matrix, so it keeps working as the
matrix changes) from GitHub Actions (`integration_id` 15368), so no other app can
satisfy it. The bypass actor is the repository admin role: you, so you can still push
directly when you need to. Turn on "Require review from Code Owners" only once there
is a second maintainer; with one, it would block your own pull requests.

Finally the `release` environment, which the publish job of the release workflow
waits on. A credential that can only push a tag (a deploy key, a fine-grained token, a
future collaborator) then cannot publish a release by itself: a reviewer has to approve
the run, and you get a prompt to do it. It does not help against a stolen `repo`-scoped
token or session of the reviewer, which can approve through the API too, so keep such
tokens (the one `gh auth login` stores is one) off machines you do not control.

```bash
gh api -X PUT repos/$REPO/environments/release --input - <<JSON
{"prevent_self_review": false,
 "reviewers": [{"type": "User", "id": $(gh api user --jq .id)}],
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST repos/$REPO/environments/release/deployment-branch-policies \
  -f name='v*' -f type=tag
```

`prevent_self_review` is off because you are the only reviewer. Turn it on when there
is a second maintainer.

### 6. Check that the settings took

```bash
gh api repos/$REPO/private-vulnerability-reporting --jq .enabled
gh api repos/$REPO/actions/permissions/fork-pr-contributor-approval --jq .approval_policy
gh api repos/$REPO/actions/permissions --jq '[.allowed_actions, .sha_pinning_required]'
gh api repos/$REPO/immutable-releases --jq .enabled
gh api repos/$REPO/code-scanning/default-setup --jq .state
gh api repos/$REPO/rulesets --jq '.[].name'
gh api repos/$REPO/environments/release --jq '[.protection_rules[].type]'
gh api repos/$REPO/actions/permissions/workflow --jq '[.default_workflow_permissions, .can_approve_pull_request_reviews]'
gh api repos/$REPO/automated-security-fixes --jq .enabled
gh api repos/$REPO/codeowners/errors --jq '.errors | length'
gh api repos/$REPO/community/profile --jq .health_percentage
```

They should print, in order: `true`; `all_external_contributors`; `["all",true]`;
`true`; `configured` (it can take a minute); `master`; a list that includes
`required_reviewers` and `branch_policy`; `["read",false]`; `true`; `0` (no CODEOWNERS errors);
and `100` (GitHub found the Code of Conduct, contributing guide, licence, pull request
template, README and issue forms; its `issue_template` field stays empty for issue forms,
which is why the check reads the percentage instead).

Then open the repository in a private browser window, as a visitor: the README
renders, the **Security** tab offers **Report a vulnerability**, Discussions is on, and
the links resolve (the download link works only after the first release).

## Releasing

A release is one tag. CI builds it from the tag; nothing is built on a laptop.

1. **Choose the version** ([Semantic Versioning](https://semver.org/spec/v2.0.0.html);
   while it is 0.x, a minor bump may change behaviour). The first release is 0.1.0.
2. **Set it** in `Sources/ApexKit/Version.swift` (`ApexVersion.current`). This is the
   only place the version lives; `Scripts/version.sh` reads it for everything else.
   (For 0.1.0 it is already set.)
3. **Finish the changelog.** In `CHANGELOG.md`, rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD`, add a fresh empty `## [Unreleased]` above it, and
   update the links at the bottom: `[Unreleased]` compares `vX.Y.Z...HEAD`, and add
   `[X.Y.Z]` pointing at the tag (the first release links to
   `releases/tag/vX.Y.Z`). For 0.1.0, also change the opening sentence, "The first
   public release, planned as 0.1.0", to "The first public release", because it
   becomes the first line of the release notes. A pre-release tag such as
   `v0.2.0-rc.1` needs its own heading, `## [0.2.0-rc.1] - YYYY-MM-DD`: the notes are
   looked up by the tag's version, literally.
4. **Check locally.** `make check test`, and if you like `make package` to build
   exactly what CI will build. `Scripts/release-notes.sh X.Y.Z` prints the release
   notes; it fails if the changelog has no entry. If the interface has changed since
   the pictures in `docs/images/` were taken, retake them first
   ([Screenshots](DEVELOPMENT.md#screenshots)) so that they show the words the app
   uses today.
5. **Merge to `master`**, then tag that commit and push the tag:

   ```bash
   git switch master && git pull
   git tag -a vX.Y.Z -m "Apex Control X.Y.Z"
   git push origin vX.Y.Z
   ```

6. **Watch the workflow** ([Release](../.github/workflows/release.yml)), which starts
   on any tag matching `v[0-9]+.[0-9]+.[0-9]+*` (so `v0.1.0` and `v0.2.0-rc.1`
   do, and a tag called `test` does not). It refuses to
   run if the tagged commit is not on `master`, if the tag does not match
   `Version.swift`, or if the changelog has no entry. It then tests, builds the
   universal app, the CLI and the disk image, checksums them, and waits for you to
   approve the `release` environment (the run's page, "Review deployments"). Once you
   do, it attests their provenance (public repositories only) and creates the GitHub
   release with the notes. The refusals guard against mistakes, not against someone
   who can push a tag: a tag push runs the workflow file from the tagged commit,
   whatever it says. The approval and the environment's tag rule make publishing a
   deliberate second step; they are no defence against whoever holds your reviewer
   credentials.
7. **Verify the release.** Download the disk image in a browser on a Mac that has
   never seen it, and check that it opens the way the release notes say (Gatekeeper
   will ask you to approve it once). Then:

   ```bash
   shasum -a 256 --ignore-missing -c SHA256SUMS
   gh attestation verify ApexControl-X.Y.Z.dmg --repo Rikearon/apex-control \
     --signer-workflow Rikearon/apex-control/.github/workflows/release.yml
   ```

   `gh attestation` needs GitHub CLI 2.97 or later (`gh --version`; upgrade it if it is
   older: before 2.97, `--signer-workflow` could be fooled by look-alike names, advisory
   GHSA-mm27-mwq9-fr5g) and a signed-in `gh` (`gh auth login`). Without a login, download
   `ApexControl-X.Y.Z.sigstore.json` from the release too and add
   `--bundle ApexControl-X.Y.Z.sigstore.json`.

8. **Start the next cycle.** Bump `Version.swift` to the next pre-release
   (for example `0.2.0-dev`) so that builds from `master` are distinguishable from the
   release in bug reports.

A tag with a suffix (`v0.2.0-rc.1`) is published as a pre-release. If the workflow
fails before it creates the release, delete the tag (`git push --delete origin
vX.Y.Z`, then `git tag -d vX.Y.Z`), fix the problem, and tag again. Once the release
is published it is immutable: its assets and tag cannot be changed or deleted while
the release exists, and even after you delete the release the tag name can never be
used again. If a published release is wrong, publish a patch release instead.

Every release attestation records the repository's name at signing time, so do not
rename the repository once there are releases.

### Third-party actions

Every action in `.github/workflows/` is pinned to a full commit SHA with the version
in a trailing comment, and `make check` fails on anything that is not. Dependabot
opens a weekly pull request when a new version exists. To bump one by hand:

```bash
gh api repos/actions/checkout/git/ref/tags/<tag> --jq '.object.sha'
```

That works for a lightweight tag. An annotated tag returns an object of type `tag`:
fetch it with `git/tags/<sha>` and use its `.object.sha`.

GitHub enforces the pinning too (the `sha_pinning_required` setting above), so an
unpinned action would not run at all. The `checks` job also downloads `actionlint` and
`zizmor` by version and SHA-256. Dependabot cannot update those two, so bump them by
hand: `gh api repos/rhysd/actionlint/releases/latest` and
`gh api repos/zizmorcore/zizmor/releases/latest` list each asset with its `digest`,
which is the SHA-256 to copy for the linux x86_64 tarball.

## Not done yet

These are deliberate, and each is tracked in a PRD:

- **Notarization and a Developer ID** ([PRD-32](prd/PRD-32-distribution-signing-updates.md)).
  Releases are ad-hoc signed, so macOS asks users to approve the app once, and
  "Open at login" may need the app to be properly signed. Notarizing needs a paid
  Apple Developer Program membership, a Developer ID Application certificate,
  `codesign --options runtime --timestamp`, then `xcrun notarytool submit --wait` and
  `xcrun stapler staple`, with the certificate and an App Store Connect key held as
  encrypted CI secrets. Decide who holds them, and what happens if that person steps
  away, in [GOVERNANCE.md](../GOVERNANCE.md) *before* creating them. The hardened
  runtime needs no entitlement for the keyboard: a hardened-runtime build signed with
  a local certificate opens the keyboard's HID interface fine, but that does not
  prove a notarized one will, so check it on a real notarized build.
- **A Homebrew cask.** A cask lives in a tap, and the official cask repository
  expects a notarized app. Add one when releases are notarized, and update it from
  the release workflow, or not at all: a stale cask is worse than none.
- **Automatic updates.** Deliberately not built: it would give the project an
  update authority to protect, and the app promises no network access.
- **Generated compatibility matrix** ([PRD-30](prd/PRD-30-protocol-conformance-probe.md)).
  `docs/COMPATIBILITY.md` is maintained by hand until then.

## Everyday chores

- **Conduct reports** arrive as draft security advisories titled `[Conduct]`. Handle
  them privately, and never publish them.
- **Triage** new issues: label them, ask for `apexctl --version` and `apexctl info`
  output when a bug report lacks it, and move questions to Discussions.
- **Good first issues.** [KNOWN-ISSUES.md](KNOWN-ISSUES.md) is a ready-made list; turn
  items into issues labelled `good first issue` and delete them from the file when
  they are fixed.
- **Reviewing hardware-facing changes.** Ask what was run and on which firmware, and
  check that any flash write reads first, patches, and verifies by read-back (the
  documented exceptions are the app's save at quit and its OLED image save).
- **Runner images and Xcode.** The matrix pins Xcode 16.0, 16.4 and 26.6 by path, so a
  new Xcode is not tried until you add it. The weekly run notices changes to those
  images, and to the default Xcode on the `xcode-27` preview image. That job is
  allowed to fail so a preview cannot block a merge; once Xcode 27 is stable, promote
  it into the required matrix in `.github/workflows/ci.yml`. GitHub supports at most
  two generally available images at a time and starts deprecating the oldest when a
  new one reaches general availability, and Intel runners are being phased out
  (`macos-15-intel` and `macos-26-intel` exist today; neither is promised for long).
  When the images they run on go, the Xcode 16.0 leg and the Intel leg have to move
  or be dropped.
- **Scheduled runs stop.** In a public repository GitHub disables scheduled workflows
  after 60 days without repository activity. If the weekly run has gone quiet,
  re-enable it on the Actions tab.
- **Approving CI for pull requests from forks.** With the policy set above, every run on
  a fork's pull request waits for you ("Approve and run workflows"), after each push.
  Look at the diff first, above all `.github/`, `Scripts/`, the `Makefile` and
  `Package.swift`: approving runs the change on GitHub's runners, with a read-only token
  and no secrets, but with your account's runner minutes.
- **Reviewing changes to CI itself.** A pull request's checks are produced by the pull
  request's own copy of `.github/`, `Scripts/` and the `Makefile`, so a green `CI` says
  nothing about a change to those files: the change can edit the check that judges
  it. Read those diffs line by line, and run the change yourself, before you merge it.

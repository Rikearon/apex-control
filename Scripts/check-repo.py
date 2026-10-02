#!/usr/bin/env python3
"""Repository checks that a compiler cannot make.

    ./Scripts/check-repo.py          (or: make check)

What is verified, and why each check exists:

  hygiene    Line endings, tabs, trailing whitespace, final newline, and the
             invisible Unicode characters (non-breaking hyphen, NBSP, zero-width
             space, BOM) that look identical to their plain versions but break
             `grep`, links and copy-paste.
  links      Every relative Markdown link, image and HTML href/src points at a
             file that exists, every `#anchor` at a heading that exists, and
             every `[text][label]` reference at a defined label.
  prd        Every `PRD-NN` mentioned anywhere resolves to docs/prd/PRD-NN-*.md,
             and every PRD is listed in the index of docs/FEATURE-GAP-ANALYSIS.md.
  docs       Every page in docs/ is reachable from docs/README.md.
  workflows  Every GitHub Action is pinned to a full commit SHA, and every
             workflow declares its permissions.
  scripts    Scripts are executable and start with a shebang.
  community  The community-health files GitHub looks for are present.
  version    Scripts/version.sh yields a valid version, and CHANGELOG.md has an
             [Unreleased] section.
  paste      Shell blocks in the documentation carry no `# comment`, on its own
             line or after a command: zsh, the default macOS shell, does not
             treat a pasted `#` as a comment, so it passes a trailing one to the
             command as arguments, and quotes, backticks and parentheses in a
             comment line are still executed or swallow the lines that follow.
  slug       Every mention of one of the owner's repositories (`Rikearon/...`)
             names the same one, so a rename cannot leave half the docs behind.
  secrets    No private keys or obvious tokens, no personal home directories,
             and nothing large enough to be an accidental binary.
  network    No networking API in Sources/: the app promises to make no network
             connections (docs/PRIVACY.md), so adding one must be a deliberate,
             documented decision rather than a side effect.
  vendor     Only known source, document and image file types (so no captures,
             dumps or other files that can carry a serial number or that are not
             ours to publish), no tool-local settings, no armoured key,
             certificate or signature blocks, and nothing that matches the
             maintainer's private list of words that must never be published
             (see LOCAL_DENYLIST below; the list is not part of the repository).
             The project does not redistribute anything from SteelSeries'
             software (CONTRIBUTING.md).

Standard library only and Python 3.9+, so it runs on a bare macOS or CI image.
Prints every problem as `path:line: message` and exits 1 if there were any.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent

MAX_FILE_BYTES = 1_500_000

BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".icns", ".dmg", ".zip", ".pdf"}

# Verbatim third-party text (licence legal code): never rewrite or lint it.
VERBATIM_PREFIXES = ("LICENSES/",)

# Characters that render like ordinary ones but are not.
INVISIBLE = {
    chr(0x2011): "non-breaking hyphen (write a plain '-')",
    chr(0x00A0): "no-break space (write a plain space)",
    chr(0x200B): "zero-width space",
    chr(0x2060): "word joiner",
    chr(0xFEFF): "byte-order mark",
}

REQUIRED_FILES = [
    "README.md",
    "LICENSE",
    "LICENSES/CC-BY-4.0.txt",
    "THIRD-PARTY-NOTICES.md",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    "SECURITY.md",
    "SUPPORT.md",
    "GOVERNANCE.md",
    "CHANGELOG.md",
    "Makefile",
    ".editorconfig",
    ".gitignore",
    ".gitattributes",
    ".github/CODEOWNERS",
    ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/dependabot.yml",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    "docs/README.md",
]

problems: list[str] = []


def problem(path: Path | str, line: int | None, message: str) -> None:
    where = str(path) if line is None else f"{path}:{line}"
    problems.append(f"{where}: {message}")


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

def list_files() -> list[Path]:
    """Tracked files plus untracked-but-not-ignored ones, so work in progress
    is checked too. Falls back to walking the tree outside a git checkout."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=ROOT, check=True, capture_output=True,
        ).stdout
        names = [n for n in out.decode("utf-8").split("\0") if n]
    except (OSError, subprocess.CalledProcessError):
        skip = {".git", ".build", "build", "dist", ".swiftpm"}
        names = [
            str(p.relative_to(ROOT))
            for p in ROOT.rglob("*")
            if p.is_file() and not (set(p.relative_to(ROOT).parts) & skip)
        ]
    # A tracked file deleted from the working tree still appears in the index.
    return sorted({Path(n) for n in names if (ROOT / n).is_file()})


_text_cache: dict[Path, str | None] = {}


def read_text(rel: Path) -> str | None:
    """The file's text, or None for binary files."""
    if rel in _text_cache:
        return _text_cache[rel]
    text: str | None = None
    if rel.suffix.lower() not in BINARY_SUFFIXES:
        data = (ROOT / rel).read_bytes()
        if b"\0" not in data:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                problem(rel, None, "not valid UTF-8")
    _text_cache[rel] = text
    return text


def is_verbatim(rel: Path) -> bool:
    return rel.as_posix().startswith(VERBATIM_PREFIXES)


# ---------------------------------------------------------------------------
# hygiene
# ---------------------------------------------------------------------------

def check_hygiene(files: list[Path]) -> None:
    for rel in files:
        text = read_text(rel)
        if text is None or is_verbatim(rel):
            continue

        if "\r" in text:
            problem(rel, None, "contains CR characters (the repository is LF-only)")
        if text and not text.endswith("\n"):
            problem(rel, None, "no newline at end of file")
        elif text.endswith("\n\n"):
            problem(rel, None, "more than one newline at end of file")

        allow_tabs = rel.name == "Makefile"
        for number, line in enumerate(text.split("\n"), start=1):
            if line != line.rstrip(" \t"):
                problem(rel, number, "trailing whitespace")
            if "\t" in line and not allow_tabs:
                problem(rel, number, "tab character (use spaces)")
            for char, why in INVISIBLE.items():
                column = line.find(char)
                if column >= 0:
                    context = line[max(0, column - 12):column].replace("\t", " ") \
                        + "<<U+%04X>>" % ord(char) + line[column + 1:column + 13]
                    problem(rel, number, f"U+{ord(char):04X} {why}, at column {column + 1}: ...{context}...")


# ---------------------------------------------------------------------------
# links
# ---------------------------------------------------------------------------

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
INLINE_CODE = re.compile(r"`[^`\n]*`")
INLINE_TARGET = re.compile(r"\]\(\s*<?([^)\s>]*)")
REF_USE = re.compile(r"\]\[([^\]]+)\]")
REF_DEF = re.compile(r"^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s|$)")
HTML_TARGET = re.compile(
    r"""(?<=\s)(?:href|srcset|src|poster)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""", re.IGNORECASE)
HTML_ANCHOR = re.compile(r"""(?:id|name)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def slugify(heading: str) -> str:
    """GitHub's heading anchor: lower-case, punctuation dropped, spaces to '-'."""
    t = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", heading)   # image -> alt text
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)          # link -> text
    t = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", t)         # reference link -> text
    t = re.sub(r"<[^>]+>", "", t)                            # inline HTML
    t = t.replace("`", "").replace("*", "")
    t = re.sub(r"[^\w\- ]", "", t.strip().lower())
    return t.replace(" ", "-")


def markdown_lines(text: str):
    """Yield (line number, line) for prose lines only: fenced code is skipped."""
    fence: tuple[str, int] | None = None
    for number, line in enumerate(text.split("\n"), start=1):
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence = (m.group(1)[0], len(m.group(1)))
                continue
            yield number, line
        elif m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1]:
            fence = None


_anchor_cache: dict[Path, set[str]] = {}


def anchors_of(rel: Path) -> set[str]:
    if rel in _anchor_cache:
        return _anchor_cache[rel]
    anchors: set[str] = set()
    seen: dict[str, int] = {}
    for _, line in markdown_lines(read_text(rel) or ""):
        m = HEADING.match(line)
        if m:
            base = slugify(m.group(2))
            n = seen.get(base, 0)
            seen[base] = n + 1
            anchors.add(base if n == 0 else f"{base}-{n}")
        anchors.update(HTML_ANCHOR.findall(line))
    _anchor_cache[rel] = anchors
    return anchors


def check_target(source: Path, number: int, target: str, known: set[Path]) -> None:
    if not target or SCHEME.match(target) or target.startswith("//"):
        return
    path_part, _, fragment = target.partition("#")
    path_part = path_part.split("?", 1)[0]

    if path_part:
        raw = unquote(path_part)
        dest = ROOT / raw.lstrip("/") if raw.startswith("/") else (ROOT / source.parent / raw)
        dest = Path(os.path.normpath(dest))
        try:
            dest_rel = dest.relative_to(ROOT)
        except ValueError:
            problem(source, number, f"link leaves the repository: {target}")
            return
        # Membership in the list of checked-in files, not `dest.exists()`: the
        # filesystem is case-insensitive on a default macOS volume and also
        # contains git-ignored files, so a link that resolves here can still be
        # a 404 on GitHub (and fail this check on the Linux CI runner).
        if dest_rel not in known:
            problem(source, number, f"broken link: {target}")
            return
    else:
        dest_rel = source

    if fragment and dest_rel.suffix == ".md" and (ROOT / dest_rel).is_file():
        if unquote(fragment) not in anchors_of(dest_rel):
            problem(source, number, f"broken anchor: {target}")


def check_links(files: list[Path]) -> None:
    # Every file and every directory that contains one (`Path(".")` included).
    known = set(files) | {parent for f in files for parent in f.parents}
    for rel in files:
        if rel.suffix != ".md" or is_verbatim(rel):
            continue
        text = read_text(rel)
        if text is None:
            continue

        lines = list(markdown_lines(text))
        defined = {
            m.group(1).strip().lower()
            for _, line in lines
            if (m := REF_DEF.match(line))
        }

        for number, line in lines:
            definition = REF_DEF.match(line)
            if definition:
                check_target(rel, number, definition.group(2), known)
                continue
            prose = INLINE_CODE.sub("", line)
            for m in INLINE_TARGET.finditer(prose):
                check_target(rel, number, m.group(1), known)
            for m in HTML_TARGET.finditer(prose):
                value = next(g for g in m.groups() if g is not None)
                # `srcset` is a comma-separated list of "url [descriptor]".
                urls = [c.split()[0] for c in value.split(",") if c.split()] \
                    if m.group(0).lower().startswith("srcset") else [value]
                for url in urls:
                    check_target(rel, number, url, known)
            for m in REF_USE.finditer(prose):
                if m.group(1).strip().lower() not in defined:
                    problem(rel, number, f"undefined link reference: [{m.group(1)}]")


# ---------------------------------------------------------------------------
# prd + docs
# ---------------------------------------------------------------------------

PRD_REF = re.compile(r"\bPRD-(\d{2})\b")
PRD_ROW = re.compile(r"^\|\s*(\d{2})\s*\|")


def check_prds(files: list[Path]) -> None:
    prd_dir = Path("docs/prd")
    on_disk: dict[str, Path] = {}
    for rel in files:
        m = re.fullmatch(r"PRD-(\d{2})-.+\.md", rel.name)
        if m and rel.parent == prd_dir:
            if m.group(1) in on_disk:
                problem(rel, None, f"PRD-{m.group(1)} is already used by {on_disk[m.group(1)].name}")
            on_disk[m.group(1)] = rel

    for rel in files:
        text = read_text(rel)
        if text is None:
            continue
        for number, line in enumerate(text.split("\n"), start=1):
            for m in PRD_REF.finditer(line):
                if m.group(1) not in on_disk:
                    problem(rel, number, f"PRD-{m.group(1)} is referenced but docs/prd/PRD-{m.group(1)}-*.md does not exist")

    index = Path("docs/FEATURE-GAP-ANALYSIS.md")
    text = read_text(index) if index in files else None
    if text is None:
        problem(index, None, "missing (the PRD index lives here)")
        return
    section = re.search(r"^## F\. PRD index\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    if not section:
        problem(index, None, 'no "## F. PRD index" section')
        return
    listed = {m.group(1) for line in section.group(1).split("\n") if (m := PRD_ROW.match(line))}
    for n in sorted(set(on_disk) - listed):
        problem(index, None, f"PRD-{n} exists but is missing from the PRD index table")
    for n in sorted(listed - set(on_disk)):
        problem(index, None, f"PRD index lists {n}, but docs/prd/PRD-{n}-*.md does not exist")


def check_docs_index(files: list[Path]) -> None:
    index = Path("docs/README.md")
    text = read_text(index) if index in files else None
    if text is None:
        return  # reported by the community check
    linked = set()
    for _, line in markdown_lines(text):
        for m in INLINE_TARGET.finditer(INLINE_CODE.sub("", line)):
            target = unquote(m.group(1).split("#", 1)[0])
            if target:
                linked.add(os.path.normpath(Path("docs") / target))
    for rel in files:
        if rel.parent == Path("docs") and rel.suffix == ".md" and rel.name != "README.md":
            if os.path.normpath(rel) not in linked:
                problem(rel, None, "not linked from docs/README.md")


# ---------------------------------------------------------------------------
# workflows, scripts, community, version, secrets
# ---------------------------------------------------------------------------

# `uses:` in block or flow style, quoted or not, value on the same or the next line.
USES = re.compile(r"""\buses\s*:\s*['"]?([^\s'",}#]+)""")
# The `on:` block (string, list or map form), and the triggers in it that run with a
# write token and secrets in the base repository's context.
ON_BLOCK = re.compile(r"^[\"']?on[\"']?\s*:(.*?)(?=^\S|\Z)", re.MULTILINE | re.DOTALL)
PRIVILEGED_TRIGGER = re.compile(r"\b(pull_request_target|workflow_run)\b")
COMMENT = re.compile(r"(^|\s)#.*$", re.MULTILINE)
UNBRACED = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")


def check_workflows(files: list[Path]) -> None:
    for rel in files:
        if rel.parent != Path(".github/workflows") or rel.suffix not in {".yml", ".yaml"}:
            continue
        text = read_text(rel) or ""
        if not re.search(r"^permissions:", text, re.MULTILINE):
            problem(rel, None, "no top-level `permissions:` (declare least privilege explicitly)")

        # Comments removed, line numbers kept, so a mention in a comment is not a use.
        code = COMMENT.sub(r"\1", text)

        def line_of(offset: int) -> int:
            return code.count("\n", 0, offset) + 1

        for block in ON_BLOCK.finditer(code):
            for m in PRIVILEGED_TRIGGER.finditer(block.group(1)):
                problem(rel, line_of(block.start(1) + m.start()),
                        f"{m.group(1)} runs with secrets and a write token in the base repository; "
                        "do not use it without a security review")
        for m in USES.finditer(code):
            ref = m.group(1)
            if ref.startswith("./"):
                continue
            number = line_of(m.start(1))
            action, _, version = ref.partition("@")
            if ref.startswith("docker://"):
                if "@sha256:" not in ref:
                    problem(rel, number, f"{ref}: pin Docker images by digest")
            elif not FULL_SHA.match(version):
                problem(rel, number, f"{action} must be pinned to a full commit SHA, not '{version or 'no ref'}'")


def check_scripts(files: list[Path]) -> None:
    for rel in files:
        if rel.parent != Path("Scripts") or rel.suffix not in {".sh", ".py"}:
            continue
        path = ROOT / rel
        first = path.read_text(encoding="utf-8").split("\n", 1)[0]
        if not first.startswith("#!"):
            problem(rel, 1, "missing shebang")
        if not os.access(path, os.X_OK):
            problem(rel, None, "not executable (chmod +x)")
        if rel.suffix == ".sh":
            # bash 3.2 (what macOS ships) reads a non-ASCII character right after
            # `$NAME` as part of the variable name in UTF-8 locales, so
            # "“$NAME”" dies with "unbound variable" under `set -u`.
            for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
                for m in UNBRACED.finditer(line):
                    problem(rel, number, f"write ${{{m.group(1)}}}, not ${m.group(1)}: a non-ASCII "
                                         "character follows it, which bash 3.2 reads as part of the name")


def check_community(files: list[Path]) -> None:
    present = set(files)
    for required in REQUIRED_FILES:
        if Path(required) not in present:
            problem(required, None, "required file is missing")


def check_version(files: list[Path]) -> None:
    # Through `bash` rather than the shebang: a script that lost its executable
    # bit (reported by check_scripts) must not abort the run with a traceback
    # before any problem has been printed.
    try:
        result = subprocess.run(["bash", str(ROOT / "Scripts/version.sh")],
                                capture_output=True, text=True)
    except OSError as error:
        problem("Scripts/version.sh", None, f"could not be run: {error}")
    else:
        if result.returncode != 0:
            problem("Scripts/version.sh", None, (result.stderr.strip() or "failed").splitlines()[-1])
    changelog = read_text(Path("CHANGELOG.md")) if Path("CHANGELOG.md") in files else None
    if changelog is not None and not re.search(r"^## \[Unreleased\]", changelog, re.MULTILINE):
        problem("CHANGELOG.md", None, "no `## [Unreleased]` section")


# Built from pieces so this file does not match its own patterns.
SECRET_PATTERNS = [
    (re.compile("-----BEGIN (?:[A-Z]+ )?PRIVATE " + "KEY-----"), "private key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b"), "GitHub token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
]
HOME_PATH = re.compile(r"/Users/([A-Za-z0-9._-]+)/")
PLACEHOLDER_USERS = {"you", "me", "name", "user", "username", "yourname", "example", "someone", "$user",
                     "shared", "runner"}  # /Users/Shared is macOS's shared folder; /Users/runner is the CI home


def check_secrets(files: list[Path]) -> None:
    for rel in files:
        size = (ROOT / rel).stat().st_size
        if size > MAX_FILE_BYTES:
            problem(rel, None, f"{size:,} bytes is over the {MAX_FILE_BYTES:,}-byte limit; "
                               "large binaries do not belong in the repository")
        text = read_text(rel)
        if text is None or is_verbatim(rel):
            continue
        for number, line in enumerate(text.split("\n"), start=1):
            for pattern, what in SECRET_PATTERNS:
                if pattern.search(line):
                    problem(rel, number, f"looks like a {what}")
            for m in HOME_PATH.finditer(line):
                if m.group(1).lower() not in PLACEHOLDER_USERS:
                    problem(rel, number, f"personal home path {m.group(0)!r}")


NETWORK_API = re.compile(
    r"URLSession|NWConnection|NWListener|NWPathMonitor|CFNetwork|CFSocket|WKWebView"
    r"|import WebKit|import Network|getaddrinfo|\"https?://"
)


# The file types this repository holds. Anything else (a capture, a memory dump, an
# archive, a file from someone else's software) is refused rather than guessed at:
# those can carry a keyboard's GUID or serial number, or material that is not ours to
# publish. If a new legitimate file type belongs here, add it and say why in the pull
# request.
ALLOWED_SUFFIXES = {
    ".swift", ".md", ".yml", ".yaml", ".py", ".sh", ".txt", ".json", ".plist",
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".icns",
}
ALLOWED_NAMES = {
    "Makefile", "LICENSE", "CODEOWNERS", ".editorconfig", ".gitattributes",
    ".gitignore", ".git-blame-ignore-revs",
}

# A file with one of these suffixes (or names above) must be text. Without the check, a
# binary file renamed to `.txt` or `.md` would pass the file-type rule and then be
# skipped by every text check.
TEXT_SUFFIXES = {".swift", ".md", ".yml", ".yaml", ".py", ".sh", ".txt", ".json", ".plist", ".svg"}

# The first bytes an image of each kind starts with, so that a renamed capture or dump is
# not taken for a picture.
IMAGE_SIGNATURES = {
    ".png": (b"\x89PNG\r\n\x1a\n",),
    ".jpg": (b"\xff\xd8\xff",),
    ".jpeg": (b"\xff\xd8\xff",),
    ".gif": (b"GIF87a", b"GIF89a"),
    ".icns": (b"icns",),
}

# An armoured block (a key, a certificate, a signature) does not belong in a text file here.
ARMOURED_BLOCK = re.compile(r"^-----BEGIN [A-Z0-9 ]+-----")

# A maintainer's private list of words that must never be published, one regular
# expression per line (blank lines and lines starting with # are ignored). It is
# deliberately not part of the repository: a list of what to keep out would itself say
# what to look for. Point CHECK_DENYLIST at it, or keep it in a git-ignored
# `.check-denylist` at the repository root.
LOCAL_DENYLIST = Path(os.environ.get("CHECK_DENYLIST") or ROOT / ".check-denylist")


def load_denylist() -> list[re.Pattern[str]]:
    """The private list's patterns. A list that was asked for but cannot be used is a
    problem, never a silent skip: it is the guard for what this script cannot name."""
    if not LOCAL_DENYLIST.is_file():
        if os.environ.get("CHECK_DENYLIST"):
            problem("CHECK_DENYLIST", None, f"{LOCAL_DENYLIST} does not exist or is not a file")
        return []
    try:
        # utf-8-sig: an editor's byte-order mark must not silently break the first pattern.
        lines = LOCAL_DENYLIST.read_text(encoding="utf-8-sig").split("\n")
    except (OSError, UnicodeDecodeError) as error:
        problem("CHECK_DENYLIST", None, f"{LOCAL_DENYLIST} cannot be read: {error}")
        return []
    patterns = []
    for number, raw in enumerate(lines, start=1):
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        try:
            patterns.append(re.compile(raw, re.IGNORECASE))
        except re.error as error:
            problem(LOCAL_DENYLIST, number, f"not a valid regular expression: {error}")
    if not patterns:
        problem("CHECK_DENYLIST", None, f"{LOCAL_DENYLIST} has no usable patterns; add some, "
                                        "or remove the file if you do not keep a list")
    return patterns


DENYLIST_STATE = "none (CHECK_DENYLIST is not set and there is no .check-denylist)"


def check_vendor(files: list[Path]) -> None:
    global DENYLIST_STATE
    denylist = load_denylist()
    if LOCAL_DENYLIST.is_file():
        DENYLIST_STATE = f"{len(denylist)} pattern{'' if len(denylist) == 1 else 's'} from {LOCAL_DENYLIST}"
    for rel in files:
        if rel.suffix.lower() not in ALLOWED_SUFFIXES and rel.name not in ALLOWED_NAMES:
            problem(rel, None, "unexpected file type: captures, dumps and other files that can carry a serial "
                               "number or are not ours to publish must never be committed. If this is a "
                               "legitimate source or document type, add it to ALLOWED_SUFFIXES in "
                               "Scripts/check-repo.py")
        suffix = rel.suffix.lower()
        if (suffix in TEXT_SUFFIXES or rel.name in ALLOWED_NAMES) and not is_verbatim(rel) \
                and read_text(rel) is None and (ROOT / rel).stat().st_size > 0:
            problem(rel, None, "binary content in a file that must be text (a capture or dump renamed?)")
        if suffix in IMAGE_SIGNATURES:
            with open(ROOT / rel, "rb") as handle:
                head = handle.read(8)
            if not head.startswith(IMAGE_SIGNATURES[suffix]):
                problem(rel, None, f"does not start like a {suffix[1:].upper()} image (a renamed capture or dump?)")
        if rel.name.endswith(".local.json") or ".claude" in rel.parts:
            problem(rel, None, "tool-local settings are per-machine and can record commands and file names, "
                               "and a project's hooks and permissions run on every contributor's machine; "
                               "keep them out of the repository")
        if is_verbatim(rel):
            continue
        text = read_text(rel)
        if text is None:
            continue
        for number, line in enumerate(text.split("\n"), start=1):
            if ARMOURED_BLOCK.match(line):
                problem(rel, number, "an armoured block (a key, certificate or signature) must not be committed")
            for pattern in denylist:
                if pattern.search(line):
                    problem(rel, number, "matches a line of your private deny-list (CHECK_DENYLIST)")


# Files whose shell blocks are for Claude Code to run line by line, not for people to paste.
PASTE_EXEMPT = {"CLAUDE.md"}
SHELL_FENCE = re.compile(r"^\s*(?:```|~~~)(\w*)")
SHELL_QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")


def check_paste(files: list[Path]) -> None:
    for rel in files:
        if rel.suffix != ".md" or rel.name in PASTE_EXEMPT or is_verbatim(rel):
            continue
        text = read_text(rel)
        if text is None:
            continue
        in_block, lang = False, ""
        for number, line in enumerate(text.split("\n"), start=1):
            fence = SHELL_FENCE.match(line)
            if fence:
                in_block, lang = (not in_block), (fence.group(1) if not in_block else "")
                continue
            if in_block and lang.lower() in ("", "bash", "sh", "shell", "zsh"):
                bare = SHELL_QUOTED.sub("''", line)
                if bare.lstrip().startswith("#") and not bare.lstrip().startswith("#!"):
                    problem(rel, number, "`# comment` line in a shell block: zsh does not treat a pasted `#` "
                                         "as a comment, so quotes, backticks and parentheses in it are "
                                         "still executed or swallow the lines that follow. Put the "
                                         "explanation in the text instead")
                elif re.search(r"\S\s+#", bare):
                    problem(rel, number, "trailing `# comment` in a shell block: zsh passes it to the "
                                         "command as arguments when the block is pasted. Put the "
                                         "explanation in the text instead")


# The repository every mention of the owner's repositories must name.
REPO_SLUG = "apex-control"
OWNER_LINK = re.compile(r"\bRikearon/([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)")


def check_slug(files: list[Path]) -> None:
    for rel in files:
        if is_verbatim(rel):
            continue
        text = read_text(rel)
        if text is None:
            continue
        for number, line in enumerate(text.split("\n"), start=1):
            for m in OWNER_LINK.finditer(line):
                name = m.group(1)
                if name.endswith(".git"):
                    name = name[:-len(".git")]
                if name != REPO_SLUG:
                    problem(rel, number, f"names Rikearon/{m.group(1)}, but the repository "
                                         f"is {REPO_SLUG} (REPO_SLUG in Scripts/check-repo.py)")


def check_no_network(files: list[Path]) -> None:
    for rel in files:
        if rel.suffix != ".swift" or rel.parts[0] != "Sources":
            continue
        for number, line in enumerate((read_text(rel) or "").split("\n"), start=1):
            m = NETWORK_API.search(line)
            if m:
                problem(rel, number,
                        f"`{m.group(0)}`: the app promises to make no network connections "
                        "(docs/PRIVACY.md, SECURITY.md). If you are deliberately changing that, "
                        "change the policy documents and this check in the same pull request.")


# ---------------------------------------------------------------------------

def main() -> int:
    files = list_files()
    check_hygiene(files)
    check_links(files)
    check_prds(files)
    check_docs_index(files)
    check_workflows(files)
    check_scripts(files)
    check_community(files)
    check_version(files)
    check_slug(files)
    check_paste(files)
    check_secrets(files)
    check_no_network(files)
    check_vendor(files)

    if problems:
        for p in problems:
            print(f"✗ {p}")
        print(f"\n{len(problems)} problem(s) in {len(files)} files.", file=sys.stderr)
        return 1
    print(f"✓ {len(files)} files checked: hygiene, links, PRDs, docs index, "
          "workflows, scripts, community files, version, paste, slug, secrets, network, vendor.")
    print(f"  private deny-list: {DENYLIST_STATE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

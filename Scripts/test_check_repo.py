#!/usr/bin/env python3
"""Tests for Scripts/check-repo.py: each rule is shown to fire on a tree that breaks it,
and the repository itself is shown to pass.

    python3 -m unittest discover -s Scripts -p 'test_*.py'      (or: make test-tools)

The checker looks at the tree around it, so every test runs it as a subprocess on a
scratch copy of the repository's files. Standard library only, Python 3.9+.

Literals that the checker itself would flag (a personal path, an old repository name, an
armoured block, a PRD number that does not exist) are built from pieces, so that this
file does not trip the rules it tests.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKER = Path("Scripts") / "check-repo.py"


def repository_files():
    """The files the checker examines: tracked ones plus untracked ones that are not ignored."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=ROOT, check=True, capture_output=True,
        ).stdout
        names = [n for n in out.decode("utf-8").split("\0") if n]
    except (OSError, subprocess.CalledProcessError):
        skip = {".git", ".build", "build", "dist", ".swiftpm", ".claude", "__pycache__"}
        names = [
            str(p.relative_to(ROOT))
            for p in ROOT.rglob("*")
            if p.is_file() and not (set(p.relative_to(ROOT).parts) & skip)
        ]
    return [n for n in names if (ROOT / n).is_file()]


class CheckRepoTests(unittest.TestCase):

    def setUp(self):
        scratch = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        self.root = Path(scratch) / "repo"
        for name in repository_files():
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)

    # -- helpers ---------------------------------------------------------------------

    def write(self, rel, content, binary=False):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if binary:
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        return path

    def check(self, env=None):
        merged = dict(os.environ)
        merged.pop("CHECK_DENYLIST", None)
        merged.update(env or {})
        result = subprocess.run(
            [sys.executable, str(self.root / CHECKER)],
            cwd=self.root, capture_output=True, text=True, env=merged,
        )
        return result.returncode, result.stdout + result.stderr

    def assertFlagged(self, fragment, env=None):
        code, output = self.check(env)
        self.assertEqual(code, 1, f"expected a problem mentioning {fragment!r}, got:\n{output}")
        self.assertIn(fragment, output)

    def assertNotFlagged(self, fragment, env=None):
        _, output = self.check(env)
        self.assertNotIn(fragment, output)

    # -- the repository itself ---------------------------------------------------------

    def test_the_repository_passes(self):
        code, output = self.check()
        self.assertEqual(code, 0, output)

    # -- file types and content ---------------------------------------------------------

    def test_an_unexpected_file_type_is_refused(self):
        self.write("capture.pcap", "x\n")
        self.assertFlagged("capture.pcap: unexpected file type")

    def test_binary_content_in_a_text_file_is_refused(self):
        self.write("docs/notes.txt", b"looks like text\0but is not", binary=True)
        self.assertFlagged("docs/notes.txt: binary content in a file that must be text")

    def test_an_image_must_start_like_an_image(self):
        self.write("docs/images/fake.png", "not a png\n")
        self.assertFlagged("docs/images/fake.png: does not start like a PNG image")

    def test_tool_local_settings_are_refused(self):
        self.write(".claude/settings.local.json", "{}\n")
        self.assertFlagged(".claude/settings.local.json: tool-local settings")

    def test_anything_else_under_dot_claude_is_refused(self):
        self.write(".claude/settings.json", "{}\n")
        self.write(".claude/commands/notes.md", "scratch\n")
        self.write(".claude/nested/settings.json", "{}\n")
        self.write("Sources/.claude/settings.json", "{}\n")
        code, output = self.check()
        self.assertEqual(code, 1, output)
        for name in (".claude/settings.json", ".claude/commands/notes.md", ".claude/nested/settings.json",
                     "Sources/.claude/settings.json"):
            self.assertIn(f"{name}: tool-local settings", output)

    def test_an_armoured_block_is_refused(self):
        self.write("docs/key.md", "-----BEGIN " + "PGP MESSAGE-----\nabc\n")
        self.assertFlagged("an armoured block")

    def test_the_private_denylist_is_applied_and_is_optional(self):
        denylist = self.root.parent / "denylist.txt"
        denylist.write_text("# a comment\nfrobnicate\n", encoding="utf-8")
        self.write("docs/note.md", "We frobnicate the widget.\n")
        self.assertFlagged("docs/note.md:1: matches a line of your private deny-list",
                           env={"CHECK_DENYLIST": str(denylist)})
        self.assertNotFlagged("matches a line of your private deny-list")

    def test_the_run_says_whether_the_denylist_was_applied(self):
        denylist = self.root.parent / "denylist.txt"
        # Bracketed, so that these lines do not match themselves in this file.
        denylist.write_text("# a comment\nzzq[u]x\nyyq[u]x\n", encoding="utf-8")
        code, output = self.check(env={"CHECK_DENYLIST": str(denylist)})
        self.assertEqual(code, 0, output)
        self.assertIn("private deny-list: 2 patterns", output)
        code, output = self.check()
        self.assertEqual(code, 0, output)
        self.assertIn("private deny-list: none", output)

    def test_a_denylist_that_is_missing_is_an_error_not_a_silent_skip(self):
        missing = self.root.parent / "no-such-list.txt"
        self.assertFlagged("CHECK_DENYLIST: ", env={"CHECK_DENYLIST": str(missing)})

    def test_a_denylist_that_cannot_be_used_is_an_error(self):
        broken = self.root.parent / "broken.txt"
        cases = {
            "has no usable patterns": "# only a comment\n\n",
            "not a valid regular expression": "fine\n([\n",
        }
        for fragment, content in cases.items():
            broken.write_text(content, encoding="utf-8")
            self.assertFlagged(fragment, env={"CHECK_DENYLIST": str(broken)})
        broken.write_bytes(b"\xff\xfe\x00")
        self.assertFlagged("cannot be read", env={"CHECK_DENYLIST": str(broken)})

    def test_a_byte_order_mark_does_not_disable_the_first_pattern(self):
        marked = self.root.parent / "marked.txt"
        marked.write_bytes(b"\xef\xbb\xbf" + "zzq[u]x\n".encode("utf-8"))
        self.write("docs/note.md", "We zzq" + "ux the widget.\n")   # split, so it does not match itself
        self.assertFlagged("docs/note.md:1: matches a line of your private deny-list",
                           env={"CHECK_DENYLIST": str(marked)})

    def test_one_pattern_is_reported_in_the_singular(self):
        one = self.root.parent / "one.txt"
        one.write_text("zzq[u]x\n", encoding="utf-8")
        code, output = self.check(env={"CHECK_DENYLIST": str(one)})
        self.assertEqual(code, 0, output)
        self.assertIn("private deny-list: 1 pattern from", output)

    # -- names and links ------------------------------------------------------------------

    def test_a_stale_repository_name_is_refused(self):
        stale = "Rikearon/" + "old-name"
        self.write("docs/note.md", f"See https://github.com/{stale}.\n")
        self.assertFlagged(f"names {stale}")

    def test_the_current_repository_name_is_accepted(self):
        self.write("docs/note.md", "See https://github.com/Rikearon/apex-control.\n")
        self.assertNotFlagged("docs/note.md:1: names")

    def test_a_broken_relative_link_is_refused(self):
        self.write("docs/note.md", "[gone](does-not-exist.md)\n")
        self.assertFlagged("does-not-exist.md")

    def test_a_broken_anchor_is_refused(self):
        self.write("docs/note.md", "[section](README.md#no-such-heading)\n")
        self.assertFlagged("no-such-heading")

    def test_a_missing_prd_is_refused(self):
        missing = "PRD-" + "99"
        self.write("docs/note.md", f"This needs {missing}.\n")
        self.assertFlagged(missing)

    # -- text hygiene ------------------------------------------------------------------------

    def test_an_invisible_character_is_reported_with_its_place(self):
        self.write("docs/note.md", "a" + chr(0x2011) + "b\n")
        self.assertFlagged("U+2011")

    def test_a_personal_home_path_is_refused(self):
        self.write("docs/note.md", "See " + "/Users/" + "alice/Documents.\n")
        self.assertFlagged("docs/note.md")

    # -- shell blocks that get pasted -----------------------------------------------------------

    def test_shell_block_comments_are_refused(self):
        fence = "`" * 3
        body = f"{fence}bash\n# explain it\napexctl info\napexctl clear  # and this\n{fence}\n"
        self.write("docs/note.md", body)
        code, output = self.check()
        self.assertEqual(code, 1, output)
        self.assertIn("docs/note.md:2: `# comment` line in a shell block", output)
        self.assertIn("docs/note.md:4: trailing `# comment` in a shell block", output)

    def test_a_hash_inside_quotes_is_not_a_comment(self):
        fence = "`" * 3
        self.write("docs/note.md", f"{fence}bash\napexctl solid '#FF4A00'\n{fence}\n")
        self.assertNotFlagged("docs/note.md:2")

    # -- workflows and the app ---------------------------------------------------------------------

    def test_an_unpinned_action_is_refused(self):
        workflow = self.root / ".github" / "workflows" / "ci.yml"
        text = workflow.read_text(encoding="utf-8")
        pinned = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        self.assertIn(pinned, text, "the test needs updating: the pinned checkout line moved")
        workflow.write_text(text.replace(pinned, "actions/checkout@v4", 1), encoding="utf-8")
        self.assertFlagged("actions/checkout must be pinned to a full commit SHA")

    def test_a_networking_api_in_the_app_is_refused(self):
        self.write("Sources/ApexKit/Sneaky.swift", "let session = URL" + "Session.shared\n")
        self.assertFlagged("Sources/ApexKit/Sneaky.swift:1")


if __name__ == "__main__":
    unittest.main()

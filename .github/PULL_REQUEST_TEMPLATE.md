## What does this change, and why?

<!-- The problem first, then the fix. Link the issue or PRD it relates to: `Closes #123`, `PRD-04 FR-2`. -->

## How was it verified?

<!-- Say what you ran. For anything that talks to the keyboard: the commands, and the firmware
     (`apexctl info` prints it). If you could not test on hardware, say so plainly. -->

## Checklist

- [ ] `swift build` and `swift test` pass, and the build is warning-free
- [ ] `make check` passes (and `make lint` too, if you touched a script or a workflow)
- [ ] If it changes what reaches the keyboard: I tested it on a device, it reads before it writes, and flash writes are verified by read-back (the app's save at quit and its OLED image save are the two documented exceptions)
- [ ] If it changes the protocol: `docs/PROTOCOL.md` is updated, with how sure it is (confirmed on hardware / from descriptor / needs RE)
- [ ] If it changes what a user sees or does: the README, the user guide or the relevant PRD **Status** is updated, and there is a screenshot for UI changes
- [ ] If a user would notice the change: `CHANGELOG.md` has a line under **Unreleased**
- [ ] The work is mine to license under the project's terms: no vendor files or code, nothing copied from an incompatible licence, and no serial numbers or GUIDs

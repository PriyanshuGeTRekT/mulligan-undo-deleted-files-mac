# Security policy

## Supported versions

Only the [latest release](https://github.com/PriyanshuGeTRekT/mulligan-undo-deleted-files-mac/releases/latest) of Mulligan receives security fixes. Please update to it and check that the problem still happens before reporting.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| Older releases | No        |

## Reporting a vulnerability

**Please do not report security problems in public issues, discussions or pull requests.**

Report them privately through GitHub:

1. Open the [Security tab](https://github.com/PriyanshuGeTRekT/mulligan-undo-deleted-files-mac/security) of this repository.
2. Click **Report a vulnerability**.
3. Describe the problem, the Mulligan and macOS versions affected, and the steps to reproduce it. A proof of concept helps.

You will get a reply as soon as possible, usually within a week. Once the problem is confirmed, a fix is prepared and released, and the advisory is published with credit to you unless you prefer to stay anonymous.

## Scope

Examples of what counts as a security problem in Mulligan:

- Mulligan writing, moving or deleting anything outside its own folder (`~/Library/Application Support/Mulligan`), other than restoring a file you asked for.
- A restore overwriting an existing file without `--replace`.
- Saved copies readable by other users on the same Mac.
- Mulligan making any network request (it should make none).

Mulligan is not notarized by Apple, and the "Open Anyway" step on first launch is expected. That alone is not a vulnerability.

# Security policy

FastMac reads your whole disk, can move files to the Trash, quits apps and runs a few admin
tools behind the macOS password prompt. Security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository. Include the FastMac version, your
macOS version, the steps to reproduce and what you expected to happen.

You'll get an acknowledgement within a few days. Fixes ship in a new release, and reporters are
credited in the changelog unless they'd rather not be.

## Supported versions

Only the latest release receives security fixes.

## Especially in scope

- Anything that moves, deletes or alters a file the safety guard (`Safety.canDelete` in
  `Sources/FastMac/Analysis.swift`) should have refused.
- Quitting or signalling a process other than the one the user confirmed.
- Running an admin command other than the one shown in the confirmation.
- Any network request to something other than `127.0.0.1`.

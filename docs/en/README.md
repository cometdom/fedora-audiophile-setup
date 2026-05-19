# Documentation

Project documentation, English-first.

## Guides

- **[Newbie walkthrough](newbie-walkthrough.md)** — start here if you've never installed Linux before. Takes you from an empty mini-PC to a fully tuned audiophile host, hand-holding every step (BIOS, USB stick, Anaconda installer, SSH, SDK download, running the wizard, first listening test).
- [Fedora 43 minimal install (custom)](fedora-43-minimal-install.md) — terser reference for the install phase, oriented at users who already know their way around a Linux installer.
- [Post-install tuning reference](post-install-tuning.md) — what the wizard does, module by module, and why each tweak matters.
- [Design notes](design-notes.md) — architectural decisions and conventions. Read this before adding a new module.
- [Diretta NIC toggle (bridge ⇄ independent)](diretta-net-toggle.md) — companion tool to temporarily bridge the two NICs so the Diretta target is reachable from the LAN (e.g. to check its firmware) without recabling, then switch back. systemd-networkd only.

## Building a PDF

Any guide here can be rendered to a styled PDF (handy for printing or sharing offline):

```bash
sudo dnf install -y pandoc weasyprint
./scripts/build-pdf.sh                              # newbie walkthrough (default)
./scripts/build-pdf.sh docs/en/post-install-tuning.md
```

The PDF lands next to the source `.md`. Styling lives in [`docs/pdf.css`](../pdf.css).

## Translations

Available / planned:

- French (`docs/fr/`) — [newbie walkthrough](../fr/newbie-walkthrough.md) translated (synced with EN v0.1). Other guides pending.
- Spanish (`docs/es/`) — planned.

If you'd like to contribute a translation, please open an issue first so we can sync on the source revision.

Each translated file should start with a marker line like:

```html
<!-- Translated from EN docs v0.X — last sync: YYYY-MM-DD -->
```

so we know when a translation is in sync with the English source.

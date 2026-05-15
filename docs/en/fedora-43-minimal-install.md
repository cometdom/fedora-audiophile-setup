# Fedora 43 or 44 — Minimal Custom Install

> This page has been folded into the full step-by-step guide. The Fedora install
> phase (BIOS settings, ISO choice, bootable USB, the Anaconda installer screen
> by screen, minimal package selection) is now covered — with screenshots — in
> the newbie walkthrough:
>
> - **English:** [Newbie walkthrough](newbie-walkthrough.md) — see *Part A — at the machine* (sections 2 to 5).
> - **Français :** [Guide pas à pas pour débutant](../fr/newbie-walkthrough.md) — voir *Partie A — à la machine* (sections 2 à 5).

Installing a clean, minimal Fedora base is the **pre-requisite** for running `setup.sh`. Rather than maintain that material in two places, it lives in the walkthrough above, which takes you all the way from an empty machine to a working audiophile host.

The short version:

- Use the **Fedora 43 or 44 Server netinst** ISO (`Fedora-Server-netinst-x86_64-44-*.iso`, or `-43-`).
- In the Anaconda installer, pick **Software Selection → Fedora Custom Operating System** and tick no add-on groups.
- **Secure Boot must be OFF** in firmware — the realtime kernel cannot be signed.
- IPv6 must stay enabled (the Diretta protocol requires it).

Everything else — partitioning, network, user creation, post-install — is in the walkthrough.

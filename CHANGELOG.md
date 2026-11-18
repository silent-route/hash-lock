# Changelog

## 1.0.3-beta

Replaces 1.0.1-beta and 1.0.2-beta, which were withdrawn; their changes are here.

- Copy buttons turn into a checkmark for a moment, so you can see the value was copied.
- The menu bar icon stays highlighted while its panel is open, without a blink: the panel opens as soon as the mouse button is pressed, as the system's menus do. Its edge lines up with the highlight's, as a system menu's does.
- Removed the option to erase a vault after a number of wrong passwords. It only limited guessing inside the app: anyone with a copy of the vault's files can guess elsewhere as long as they like, and the app itself can be patched to skip the count. What actually stops guessing is Argon2id and a good password. The option also let anyone at the Mac wipe a vault on purpose.

## 1.0.0-beta

First public release.

- Notes with fields (Login, Password, IP Address, Website, Text, Secret), free text and attached files. Password and login generators. Long values wrap so they can be read in full.
- Crypto wallet backups with presets for Bitcoin, Monero and other coins. BIP-39 words and checksums are checked as you type.
- Files and whole folders, symlinks included, browsed as icons, a list or columns like in Finder. Images, PDFs and text open in the app.
- Several vaults, each with its own password and an optional 24-word recovery key.
- Argon2id for the password, XChaCha20-Poly1305 for every note and file, each with its own key. Changing the password re-encrypts the vault under a new master key.
- Vault export and import as one encrypted `.hashlock` file.
- Locks on idle, sleep, screen lock and user switch. Copied values are kept off clipboard history and Universal Clipboard and cleared after 90 seconds.
- Optional erase of a vault after a number of wrong passwords in a row.
- Menu bar item, single instance, no network access at all.

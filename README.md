# Hash Lock

An encrypted vault for the Mac. Passwords, server logins, keys, crypto wallet backups, and files or whole folders you'd rather not leave lying around, even on your own disk.

I wanted one place for all of that which never touches the network, keeps nothing decrypted longer than it has to, and doesn't ask me to trust a cloud. Nothing I tried did all three, so I wrote this.

Intel and Apple Silicon, macOS 14 Sonoma or later. No network access at all.

[Releases](../../releases)

**Status:** beta. The vault format is versioned, and later versions will open vaults made by this one. Keep a backup anyway.

## Features

**What goes in**
- **Notes** with a title, free text, attached files and fields: Login, Password, IP Address (an optional port is fine, and it's checked as you type), Website, Text and Secret. Any field can be hidden behind dots; passwords and secrets start hidden. Long values wrap, so a key or token is readable in full. There's a generator for passwords (characters or words) and for logins.
- **Crypto wallets.** A template with presets for Bitcoin, Monero and other coins. Bitcoin: seed words (BIP-39, Electrum, SLIP-39, aezeed or other), passphrase, software, derivation path, xpub, birthday. Monero: the 25-word seed, Polyseed or the old 13 words, seed offset, address, view and spend keys, restore height. Words from the BIP-39 list are checked as you type, BIP-39 seeds against their checksum too. It's a backup, so Hash Lock never derives keys or addresses.
- **Files and folders.** Drop them on the window, paste with ⌘V, or pick them. Images, PDFs and text open inside the app. A folder keeps its structure and symlinks, and you browse it like in Finder: icons, list or columns.
- **Several vaults** (Personal, Work…), each with its own password. One is open at a time.

**Getting around**
- The list searches names only, never contents. Pinned items sit in their own section on top.
- Right-click an empty part of the list for New Note, New Crypto Wallet or Add Files. Double-click it for a new note. Click the list header or press Esc to close the open item.
- Copying a field marks it so clipboard managers skip it, keeps it off Universal Clipboard, and clears it after 90 seconds if it's still there.
- Export a file, or drag it to Finder. It's written straight to where you drop it, with no temporary copy.
- The menu bar item opens, locks and quits. Quitting always locks first.

What changed in each version: [CHANGELOG.md](CHANGELOG.md).

## Security

**The password is never stored.** Each vault has a random 256-bit master key. It's saved only encrypted, under a key Argon2id derives from your password (256 MB and three passes per try by default, up to 2 GB in Settings). Checking a password means trying to decrypt that copy, the same way a Bitcoin wallet checks its passphrase. A recovery key is optional: 24 words on paper that unlock a second encrypted copy.

**On disk** every note and every file is its own encrypted file with its own key, sealed with XChaCha20-Poly1305 (libsodium secretstream). A changed byte, a truncated file or two swapped files fail to decrypt. Sizes are padded to a rough size class. Writes are atomic, so a crash leaves the old version or the new one.

In the clear: each vault's name (so you can pick one before unlocking), the password derivation settings, and what the folder itself shows, which is how many encrypted files there are, their rough sizes and when they changed. Titles, file names and contents are encrypted. Full format: [docs/format.md](docs/format.md).

**Changing the password** re-encrypts the whole vault under a new master key by default. The new copy is written next to the old one and swapped in with a single atomic rename. After that, an old backup of the vault's header plus the old password opens nothing current. With a recovery key you get new words. You can turn re-encryption off for a quick change; the sheet tells you what that costs.

**In memory**
- Keys live in libsodium's guarded memory: locked out of swap, fenced by guard pages, wiped on lock.
- Only the open item is decrypted. Locking drops everything, wipes the buffers Hash Lock owns, overwrites the editor's storage and clears the clipboard if it still holds our value.
- Text that has been on screen also passed through Swift strings, images and PDFs, and macOS has no reliable way to scrub those. They're freed, and their bytes can linger in the app's memory until reused. Only root or a debugger could read them, and the hardened runtime blocks debuggers.
- After quitting, macOS zeroes the app's memory before anyone else gets it. Swap and the sleep image are encrypted. Core dumps are off, and no window state is saved.

**Around the app**
- App Sandbox without the network entitlement, so macOS itself won't let it connect anywhere.
- No AppleScript, no URL scheme, no helper. The hardened runtime keeps other processes from attaching or injecting code.
- The note editor has spell check, autocorrect, completion, data detectors and Writing Tools off, so your text isn't sent to system services.
- One copy of the app runs, and a vault opens in one copy at a time.

**Locking.** After 15 minutes idle, on sleep, screen lock, screen saver and user switch; all of it is adjustable in Settings › Lock. Settings that weaken protection can only be changed with a vault unlocked, and locking closes any sheet showing vault data. Optionally (off by default) a vault is erased after a set number of wrong passwords in a row. That only limits guessing inside the app.

**Limits**
- Malware running as you while a vault is open can read the screen or log keys, as with any app.
- A weak password. Use several random words, and the Strong setting for a vault you export.
- Anyone who can write to the vault's folder can delete it or put back an older copy. Keep backups.
- An old backup opens with the password it was made with. Re-encrypting protects the vault as it is now, and the backup still holds what it held.

## Installation

1. Download `Hash-Lock-<version>.dmg` from [Releases](../../releases) and drag Hash Lock to Applications.
2. The app isn't notarized (no Apple Developer account behind it), so remove the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Hash Lock.app"
   ```

   or open it once and click Open Anyway in System Settings › Privacy & Security.

### Updating

Open the new disk image and drag Hash Lock over the old one. Vaults live in the app's container and aren't touched. A running copy notices the new version and offers Relaunch to Update.

Every release is signed with the same certificate, and macOS ties the app's data to it. If a copy signed by someone else asks for access to Hash Lock's data, say no.

### Moving a vault

Settings › Vault › Export writes the vault to one `.hashlock` file without decrypting anything. On another Mac, use Import Vault… or double-click the file; it opens with the same password or recovery key. If that vault is already there, you choose to replace it or keep both.

The file is protected by the password alone, so anyone holding it can guess offline as long as they like. It also lives on its own: later password changes or deleting the vault don't reach it. The app shows both warnings before exporting.

### Uninstalling

Settings › Vault › Uninstall Hash Lock moves the app to the Trash, and can delete all vaults with it. Deleting a vault overwrites its encrypted master key first. Backups and snapshots made before that are out of the app's reach.

## Building

Swift 6 and the macOS 26 SDK (Xcode 26 or just its Command Line Tools).

```sh
scripts/fetch-libsodium.sh   # libsodium at the version and checksum in libsodium.pin
scripts/test.sh              # unit tests
scripts/build-app.sh         # build/Hash Lock.app, universal, sandboxed, self-signed
scripts/package-release.sh   # build/release/Hash-Lock-<version>.dmg and its SHA-256
swift run ui-snapshots       # renders the windows to PNG
```

The signing identity is created on the first build in `~/.hashlock-signing`. Back it up: an app signed with another certificate looks like a different app to macOS.

| Directory | Contents |
|---|---|
| `Sources/VaultCore` | key derivation, key slots, encryption, catalog, vault files; no UI |
| `Sources/HashLockUI` | model, windows, editors, settings |
| `Sources/HashLockApp` | entry point, main window, menu bar item |
| `Sources/ui-snapshots` | development tool, not shipped |
| `Tests/VaultCoreTests` | tampering, truncation, swapped files, header downgrades, re-encryption, recovery, vault files, BIP-39 vectors |

Releases are built by GitHub Actions on a `v*` tag.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). Use it, change it, sell it, whatever you like. If you share a modified version, share its source under the same license.

Includes [libsodium](https://libsodium.org) (ISC) and the BIP-39 English word list (MIT). Their notices ship in the app's `Contents/Resources`.

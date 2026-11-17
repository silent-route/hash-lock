# Vault format, version 1

Everything Hash Lock keeps is in its sandbox container:

```
~/Library/Containers/org.hashlock.app/Data/Library/Application Support/Hash Lock/Vaults/
  <vault id>/
    info.json        the vault's name and creation date — the only plaintext besides the header
    header.json      format, version, vault id and key slots
    catalog          the encrypted item list
    blobs/xx/<id>    one encrypted blob per note body or file
    .lock            held with flock(2) while the vault is unlocked, so one copy of the app opens it at a time
```

## Keys

- **Master key (MK):** 32 random bytes, made when the vault is created and never written in the clear. A plain password change only re-wraps it; re-encrypting (on by default in Change Password) replaces it, so an older header no longer opens anything.
- **Key slots** in `header.json` hold MK encrypted with XChaCha20-Poly1305 under a *wrapping key*:
  - **password slot:** wrapping key = Argon2id13(password in Unicode NFC, 16-byte random salt, opslimit, memlimit) → 32 bytes. The settings are stored with the slot; a header asking for less than 2 passes / 64 MiB, or more than 32 passes / 4 GiB, is refused.
  - **recovery slot (optional):** a BIP-39 phrase of 24 words carries 256 random bits *E*; wrapping key = BLAKE2b-256(key = *E*, message = `"HashLock/recovery/v1"` ‖ vault id).
- Each slot's associated data binds it to the vault and to its own settings: `"HashLock/slot/v1\0"` ‖ vault id (16 bytes) ‖ kind ‖ `\0` ‖ algorithm ‖ `\0` ‖ opslimit (u64 LE) ‖ memlimit (u64 LE) ‖ salt. Editing any of them in the header makes the slot fail to open, exactly as a wrong password does. **The password check is this authentication tag; nothing derived from the password is stored.**
- **Subkeys** of MK, by libsodium's `crypto_kdf` with context `"HashLock"`: id 1 → catalog key, id 2 → blob root key.
- **Per-blob key** = BLAKE2b-256(key = blob root key, message = the blob's 32-character hex name). A blob moved to another name does not decrypt.

## Blobs

Every encrypted file (the catalog too) is a libsodium `secretstream_xchacha20poly1305` stream:

```
header                                        24 bytes
message 0: "HLB1", 4 zero bytes, length u64   16 bytes + 17
content, then zeros up to the padded length,
in 64 KiB messages; the last one shorter (possibly empty), tagged FINAL
```

- The padded length is Padmé(max(length, 512)): at most 12 % overhead, and only a size class is visible.
- Truncation, reordering, a dropped or altered piece, or extra bytes fail authentication or the size check (the file's size follows exactly from the length in message 0).
- Files are encrypted while they are read, through one 64 KiB buffer; a file that changes while it is added is refused.

## Writes

Every file is written to a temporary file beside it (mode 0600), flushed with `F_FULLFSYNC`, and renamed over the old one; the folder is flushed after. A changed note is a new blob; the catalog is saved; only then is the old blob removed. A crash at any point leaves one complete version.

The catalog lists the blobs its last save let go of (`retired`); they are removed right after, and if a crash comes first, at the next unlock. No other blob is ever removed on its own: one the catalog doesn't know about (left by a crash, or because an older `catalog` was put back) may be the only copy of something. Verify counts them, and can list them as items again (a blob's key follows from its name, so it still decrypts) or remove them.

## Re-encrypting

Every blob is read with the old key and written with the new one, piece by piece, into `.reencrypt-<uuid>` beside the vault, with a new catalog and header. The two folders are then exchanged with `renamex_np(RENAME_SWAP)` in one step, and the old one is shredded. Importing over an existing vault uses the same swap, and takes the vault's lock first. Leftover `.reencrypt-`, `.import-` and `.replaced-` folders from a crash are shredded at launch.

## Deleting

Deleting a vault first overwrites `header.json` — the only place MK exists, wrapped — with random bytes and flushes it, then removes the folder.

## Vault files (.hashlock)

One file holding a vault's own files, already encrypted:

```
"HLARCH01"
entries: path length (u16 LE), path (UTF-8), size (u64 LE), bytes
end: path length 0
BLAKE2b-256 of everything before it
```

Only `header.json`, `info.json`, `catalog` and `blobs/xx/<hex>` are accepted; anything else, a repeated path, a size past the end of the file or a wrong checksum refuses the whole file. The checksum catches a copy damaged on the way; what keeps the vault safe is its own encryption. An import is unpacked into a hidden folder beside the vaults and moved into place only once all of it checks out.

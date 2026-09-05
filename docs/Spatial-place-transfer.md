# Encrypted place transfer

In spatial-data settings, choose **Export encrypted place** beside a saved place. Save the displayed recovery key separately, confirm that it is saved, then choose a destination in the system Files exporter. Vispace does not upload, message, or automatically share the file or key. Closing the export sheet releases the in-app copy of the key. Import uses the system Files picker and a recovery-key field; no folder import or automatic overwrite is available.

The transfer contains one latest valid ARWorldMap checkpoint and that map's current object metadata, including user names and temporal revision provenance. Historical checkpoints, mutation journals, scene relations, coordinate alignments, and place fingerprints are not transferred. Derived state is rebuilt from the imported metadata and subsequent observations. There are no camera/depth pixel buffers in the portable schema. Restore the imported place by viewing the original physical space on a compatible LiDAR device.

## Format and validation

- File prefix: UTF-8 `VISPACE-PLACE`, followed by the two-byte big-endian envelope version `1`.
- The remaining bytes are a CryptoKit AES-256-GCM combined sealed box, including its random nonce and authentication tag. The entire prefix is authenticated as additional data.
- A new random 256-bit recovery key is generated for every export. Its Base64 form is shown only in the export sheet and is not included in the file, logs, preferences, or app-owned disk files. This is a random key, not a human-password encryption scheme.
- Authenticated plaintext: a four-byte big-endian JSON-manifest length, the JSON manifest, the raw secure-coded ARWorldMap archive, and a 32-byte SHA-256 digest of that archive. JSON contains no binary archive/Base64 data and cannot use binary-plist shared references.
- Limits: 36 MiB encrypted file, 3 MiB JSON manifest, 32 MiB world-map archive, and 2,048 objects. Input file size and bounded reads are checked before decryption. Manifest element count is checked before model construction. Object labels and names are limited to 256 UTF-8 bytes in portable files.
- Envelope/manifest version, authenticated decryption, checksum, coordinate provenance, metadata invariants, and Apple's `NSSecureCoding` ARWorldMap-only decoder must all succeed before import writes any place data. Wrong keys, modified bytes, unknown versions, and excessive payloads fail without modifying the selected file.

## Publication and recovery

Storage maintenance pauses capture and drains dependent work. Import reads the existing metadata strictly, without treating an unreadable catalog as an empty store. A surviving backup without its primary catalog requires catalog recovery first. Existing map IDs, coordinate-frame IDs, and global object IDs cause explicit collision errors; import never silently merges or replaces them.

A fresh typed blob is written and verified first. One atomic metadata replacement then publishes its map and objects together. A failed publication removes only the newly created blob; the existing primary catalog remains unchanged. If a process stops before rollback, the unpublished blob cannot be restored independently and normal reconciliation preserves it in bounded quarantine. Backup maintenance may advance to a valid copy of the prior catalog; it never requires replacing existing places with imported content.

For a first import or checkpoint, the recovery copy records the empty prior state until the primary catalog is published. A failed first publication therefore cannot resurrect the rejected map through backup recovery. After successful publication, refreshing that first recovery copy is best effort: a maintenance failure does not report the completed import as failed or remove its referenced blob. If this refresh fails and the primary is subsequently lost before another successful save, only the empty prior state is recoverable.

The importer only reads a user-selected, security-scoped file under coordinated access. Paths in the file are not interpreted as destinations. All writes remain behind the existing repository's protected, backup-excluded spatial-directory policy, symlink checks, byte quota, and free-space admission.

## Validation

`SpatialPlaceArchiveServiceTests` covers encrypted round trips and names, random independent keys, wrong keys and modified ciphertext, future formats, object-count bounds, independent checksum/secure-type validation, import/export with temporal cold recovery and backward wall time, duplicate map/frame/object rejection, surviving-backup preservation, and rollback after a catalog-write failure. Core and repository fixtures replace Apple's opaque ARWorldMap creation only through DEBUG-only validators; production initializers always use Apple's secure decoder. Physical-device relocalization and system Files-provider UI must also be checked on a device.

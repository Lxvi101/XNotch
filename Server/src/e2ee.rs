//! End-to-end encrypted drops (format "XNotch Cloud E2EE v1", see `docs/E2EE.md`).
//!
//! The server never sees keys or plaintext of these drops. It only stores
//! opaque objects, enforces names and size limits, and serves the decrypting
//! page, whose script lives in `assets/`.

/// Format versions this server can store and serve. Advertised in `/api/info`.
pub const VERSIONS: &[u8] = &[1];

/// Fixed header of every encrypted object: magic, version, kind, 32-byte salt.
pub const HEADER_LEN: u64 = 4 + 1 + 1 + 32;
/// AES-GCM tag per segment.
pub const TAG_LEN: u64 = 16;
/// Largest manifest plaintext a client may write and a browser will read.
pub const MAX_MANIFEST_PLAINTEXT: u64 = 256 * 1024;
/// The manifest is always a single segment, so this is its largest ciphertext.
pub const MAX_MANIFEST_BYTES: u64 = HEADER_LEN + MAX_MANIFEST_PLAINTEXT + TAG_LEN;

/// Format primitives the browser runs, without any page logic (tested on their own with Node).
pub const CORE_JS: &str = include_str!("assets/e2ee-core.js");
/// The drop page logic on top of [`CORE_JS`].
pub const PAGE_JS: &str = include_str!("assets/e2ee-page.js");

pub fn is_supported(version: u8) -> bool {
    VERSIONS.contains(&version)
}

/// Encrypted files are stored under random object names: 32 lowercase hex characters.
/// Real names live only in the encrypted manifest.
pub fn is_object_name(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn object_names_are_opaque_hex() {
        assert!(is_object_name("0123456789abcdef0123456789abcdef"));
        for name in ["", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcde", "report.pdf"] {
            assert!(!is_object_name(name), "{name}");
        }
        assert!(!is_object_name(&"a".repeat(33)));
    }

    #[test]
    fn scripts_cannot_end_their_tag_early() {
        // Both scripts are inlined into a `<script>` element.
        for script in [CORE_JS, PAGE_JS] {
            assert!(!script.to_ascii_lowercase().contains("</script"), "script contains a closing tag");
            assert!(!script.contains("<!--"), "script contains an HTML comment opener");
        }
    }
}

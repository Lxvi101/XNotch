//! File name validation, URL encoding and content-type helpers.

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};

/// Longest accepted file name, in UTF-8 bytes.
pub const MAX_NAME_BYTES: usize = 255;

/// Everything except RFC 3986 unreserved characters gets encoded.
const COMPONENT: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');

/// Validates an uploaded file name. Names are rejected rather than rewritten so
/// the client always gets back exactly the name it sent.
pub fn validate(name: &str) -> Result<(), &'static str> {
    if name.is_empty() {
        return Err("file name is empty");
    }
    if name == "." || name == ".." {
        return Err("file name is not allowed");
    }
    if name.len() > MAX_NAME_BYTES {
        return Err("file name is longer than 255 bytes");
    }
    if name.contains(['/', '\\']) {
        return Err("file name must not contain slashes");
    }
    if name.chars().any(char::is_control) {
        return Err("file name must not contain control characters");
    }
    // object_store escapes a few characters (`%`, `#`, `?`, ...) in keys; the
    // escaped form must still fit in a single file name on disk.
    if object_store::path::PathPart::from(name).as_ref().len() > MAX_NAME_BYTES {
        return Err("file name is too long");
    }
    Ok(())
}

/// Percent-encodes a value for use as a single URL path segment.
pub fn encode_segment(value: &str) -> String {
    utf8_percent_encode(value, COMPONENT).to_string()
}

/// Content-Disposition value with an ASCII fallback and an RFC 5987 `filename*`.
pub fn content_disposition(kind: &str, name: &str) -> String {
    let fallback: String =
        name.chars().map(|c| if c.is_ascii_graphic() && c != '"' && c != '\\' || c == ' ' { c } else { '_' }).collect();
    format!("{kind}; filename=\"{fallback}\"; filename*=UTF-8''{}", encode_segment(name))
}

/// Picks a content type: the extension wins, then a specific type sent by the
/// client, then `application/octet-stream`.
pub fn guess_content_type(name: &str, declared: Option<&str>) -> String {
    if let Some(mime) = mime_guess::from_path(name).first() {
        return mime.essence_str().to_owned();
    }
    declared
        .map(|d| d.split(';').next().unwrap_or("").trim().to_ascii_lowercase())
        .filter(|d| {
            let mut parts = d.split('/');
            let ok = |p: Option<&str>| {
                p.is_some_and(|p| {
                    !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"!#$&-^_.+".contains(&b))
                })
            };
            ok(parts.next()) && ok(parts.next()) && parts.next().is_none() && d != "application/octet-stream"
        })
        .unwrap_or_else(|| "application/octet-stream".into())
}

/// Types a browser may render inline without risking script execution in our origin.
pub fn is_inline_safe(content_type: &str) -> bool {
    let essence = content_type.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    match essence.split_once('/') {
        Some(("image", sub)) => matches!(
            sub,
            "png"
                | "jpeg"
                | "gif"
                | "webp"
                | "avif"
                | "bmp"
                | "x-icon"
                | "vnd.microsoft.icon"
                | "tiff"
                | "heic"
                | "heif"
        ),
        Some(("video" | "audio", _)) => true,
        _ => essence == "application/pdf" || essence == "text/plain",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_normal_names() {
        for name in ["photo.jpg", "My Report (final).pdf", ".DS_Store", "日本語.txt", "a..b", "emoji 🎉.png"] {
            assert!(validate(name).is_ok(), "{name}");
        }
        assert!(validate(&"a".repeat(255)).is_ok());
    }

    #[test]
    fn rejects_bad_names() {
        for name in ["", ".", "..", "a/b", "../x", "a\\b", "a\nb", "tab\there", "nul\0", "del\u{7f}", "c1\u{85}"] {
            assert!(validate(name).is_err(), "{name:?}");
        }
        assert!(validate(&"a".repeat(256)).is_err());
        // 86 three-byte characters = 258 bytes.
        assert!(validate(&"日".repeat(86)).is_err());
    }

    #[test]
    fn encodes_segments() {
        assert_eq!(encode_segment("a b/c?.txt"), "a%20b%2Fc%3F.txt");
        assert_eq!(encode_segment("日.txt"), "%E6%97%A5.txt");
        assert_eq!(encode_segment("x-y_z~1.png"), "x-y_z~1.png");
    }

    #[test]
    fn builds_content_disposition() {
        assert_eq!(
            content_disposition("attachment", "résumé \"v2\".pdf"),
            "attachment; filename=\"r_sum_ _v2_.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9%20%22v2%22.pdf"
        );
    }

    #[test]
    fn guesses_content_types() {
        assert_eq!(guess_content_type("a.PNG", None), "image/png");
        assert_eq!(guess_content_type("a.png", Some("text/html")), "image/png");
        assert_eq!(guess_content_type("noext", Some("text/plain; charset=utf-8")), "text/plain");
        assert_eq!(guess_content_type("noext", Some("garbage")), "application/octet-stream");
        assert_eq!(guess_content_type("noext", None), "application/octet-stream");
    }

    #[test]
    fn inline_safety() {
        for t in ["image/png", "image/jpeg", "video/mp4", "audio/mpeg", "application/pdf", "text/plain; charset=utf-8"]
        {
            assert!(is_inline_safe(t), "{t}");
        }
        for t in ["image/svg+xml", "text/html", "application/javascript", "application/xhtml+xml", "text/xml"] {
            assert!(!is_inline_safe(t), "{t}");
        }
    }
}

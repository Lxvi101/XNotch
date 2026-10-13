//! Parsing of single-range `Range: bytes=` request headers.

use std::ops::Range;

#[derive(Debug, PartialEq, Eq)]
pub enum ByteRange {
    /// No usable range: serve the whole file with 200.
    Full,
    /// Serve this half-open byte range with 206.
    Partial(Range<u64>),
    /// Respond 416.
    Unsatisfiable,
}

/// Parses a `Range` header against an object of `size` bytes.
///
/// Malformed headers, other units and multi-range requests are ignored (the
/// whole file is served), which RFC 9110 allows.
pub fn parse(header: &str, size: u64) -> ByteRange {
    let Some((unit, spec)) = header.trim().split_once('=') else {
        return ByteRange::Full;
    };
    if !unit.trim().eq_ignore_ascii_case("bytes") || spec.contains(',') {
        return ByteRange::Full;
    }
    let Some((start, end)) = spec.trim().split_once('-') else {
        return ByteRange::Full;
    };
    let (start, end) = (start.trim(), end.trim());
    let num =
        |s: &str| (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse::<u64>().ok()).flatten();

    match (start.is_empty(), end.is_empty()) {
        // bytes=-N: the last N bytes
        (true, false) => match num(end) {
            None => ByteRange::Full,
            Some(0) => ByteRange::Unsatisfiable,
            Some(_) if size == 0 => ByteRange::Unsatisfiable,
            Some(n) => ByteRange::Partial(size.saturating_sub(n)..size),
        },
        // bytes=A-
        (false, true) => match num(start) {
            None => ByteRange::Full,
            Some(a) if a >= size => ByteRange::Unsatisfiable,
            Some(a) => ByteRange::Partial(a..size),
        },
        // bytes=A-B
        (false, false) => match (num(start), num(end)) {
            (Some(a), Some(b)) if a <= b => {
                if a >= size {
                    ByteRange::Unsatisfiable
                } else {
                    ByteRange::Partial(a..b.min(size - 1) + 1)
                }
            }
            _ => ByteRange::Full,
        },
        (true, true) => ByteRange::Full,
    }
}

#[cfg(test)]
mod tests {
    use super::ByteRange::*;
    use super::*;

    #[test]
    fn bounded() {
        assert_eq!(parse("bytes=0-0", 10), Partial(0..1));
        assert_eq!(parse("bytes=2-5", 10), Partial(2..6));
        assert_eq!(parse("bytes=2-500", 10), Partial(2..10));
        assert_eq!(parse("Bytes = 0-9", 10), Partial(0..10));
        assert_eq!(parse("bytes=10-20", 10), Unsatisfiable);
    }

    #[test]
    fn open_ended_and_suffix() {
        assert_eq!(parse("bytes=4-", 10), Partial(4..10));
        assert_eq!(parse("bytes=10-", 10), Unsatisfiable);
        assert_eq!(parse("bytes=-3", 10), Partial(7..10));
        assert_eq!(parse("bytes=-30", 10), Partial(0..10));
        assert_eq!(parse("bytes=-0", 10), Unsatisfiable);
        assert_eq!(parse("bytes=-5", 0), Unsatisfiable);
        assert_eq!(parse("bytes=0-", 0), Unsatisfiable);
    }

    #[test]
    fn ignored() {
        for h in [
            "",
            "bytes",
            "bytes=",
            "bytes=-",
            "items=0-1",
            "bytes=0-1,3-4",
            "bytes=5-2",
            "bytes=a-b",
            "bytes=+1-2",
            "bytes=1-2-3",
        ] {
            assert_eq!(parse(h, 10), Full, "{h:?}");
        }
    }
}

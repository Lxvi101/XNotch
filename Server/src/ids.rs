//! Random drop identifiers.

use rand::distr::{Alphanumeric, SampleString};

/// Generates a base62 id (`[A-Za-z0-9]`) from the thread-local CSPRNG.
pub fn generate(len: usize) -> String {
    Alphanumeric.sample_string(&mut rand::rng(), len)
}

/// Cheap shape check done before touching storage. Accepts any length an
/// operator could have configured over time.
pub fn is_valid(id: &str) -> bool {
    (6..=32).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn generates_base62_of_requested_length() {
        for len in [6, 8, 12, 32] {
            let id = generate(len);
            assert_eq!(id.len(), len);
            assert!(is_valid(&id), "{id}");
        }
    }

    #[test]
    fn ids_are_unique_enough() {
        let ids: HashSet<String> = (0..10_000).map(|_| generate(8)).collect();
        assert_eq!(ids.len(), 10_000);
    }

    #[test]
    fn validates_shape() {
        assert!(is_valid("8122cbAZ"));
        assert!(!is_valid("abc"));
        assert!(!is_valid("abc-def"));
        assert!(!is_valid("../etc"));
        assert!(!is_valid("api"));
        assert!(!is_valid(&"a".repeat(33)));
    }
}

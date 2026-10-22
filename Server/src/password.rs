//! Optional drop passwords: Argon2id hashes in the metadata, and an unlock
//! cookie that carries a per-drop random key once the password was right.

use argon2::Argon2;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use axum::http::{HeaderMap, header};
use rand::Rng;
use subtle::ConstantTimeEq;

use crate::SharedState;
use crate::error::ApiError;
use crate::ids;
use crate::model::DropMeta;

/// No waiting request queue. Keep the permit inside the blocking job so a
/// disconnected/cancelled HTTP request cannot release it while Argon2 still runs.
pub async fn run_bounded<T: Send + 'static>(
    state: &SharedState,
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<T, ApiError> {
    let permit = state.password_checks.clone().try_acquire_owned().map_err(|_| ApiError::TooManyRequests(1))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        work()
    })
    .await
    .map_err(|e| ApiError::internal("password worker failed", e))
}

/// Longest accepted password, in bytes. Argon2 handles any length; this only
/// bounds the work a request can ask for.
pub const MAX_PASSWORD_BYTES: usize = 1024;
/// Length of the random key stored in the unlock cookie.
const UNLOCK_KEY_LENGTH: usize = 32;

/// Hashes with Argon2id at the crate's default (OWASP) cost. CPU-bound: call
/// from a blocking task.
pub fn hash(password: &str) -> Result<String, String> {
    let mut salt = [0u8; 16];
    rand::rng().fill_bytes(&mut salt);
    let salt = SaltString::encode_b64(&salt).map_err(|e| e.to_string())?;
    Argon2::default().hash_password(password.as_bytes(), &salt).map(|h| h.to_string()).map_err(|e| e.to_string())
}

/// CPU-bound: call from a blocking task.
pub fn verify(password: &str, hash: &str) -> bool {
    PasswordHash::new(hash).is_ok_and(|parsed| Argon2::default().verify_password(password.as_bytes(), &parsed).is_ok())
}

pub fn new_unlock_key() -> String {
    ids::generate(UNLOCK_KEY_LENGTH)
}

/// One cookie per drop, scoped to its path, so unlocking one drop says
/// nothing about another.
pub fn cookie_name(id: &str) -> String {
    format!("xn_unlock_{id}")
}

/// The `Set-Cookie` value after a correct password. It lives as long as the drop.
pub fn unlock_cookie(meta: &DropMeta, key: &str, max_age: i64, secure: bool) -> String {
    format!(
        "{}={key}; Path=/{}; Max-Age={}; HttpOnly; SameSite=Lax{}",
        cookie_name(&meta.id),
        meta.id,
        max_age.max(0),
        if secure { "; Secure" } else { "" }
    )
}

/// Whether the request may see the drop: always for drops without a
/// password, otherwise only with the drop's unlock cookie.
pub fn is_unlocked(meta: &DropMeta, headers: &HeaderMap) -> bool {
    let Some(expected) = meta.unlock_key.as_deref().filter(|_| meta.is_protected()) else {
        return !meta.is_protected();
    };
    let name = cookie_name(&meta.id);
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .any(|(k, v)| k == name && bool::from(v.as_bytes().ct_eq(expected.as_bytes())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;
    use chrono::Utc;

    #[test]
    fn hashes_and_verifies() {
        let hash = hash("correct horse").unwrap();
        assert!(hash.starts_with("$argon2id$"), "{hash}");
        assert!(verify("correct horse", &hash));
        assert!(!verify("Correct horse", &hash));
        assert!(!verify("correct horse", "not a hash"));
    }

    #[test]
    fn unlock_cookie_must_match_the_drop() {
        let mut meta = DropMeta::new("abcdefgh".into(), None, Utc::now(), 3600);
        let empty = HeaderMap::new();
        assert!(is_unlocked(&meta, &empty));

        meta.password_hash = Some("$argon2id$x".into());
        meta.unlock_key = Some("k".repeat(32));
        assert!(!is_unlocked(&meta, &empty));

        let mut headers = HeaderMap::new();
        headers.insert(
            header::COOKIE,
            HeaderValue::from_str(&format!("a=b; xn_unlock_abcdefgh={}", "k".repeat(32))).unwrap(),
        );
        assert!(is_unlocked(&meta, &headers));

        let mut wrong = HeaderMap::new();
        wrong.insert(header::COOKIE, HeaderValue::from_static("xn_unlock_abcdefgh=nope"));
        assert!(!is_unlocked(&meta, &wrong));

        let cookie = unlock_cookie(&meta, "key", 60, true);
        assert_eq!(cookie, "xn_unlock_abcdefgh=key; Path=/abcdefgh; Max-Age=60; HttpOnly; SameSite=Lax; Secure");
    }
}

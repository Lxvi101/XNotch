//! Metadata as stored in `drops/{id}/meta.json` and `relay/rooms/{room}`.

use chrono::{DateTime, Duration, SubsecRound, Utc};
use serde::{Deserialize, Serialize};

use crate::config::MIN_EXPIRY;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DropMeta {
    pub id: String,
    pub title: Option<String>,
    #[serde(with = "rfc3339")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "rfc3339")]
    pub expires_at: DateTime<Utc>,
    #[serde(default)]
    pub files: Vec<FileMeta>,
    /// Argon2id PHC string when the drop needs a password.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password_hash: Option<String>,
    /// Random key a browser gets as a cookie once it knows the password.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unlock_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FileMeta {
    pub name: String,
    pub size: u64,
    pub content_type: String,
}

impl DropMeta {
    pub fn new(id: String, title: Option<String>, now: DateTime<Utc>, expires_in: u64) -> Self {
        let created_at = now.trunc_subsecs(0);
        Self {
            id,
            title,
            created_at,
            expires_at: created_at + Duration::seconds(expires_in as i64),
            files: Vec::new(),
            password_hash: None,
            unlock_key: None,
        }
    }

    pub fn is_protected(&self) -> bool {
        self.password_hash.is_some()
    }

    pub fn is_expired(&self, now: DateTime<Utc>) -> bool {
        now >= self.expires_at
    }

    pub fn total_size(&self) -> u64 {
        self.files.iter().map(|f| f.size).sum()
    }

    pub fn file(&self, name: &str) -> Option<&FileMeta> {
        self.files.iter().find(|f| f.name == name)
    }

    /// Adds a file or replaces the entry with the same name.
    pub fn upsert_file(&mut self, file: FileMeta) {
        match self.files.iter_mut().find(|f| f.name == file.name) {
            Some(existing) => *existing = file,
            None => self.files.push(file),
        }
    }
}

/// A registered relay room, stored at `relay/rooms/{room}`. The room id is the key.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct RelayRoom {
    #[serde(with = "rfc3339")]
    pub created_at: DateTime<Utc>,
}

/// Effective lifetime of a new drop: the default when unset, clamped to
/// `[MIN_EXPIRY, max]`.
pub fn clamp_expiry(requested: Option<i64>, default: u64, max: u64) -> u64 {
    match requested {
        None => default.clamp(MIN_EXPIRY, max),
        Some(secs) => (secs.max(0) as u64).clamp(MIN_EXPIRY, max),
    }
}

/// Formats timestamps as RFC 3339 UTC with whole seconds (`2026-01-02T03:04:05Z`),
/// which Foundation's `ISO8601DateFormatter` parses with its default options.
pub fn format_time(t: &DateTime<Utc>) -> String {
    t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

pub mod rfc3339 {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(t: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&super::format_time(t))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let raw = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&raw).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_expiry() {
        let (default, max) = (86_400, 30 * 86_400);
        assert_eq!(clamp_expiry(None, default, max), 86_400);
        assert_eq!(clamp_expiry(Some(3600), default, max), 3600);
        assert_eq!(clamp_expiry(Some(1), default, max), 60);
        assert_eq!(clamp_expiry(Some(0), default, max), 60);
        assert_eq!(clamp_expiry(Some(-5), default, max), 60);
        assert_eq!(clamp_expiry(Some(i64::MAX), default, max), max);
        assert_eq!(clamp_expiry(None, 10 * max, max), max);
    }

    #[test]
    fn round_trips_metadata() {
        let now = DateTime::parse_from_rfc3339("2026-10-13T10:00:00.750Z").unwrap().with_timezone(&Utc);
        let mut meta = DropMeta::new("abcdefgh".into(), Some("Hi".into()), now, 3600);
        meta.upsert_file(FileMeta { name: "a.txt".into(), size: 1, content_type: "text/plain".into() });
        meta.upsert_file(FileMeta { name: "a.txt".into(), size: 2, content_type: "text/plain".into() });
        assert_eq!(meta.files.len(), 1);
        assert_eq!(meta.total_size(), 2);

        let json = serde_json::to_string(&meta).unwrap();
        assert!(json.contains("\"created_at\":\"2026-10-13T10:00:00Z\""), "{json}");
        assert!(json.contains("\"expires_at\":\"2026-10-13T11:00:00Z\""), "{json}");
        assert_eq!(serde_json::from_str::<DropMeta>(&json).unwrap(), meta);
        assert!(!meta.is_expired(now));
        assert!(meta.is_expired(meta.expires_at));
    }
}

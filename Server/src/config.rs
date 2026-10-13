//! Configuration loaded from environment variables.

use std::fmt;
use std::path::PathBuf;
use std::time::Duration;

const MIB: usize = 1024 * 1024;
const GIB: u64 = 1024 * 1024 * 1024;
/// Upper bound for `RELAY_MAX_MESSAGE`; every message is buffered whole in memory.
const MAX_RELAY_MESSAGE: usize = 256 * MIB;

/// Lowest expiry a drop can have, in seconds.
pub const MIN_EXPIRY: u64 = 60;
/// Upper bound for `MAX_EXPIRY` (ten years) so date arithmetic can never overflow.
const MAX_EXPIRY_LIMIT: u64 = 10 * 365 * 86_400;

#[derive(Clone, Debug)]
pub struct Config {
    /// Base URL for links, without a trailing slash.
    pub public_url: String,
    pub api_token: String,
    pub port: u16,
    pub site_name: String,
    pub storage: StorageConfig,
    pub max_file_size: u64,
    pub default_expiry: u64,
    pub max_expiry: u64,
    pub id_length: usize,
    pub relay: RelayConfig,
}

/// Settings for the WebSocket relay between the iPhone and the Mac.
#[derive(Clone, Debug)]
pub struct RelayConfig {
    pub enabled: bool,
    /// Largest WebSocket message in bytes, in either direction.
    pub max_message: usize,
    /// Concurrent phone connections (waiting for or paired with a Mac).
    pub max_pairs: usize,
    /// Waiting Mac sockets across all rooms.
    pub max_waiting: usize,
    /// Waiting Mac sockets per room; a new one beyond this replaces the oldest.
    pub max_waiting_per_room: usize,
    /// How long a phone waits for a Mac before it is turned away.
    pub phone_wait: Duration,
    /// A pair is closed after this long without a data message in either direction.
    pub idle_timeout: Duration,
    /// Interval of server-side WebSocket pings. Not configurable from the environment.
    pub ping_interval: Duration,
}

impl RelayConfig {
    fn from_env(var: &impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let enabled = match var("RELAY").as_deref().map(str::to_ascii_lowercase).as_deref() {
            None | Some("on" | "true" | "1" | "yes") => true,
            Some("off" | "false" | "0" | "no") => false,
            Some(other) => return Err(format!("RELAY must be `on` or `off`, got `{other}`")),
        };
        let max_message = parse_or(var, "RELAY_MAX_MESSAGE", 8 * MIB)?;
        if !(1024..=MAX_RELAY_MESSAGE).contains(&max_message) {
            return Err(format!("RELAY_MAX_MESSAGE must be between 1024 and {MAX_RELAY_MESSAGE} bytes"));
        }
        let max_pairs = parse_or(var, "RELAY_MAX_PAIRS", 64usize)?;
        let max_waiting = parse_or(var, "RELAY_MAX_WAITING", 256usize)?;
        if max_pairs == 0 || max_waiting == 0 {
            return Err("RELAY_MAX_PAIRS and RELAY_MAX_WAITING must be at least 1".into());
        }
        let phone_wait = parse_or(var, "RELAY_PHONE_WAIT", 10u64)?;
        if phone_wait > 300 {
            return Err("RELAY_PHONE_WAIT must be at most 300 seconds".into());
        }
        let idle_timeout = parse_or(var, "RELAY_IDLE_TIMEOUT", 1800u64)?;
        if idle_timeout == 0 {
            return Err("RELAY_IDLE_TIMEOUT must be at least 1 second".into());
        }
        Ok(Self {
            enabled,
            max_message,
            max_pairs,
            max_waiting,
            max_waiting_per_room: 8,
            phone_wait: Duration::from_secs(phone_wait),
            idle_timeout: Duration::from_secs(idle_timeout),
            ping_interval: Duration::from_secs(20),
        })
    }
}

#[derive(Clone)]
pub enum StorageConfig {
    Local {
        data_dir: PathBuf,
    },
    S3 {
        bucket: String,
        endpoint: Option<String>,
        region: String,
        access_key_id: Option<String>,
        secret_access_key: Option<String>,
        prefix: Option<String>,
        virtual_hosted_style: bool,
    },
}

// Hand-written so secrets never end up in logs.
impl fmt::Debug for StorageConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Local { data_dir } => f.debug_struct("Local").field("data_dir", data_dir).finish(),
            Self::S3 { bucket, endpoint, region, prefix, virtual_hosted_style, .. } => f
                .debug_struct("S3")
                .field("bucket", bucket)
                .field("endpoint", endpoint)
                .field("region", region)
                .field("prefix", prefix)
                .field("virtual_hosted_style", virtual_hosted_style)
                .finish_non_exhaustive(),
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Self::from_lookup(|key| std::env::var(key).ok())
    }

    /// Builds the config from any key lookup, which keeps it testable.
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        // Treat empty values like unset ones, which is what compose files produce.
        let var = |key: &str| get(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());

        let public_url = var("PUBLIC_URL").ok_or("PUBLIC_URL is required")?;
        if !(public_url.starts_with("https://") || public_url.starts_with("http://")) {
            return Err("PUBLIC_URL must start with http:// or https://".into());
        }
        let public_url = public_url.trim_end_matches('/').to_owned();

        let api_token = var("API_TOKEN").ok_or("API_TOKEN is required")?;
        if api_token.len() < 16 {
            return Err("API_TOKEN must be at least 16 characters long".into());
        }

        let port = parse_or(&var, "PORT", 8080u16)?;
        let site_name = var("SITE_NAME").unwrap_or_else(|| "XNotch Cloud".into());

        let storage = match var("STORAGE").as_deref().map(str::to_ascii_lowercase).as_deref() {
            None | Some("local") => {
                StorageConfig::Local { data_dir: PathBuf::from(var("DATA_DIR").unwrap_or_else(|| "/data".into())) }
            }
            Some("s3") => StorageConfig::S3 {
                bucket: var("S3_BUCKET").ok_or("S3_BUCKET is required when STORAGE=s3")?,
                endpoint: var("S3_ENDPOINT").map(|e| e.trim_end_matches('/').to_owned()),
                region: var("S3_REGION").unwrap_or_else(|| "us-east-1".into()),
                access_key_id: var("S3_ACCESS_KEY_ID"),
                secret_access_key: var("S3_SECRET_ACCESS_KEY"),
                prefix: var("S3_PREFIX").map(|p| p.trim_matches('/').to_owned()).filter(|p| !p.is_empty()),
                virtual_hosted_style: parse_or(&var, "S3_VIRTUAL_HOSTED_STYLE", false)?,
            },
            Some(other) => return Err(format!("STORAGE must be `local` or `s3`, got `{other}`")),
        };

        let max_file_size = parse_or(&var, "MAX_FILE_SIZE", 5 * GIB)?;
        let max_expiry = parse_or(&var, "MAX_EXPIRY", 30 * 86_400u64)?;
        if !(MIN_EXPIRY..=MAX_EXPIRY_LIMIT).contains(&max_expiry) {
            return Err(format!("MAX_EXPIRY must be between {MIN_EXPIRY} and {MAX_EXPIRY_LIMIT} seconds"));
        }
        let default_expiry = parse_or(&var, "DEFAULT_EXPIRY", 86_400u64)?.clamp(MIN_EXPIRY, max_expiry);

        let id_length = parse_or(&var, "ID_LENGTH", 8usize)?;
        if !(6..=32).contains(&id_length) {
            return Err("ID_LENGTH must be between 6 and 32".into());
        }

        let relay = RelayConfig::from_env(&var)?;

        Ok(Self {
            public_url,
            api_token,
            port,
            site_name,
            storage,
            max_file_size,
            default_expiry,
            max_expiry,
            id_length,
            relay,
        })
    }
}

fn parse_or<T: std::str::FromStr>(var: &impl Fn(&str) -> Option<String>, key: &str, default: T) -> Result<T, String> {
    match var(key) {
        None => Ok(default),
        Some(raw) => raw.parse().map_err(|_| format!("{key} has an invalid value: `{raw}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn load(pairs: &[(&str, &str)]) -> Result<Config, String> {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        Config::from_lookup(|k| map.get(k).cloned())
    }

    const BASE: [(&str, &str); 2] = [("PUBLIC_URL", "https://drop.example.com/"), ("API_TOKEN", "0123456789abcdef")];

    #[test]
    fn defaults() {
        let c = load(&BASE).unwrap();
        assert_eq!(c.public_url, "https://drop.example.com");
        assert_eq!(c.port, 8080);
        assert_eq!(c.site_name, "XNotch Cloud");
        assert_eq!(c.max_file_size, 5 * GIB);
        assert_eq!(c.default_expiry, 86_400);
        assert_eq!(c.max_expiry, 30 * 86_400);
        assert_eq!(c.id_length, 8);
        assert!(matches!(c.storage, StorageConfig::Local { .. }));
        let r = &c.relay;
        assert!(r.enabled);
        assert_eq!(r.max_message, 8 * MIB);
        assert_eq!((r.max_pairs, r.max_waiting, r.max_waiting_per_room), (64, 256, 8));
        assert_eq!(r.phone_wait, Duration::from_secs(10));
        assert_eq!(r.idle_timeout, Duration::from_secs(1800));
        assert_eq!(r.ping_interval, Duration::from_secs(20));
    }

    #[test]
    fn relay_settings() {
        let with = |pairs: &[(&'static str, &'static str)]| {
            let mut v = BASE.to_vec();
            v.extend_from_slice(pairs);
            load(&v)
        };
        assert!(!with(&[("RELAY", "off")]).unwrap().relay.enabled);
        assert!(!with(&[("RELAY", "OFF")]).unwrap().relay.enabled);
        assert!(with(&[("RELAY", "on")]).unwrap().relay.enabled);
        assert!(with(&[("RELAY", "maybe")]).is_err());
        let c =
            with(&[("RELAY_MAX_MESSAGE", "65536"), ("RELAY_PHONE_WAIT", "0"), ("RELAY_IDLE_TIMEOUT", "60")]).unwrap();
        assert_eq!(c.relay.max_message, 65536);
        assert_eq!(c.relay.phone_wait, Duration::ZERO);
        assert_eq!(c.relay.idle_timeout, Duration::from_secs(60));
        assert!(with(&[("RELAY_MAX_MESSAGE", "10")]).is_err());
        assert!(with(&[("RELAY_MAX_PAIRS", "0")]).is_err());
        assert!(with(&[("RELAY_IDLE_TIMEOUT", "0")]).is_err());
        assert!(with(&[("RELAY_PHONE_WAIT", "-1")]).is_err());
    }

    #[test]
    fn rejects_short_or_missing_token() {
        assert!(load(&[BASE[0]]).is_err());
        assert!(load(&[BASE[0], ("API_TOKEN", "short")]).is_err());
        assert!(load(&[BASE[0], ("API_TOKEN", "   ")]).is_err());
    }

    #[test]
    fn rejects_bad_values() {
        let mut v = BASE.to_vec();
        v.push(("ID_LENGTH", "5"));
        assert!(load(&v).is_err());
        let mut v = BASE.to_vec();
        v.push(("STORAGE", "s3"));
        assert!(load(&v).is_err(), "s3 needs a bucket");
        let mut v = BASE.to_vec();
        v.push(("PORT", "abc"));
        assert!(load(&v).is_err());
    }
}

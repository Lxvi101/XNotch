//! Bounded process-local admission control. No request/body/stream is retained here.

use std::collections::{BTreeSet, HashMap};
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, Request, State};
use axum::http::{HeaderMap, Method};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use ipnet::IpNet;

use crate::SharedState;
use crate::error::ApiError;

const TOKEN: u128 = 60_000_000_000; // one token, in nanoseconds * requests/minute
const MAX_FORWARDED_BYTES: usize = 2048;
const MAX_HOPS: usize = 32;

#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub per_minute: u32,
    pub burst: u32,
}

#[derive(Clone, Debug)]
pub struct RateLimitConfig {
    /// Public requests, password posts, management API, relay upgrades.
    pub budgets: [Budget; 4],
    pub max_clients: usize,
    pub idle_ttl: Duration,
    pub trusted_proxies: Vec<IpNet>,
    pub password_concurrency: usize,
}

impl RateLimitConfig {
    pub(crate) fn from_env(var: &impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let number = |key: &str, default: u32, max: u32| -> Result<u32, String> {
            let n = match var(key) {
                Some(raw) => raw.parse::<u32>().map_err(|_| format!("{key} must be an integer"))?,
                None => default,
            };
            if !(1..=max).contains(&n) {
                return Err(format!("{key} must be between 1 and {max}"));
            }
            Ok(n)
        };
        let mut budgets = [Budget { per_minute: 1, burst: 1 }; 4];
        for (budget, (name, rate, burst)) in
            budgets.iter_mut().zip([("PUBLIC", 120, 60), ("PASSWORD", 10, 5), ("API", 120, 60), ("RELAY", 30, 20)])
        {
            budget.per_minute = number(&format!("RATE_LIMIT_{name}_PER_MINUTE"), rate, 1_000_000)?;
            budget.burst = number(&format!("RATE_LIMIT_{name}_BURST"), burst, 1_000_000)?;
        }
        let idle_ttl = Duration::from_secs(number("RATE_LIMIT_IDLE_SECONDS", 900, 86_400)? as u64);
        // Forgetting an entry must never give it tokens earlier than normal refill.
        if budgets.iter().any(|b| u64::from(b.burst) * 60 > u64::from(b.per_minute) * idle_ttl.as_secs()) {
            return Err("RATE_LIMIT_IDLE_SECONDS must cover the full refill time of every bucket".into());
        }
        let raw = var("TRUSTED_PROXIES").unwrap_or_default();
        if raw.len() > 8192 {
            return Err("TRUSTED_PROXIES is too long".into());
        }
        let mut trusted_proxies = Vec::new();
        if !raw.is_empty() {
            for value in raw.split(',') {
                let value = value.trim();
                let net = value
                    .parse::<IpNet>()
                    .or_else(|_| value.parse::<IpAddr>().map(IpNet::from))
                    .map_err(|_| format!("TRUSTED_PROXIES requires IP addresses or CIDRs, got `{value}`"))?;
                if net.prefix_len() == 0 || trusted_proxies.len() >= 128 {
                    return Err("TRUSTED_PROXIES cannot trust /0 or contain more than 128 entries".into());
                }
                trusted_proxies.push(net);
            }
        }
        Ok(Self {
            budgets,
            max_clients: number("RATE_LIMIT_MAX_CLIENTS", 10_000, 1_000_000)? as usize,
            idle_ttl,
            trusted_proxies,
            password_concurrency: number("PASSWORD_CONCURRENCY", 4, 64)? as usize,
        })
    }

    fn trusted(&self, ip: IpAddr) -> bool {
        self.trusted_proxies.iter().any(|net| net.contains(&ip))
    }

    /// Walk right to left, trusting a hop only if its immediate sender is trusted.
    /// Malformed/oversized chains fall back to the socket peer, never the leftmost value.
    fn client_ip(&self, peer: IpAddr, headers: &HeaderMap) -> IpAddr {
        let peer = peer.to_canonical();
        if !self.trusted(peer) {
            return peer;
        }
        let mut hops = Vec::new();
        let mut bytes = 0usize;
        for value in headers.get_all("x-forwarded-for") {
            bytes = bytes.saturating_add(value.len());
            if bytes > MAX_FORWARDED_BYTES {
                return peer;
            }
            let Ok(value) = value.to_str() else { return peer };
            for hop in value.split(',') {
                if hops.len() == MAX_HOPS {
                    return peer;
                }
                let Ok(ip) = hop.trim().parse::<IpAddr>() else { return peer };
                hops.push(ip.to_canonical());
            }
        }
        let mut client = peer;
        for hop in hops.into_iter().rev() {
            if !self.trusted(client) {
                break;
            }
            client = hop;
        }
        client
    }
}

#[derive(Clone, Copy)]
enum Class {
    Public = 0,
    Password = 1,
    Api = 2,
    Relay = 3,
}

fn classify(request: &Request) -> Class {
    let path = request.uri().path();
    if path == "/api" || path.starts_with("/api/") {
        if path.starts_with("/api/relay/rooms/") && path.ends_with("/connect") { Class::Relay } else { Class::Api }
    } else if request.method() == Method::POST {
        Class::Password
    } else {
        Class::Public
    }
}

struct Bucket {
    credit: u128,
    updated: Instant,
}

impl Bucket {
    fn refill(&mut self, budget: Budget, now: Instant) {
        let added = now.saturating_duration_since(self.updated).as_nanos().saturating_mul(budget.per_minute.into());
        self.credit = self.credit.saturating_add(added).min(u128::from(budget.burst) * TOKEN);
        self.updated = now;
    }

    fn retry_after(&self, budget: Budget) -> u64 {
        TOKEN.saturating_sub(self.credit).div_ceil(u128::from(budget.per_minute) * 1_000_000_000) as u64
    }
}

struct Client {
    buckets: [Bucket; 4],
    seen: Instant,
}

#[derive(Default)]
struct Table {
    clients: HashMap<IpAddr, Client>,
    // Exactly one entry per client; unlike lazy expiry queues this cannot grow on hits.
    oldest: BTreeSet<(Instant, IpAddr)>,
}

pub struct RateLimiter {
    config: RateLimitConfig,
    table: Mutex<Table>,
}

impl RateLimiter {
    pub fn new(config: RateLimitConfig) -> Self {
        Self { config, table: Mutex::new(Table::default()) }
    }

    fn check(&self, ip: IpAddr, class: Class, now: Instant) -> Result<(), u64> {
        // Poisoning fails closed. The lock never covers IO or an await.
        let mut table = self.table.lock().map_err(|_| 1u64)?;
        // Bound cleanup work per request, including after a long idle period.
        for _ in 0..64 {
            let Some(&(seen, ip)) = table.oldest.first() else { break };
            if now.saturating_duration_since(seen) < self.config.idle_ttl {
                break;
            }
            table.oldest.remove(&(seen, ip));
            table.clients.remove(&ip);
        }
        if !table.clients.contains_key(&ip) {
            if table.clients.len() >= self.config.max_clients {
                // Do not evict live buckets: IP churn must not reset an attacker's limit.
                let retry = table
                    .oldest
                    .first()
                    .map(|(seen, _)| {
                        self.config
                            .idle_ttl
                            .saturating_sub(now.saturating_duration_since(*seen))
                            .as_secs()
                            .saturating_add(1)
                    })
                    .unwrap_or(1);
                return Err(retry.max(1));
            }
            let buckets = self.config.budgets.map(|b| Bucket { credit: u128::from(b.burst) * TOKEN, updated: now });
            table.clients.insert(ip, Client { buckets, seen: now });
        }
        let client = table.clients.get_mut(&ip).expect("client inserted above");
        let previous = client.seen;
        // Requests can capture timestamps in one order and acquire the mutex in
        // another. Never move a client's refill/expiry clock backwards.
        let now = now.max(previous);
        client.seen = now;
        let index = class as usize;
        let budget = self.config.budgets[index];
        client.buckets[index].refill(budget, now);
        let mut retry = client.buckets[index].retry_after(budget);
        // Password attempts also consume the public budget, before body/storage/Argon2 work.
        if matches!(class, Class::Password) {
            client.buckets[0].refill(self.config.budgets[0], now);
            retry = retry.max(client.buckets[0].retry_after(self.config.budgets[0]));
        }
        if retry == 0 {
            client.buckets[index].credit -= TOKEN;
            if matches!(class, Class::Password) {
                client.buckets[0].credit -= TOKEN;
            }
        }
        table.oldest.remove(&(previous, ip));
        table.oldest.insert((now, ip));
        if retry == 0 { Ok(()) } else { Err(retry) }
    }
}

/// Runs once before authentication, body extraction, storage access and upgrade.
/// Health is registered outside this layer. No limits are applied to an admitted stream.
pub async fn admit(State(state): State<SharedState>, request: Request, next: Next) -> Response {
    let Some(ConnectInfo(peer)) = request.extensions().get::<ConnectInfo<SocketAddr>>() else {
        // Embedders must supply ConnectInfo, just like the production listener.
        return ApiError::TooManyRequests(1).into_response();
    };
    let ip = state.config.rate_limit.client_ip(peer.ip(), request.headers());
    match state.rate_limiter.check(ip, classify(&request), Instant::now()) {
        Ok(()) => next.run(request).await,
        Err(seconds) => ApiError::TooManyRequests(seconds).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> RateLimitConfig {
        RateLimitConfig::from_env(&|_| None).unwrap()
    }

    fn ip(n: u8) -> IpAddr {
        IpAddr::from([192, 0, 2, n])
    }

    #[test]
    fn exact_burst_refill_and_client_and_class_isolation() {
        let mut config = config();
        config.budgets[0] = Budget { per_minute: 60, burst: 2 };
        let limiter = RateLimiter::new(config);
        let start = Instant::now();
        assert_eq!(limiter.check(ip(1), Class::Public, start), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, start), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, start), Err(1));
        assert_eq!(limiter.check(ip(2), Class::Public, start), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Api, start), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, start + Duration::from_millis(999)), Err(1));
        assert_eq!(limiter.check(ip(1), Class::Public, start + Duration::from_secs(1)), Ok(()));
        let later = start + Duration::from_secs(100);
        assert_eq!(limiter.check(ip(1), Class::Public, later), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, later), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, later), Err(1));
    }

    #[test]
    fn saturation_never_evicts_live_buckets_and_expiry_reclaims_capacity() {
        let mut config = config();
        config.max_clients = 1;
        config.idle_ttl = Duration::from_secs(60);
        config.budgets[0] = Budget { per_minute: 1, burst: 1 };
        let limiter = RateLimiter::new(config);
        let start = Instant::now();
        assert_eq!(limiter.check(ip(1), Class::Public, start), Ok(()));
        assert!(limiter.check(ip(2), Class::Public, start).is_err());
        assert_eq!(limiter.check(ip(1), Class::Public, start), Err(60));
        assert_eq!(limiter.check(ip(2), Class::Public, start + Duration::from_secs(60)), Ok(()));
        assert!(limiter.check(ip(1), Class::Public, start + Duration::from_secs(60)).is_err());
        let table = limiter.table.lock().unwrap();
        assert_eq!(table.clients.len(), 1);
        assert_eq!(table.oldest.len(), 1);
    }

    #[test]
    fn out_of_order_concurrent_timestamps_cannot_mint_refill_credit() {
        let mut config = config();
        config.budgets[0] = Budget { per_minute: 60, burst: 1 };
        let limiter = RateLimiter::new(config);
        let start = Instant::now();
        assert_eq!(limiter.check(ip(1), Class::Public, start), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, start + Duration::from_secs(1)), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Public, start), Err(1));
        assert_eq!(limiter.check(ip(1), Class::Public, start + Duration::from_secs(1)), Err(1));
        assert_eq!(limiter.check(ip(1), Class::Public, start + Duration::from_secs(2)), Ok(()));
    }

    #[test]
    fn password_admission_checks_both_budgets_without_partial_spending() {
        let mut config = config();
        config.budgets[0] = Budget { per_minute: 1, burst: 1 };
        config.budgets[1] = Budget { per_minute: 1, burst: 2 };
        let limiter = RateLimiter::new(config);
        let start = Instant::now();
        assert_eq!(limiter.check(ip(1), Class::Password, start), Ok(()));
        assert_eq!(limiter.check(ip(1), Class::Password, start), Err(60));
        assert_eq!(limiter.check(ip(1), Class::Public, start), Err(60));
        let table = limiter.table.lock().unwrap();
        assert_eq!(table.clients[&ip(1)].buckets[1].credit, TOKEN);
    }

    #[test]
    fn poisoned_state_fails_closed() {
        let limiter = RateLimiter::new(config());
        let _ = std::panic::catch_unwind(|| {
            let _guard = limiter.table.lock().unwrap();
            panic!("test poisoned limiter");
        });
        assert_eq!(limiter.check(ip(1), Class::Public, Instant::now()), Err(1));
    }

    #[test]
    fn hit_and_rejection_expiry_index_stays_bounded() {
        let limiter = RateLimiter::new(config());
        let start = Instant::now();
        for n in 0..10_000 {
            let _ = limiter.check(ip(1), Class::Public, start + Duration::from_millis(n));
        }
        let table = limiter.table.lock().unwrap();
        assert_eq!(table.clients.len(), 1);
        assert_eq!(table.oldest.len(), 1);
    }

    #[test]
    fn untrusted_peer_cannot_spoof_identity_and_mapped_ipv4_is_canonical() {
        let config = config();
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", "198.51.100.9".parse().unwrap());
        headers.insert("forwarded", "for=198.51.100.10".parse().unwrap());
        headers.insert("x-real-ip", "198.51.100.11".parse().unwrap());
        assert_eq!(config.client_ip(ip(1), &headers), ip(1));
        assert_eq!(config.client_ip("::ffff:192.0.2.1".parse().unwrap(), &headers), ip(1));
    }

    #[test]
    fn trusted_chain_stops_at_first_untrusted_hop_and_rejects_invalid_chains() {
        let config =
            RateLimitConfig::from_env(&|key| (key == "TRUSTED_PROXIES").then(|| "10.0.0.0/24,2001:db8:1::/64".into()))
                .unwrap();
        let peer = "10.0.0.2".parse().unwrap();
        let mut headers = HeaderMap::new();
        headers.append("x-forwarded-for", "203.0.113.250, 198.51.100.9".parse().unwrap());
        headers.append("x-forwarded-for", "10.0.0.3".parse().unwrap());
        assert_eq!(config.client_ip(peer, &headers), "198.51.100.9".parse::<IpAddr>().unwrap());
        for bad in ["unknown, 10.0.0.3", "198.51.100.9:1234", "", "192.0.2.1,", "garbage"] {
            headers.insert("x-forwarded-for", bad.parse().unwrap());
            assert_eq!(config.client_ip(peer, &headers), peer);
        }
        headers.insert("x-forwarded-for", "2001:db8:2::1, 2001:db8:1::2".parse().unwrap());
        assert_eq!(
            config.client_ip("2001:db8:1::3".parse().unwrap(), &headers),
            "2001:db8:2::1".parse::<IpAddr>().unwrap()
        );
        headers.insert("x-forwarded-for", "192.0.2.1,".repeat(1000).parse().unwrap());
        assert_eq!(config.client_ip(peer, &headers), peer);
        headers.insert(
            "x-forwarded-for",
            std::iter::repeat_n("192.0.2.1", 33).collect::<Vec<_>>().join(",").parse().unwrap(),
        );
        assert_eq!(config.client_ip(peer, &headers), peer);
        headers.remove("x-forwarded-for");
        assert_eq!(config.client_ip(peer, &headers), peer);
    }

    #[test]
    fn rejects_invalid_or_unsafe_configuration() {
        for (key, value) in [
            ("TRUSTED_PROXIES", "example.com"),
            ("TRUSTED_PROXIES", "0.0.0.0/0"),
            ("TRUSTED_PROXIES", "::/0"),
            ("TRUSTED_PROXIES", "127.0.0.1,"),
            ("TRUSTED_PROXIES", "10.0.0.0/33"),
            ("RATE_LIMIT_MAX_CLIENTS", "0"),
            ("RATE_LIMIT_PUBLIC_PER_MINUTE", "-1"),
            ("RATE_LIMIT_API_BURST", "1000001"),
            ("RATE_LIMIT_IDLE_SECONDS", "1"),
            ("PASSWORD_CONCURRENCY", "65"),
        ] {
            assert!(RateLimitConfig::from_env(&|k| (k == key).then(|| value.into())).is_err(), "{key}={value}");
        }
    }
}

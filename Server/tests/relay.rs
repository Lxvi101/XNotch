//! End-to-end tests of the WebSocket relay over a real listener.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use futures_util::{SinkExt, StreamExt};
use http_body_util::BodyExt;
use serde_json::Value;
use tempfile::TempDir;
use tokio::net::TcpStream;
use tokio::time::{Instant, sleep, timeout};
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use tower::ServiceExt;
use xnotch_cloud::config::Config;
use xnotch_cloud::storage::Storage;
use xnotch_cloud::{AppState, SharedState, app};

const TOKEN: &str = "test-token-0123456789";
const WAIT: Duration = Duration::from_secs(5);

type Client = WebSocketStream<MaybeTlsStream<TcpStream>>;

fn room(seed: char) -> String {
    format!("{}{}", "0123456789abcdef".repeat(3), seed.to_string().repeat(16))
}

struct Server {
    addr: SocketAddr,
    app: Router,
    state: SharedState,
    dir: TempDir,
}

fn config(dir: &TempDir, extra: &[(&str, &str)]) -> Config {
    let mut env: HashMap<String, String> = HashMap::from([
        ("PUBLIC_URL".into(), "https://drop.example.com".into()),
        ("API_TOKEN".into(), TOKEN.into()),
        ("DATA_DIR".into(), dir.path().to_string_lossy().into_owned()),
    ]);
    env.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    Config::from_lookup(|k| env.get(k).cloned()).unwrap()
}

async fn start_in(dir: TempDir, extra: &[(&str, &str)], tweak: impl FnOnce(&mut Config)) -> Server {
    let mut config = config(&dir, extra);
    tweak(&mut config);
    let storage = Storage::from_config(&config.storage).unwrap();
    let state = Arc::new(AppState::new(config, storage));
    state.relay.load(&state.storage).await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = app(state.clone());
    tokio::spawn(async move {
        axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>()).await.unwrap()
    });
    Server { addr, app: app(state.clone()), state, dir }
}

async fn start(extra: &[(&str, &str)], tweak: impl FnOnce(&mut Config)) -> Server {
    start_in(TempDir::new().unwrap(), extra, tweak).await
}

impl Server {
    async fn request(&self, method: Method, uri: &str, token: Option<&str>) -> (StatusCode, Value) {
        let mut request = Request::builder().method(method).uri(uri);
        if let Some(token) = token {
            request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }
        let mut request = request.body(Body::empty()).unwrap();
        request.extensions_mut().insert(axum::extract::ConnectInfo("127.0.0.1:12345".parse::<SocketAddr>().unwrap()));
        let response = self.app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let body = response.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
    }

    async fn register(&self, room: &str) -> StatusCode {
        self.request(Method::PUT, &format!("/api/relay/rooms/{room}"), Some(TOKEN)).await.0
    }

    async fn unregister(&self, room: &str) -> StatusCode {
        self.request(Method::DELETE, &format!("/api/relay/rooms/{room}"), Some(TOKEN)).await.0
    }

    fn url(&self, room: &str, role: &str) -> String {
        format!("ws://{}/api/relay/rooms/{room}/connect?role={role}", self.addr)
    }

    async fn connect(&self, room: &str, role: &str) -> Client {
        let (client, response) = tokio_tungstenite::connect_async(self.url(room, role)).await.unwrap();
        assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
        client
    }

    /// Connects a Mac and waits until it sits in the pool.
    async fn connect_mac(&self, room: &str) -> Client {
        let before = self.state.relay.waiting_macs(room);
        let client = self.connect(room, "mac").await;
        self.wait_for_macs(room, before + 1).await;
        client
    }

    async fn wait_for_macs(&self, room: &str, count: usize) {
        let deadline = Instant::now() + WAIT;
        while self.state.relay.waiting_macs(room) != count {
            assert!(Instant::now() < deadline, "expected {count} waiting macs");
            sleep(Duration::from_millis(5)).await;
        }
    }

    /// Status of a connect attempt that is refused before the upgrade.
    async fn refused(&self, url: String) -> (StatusCode, Value) {
        match tokio_tungstenite::connect_async(url).await {
            Err(tungstenite::Error::Http(response)) => {
                let body = response.body().as_deref().map(serde_json::from_slice).and_then(Result::ok);
                (response.status(), body.unwrap_or(Value::Null))
            }
            other => panic!("expected an HTTP error, got {:?}", other.map(|(_, r)| r.status())),
        }
    }

    /// Connects a Mac and a phone and checks they are paired.
    async fn pair(&self, room: &str) -> (Client, Client) {
        let mut mac = self.connect_mac(room).await;
        let mut phone = self.connect(room, "phone").await;
        phone.send(Message::binary(b"hello mac".to_vec())).await.unwrap();
        assert_eq!(next_data(&mut mac).await, Message::binary(b"hello mac".to_vec()));
        (mac, phone)
    }
}

/// Next data message, skipping pings and pongs.
async fn next_data(client: &mut Client) -> Message {
    loop {
        let message = timeout(WAIT, client.next()).await.expect("timed out waiting for a message");
        match message {
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
            Some(Ok(message)) => return message,
            other => panic!("expected a message, got {other:?}"),
        }
    }
}

/// Reads until the server closes the socket and returns the close code and reason.
async fn closed(client: &mut Client) -> (u16, String) {
    loop {
        let message = timeout(WAIT, client.next()).await.expect("timed out waiting for close");
        match message {
            Some(Ok(Message::Close(Some(frame)))) => return (frame.code.into(), frame.reason.to_string()),
            Some(Ok(Message::Close(None))) => return (1005, String::new()),
            Some(Ok(_)) => continue,
            other => panic!("expected a close frame, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn registers_rooms() {
    let s = start(&[], |_| {}).await;
    let a = room('a');
    let uri = format!("/api/relay/rooms/{a}");

    for token in [None, Some("wrong-token-0123456789")] {
        assert_eq!(s.request(Method::PUT, &uri, token).await.0, StatusCode::UNAUTHORIZED);
        assert_eq!(s.request(Method::DELETE, &uri, token).await.0, StatusCode::UNAUTHORIZED);
    }
    for bad in [a.to_uppercase(), a[1..].to_owned(), format!("{a}0"), "z".repeat(64), "room".into()] {
        let (status, body) = s.request(Method::PUT, &format!("/api/relay/rooms/{bad}"), Some(TOKEN)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
        assert!(body["error"].is_string());
        let (status, _) = s.refused(s.url(&bad, "mac")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }

    let (status, body) = s.refused(s.url(&a, "mac")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"], "room not found");

    assert_eq!(s.register(&a).await, StatusCode::NO_CONTENT);
    let stored = s.dir.path().join("relay/rooms").join(&a);
    let record: Value = serde_json::from_slice(&std::fs::read(&stored).unwrap()).unwrap();
    let created_at = record["created_at"].as_str().unwrap().to_owned();
    assert!(chrono::DateTime::parse_from_rfc3339(&created_at).is_ok(), "{created_at}");
    assert_eq!(s.register(&a).await, StatusCode::NO_CONTENT, "idempotent");
    let record: Value = serde_json::from_slice(&std::fs::read(&stored).unwrap()).unwrap();
    assert_eq!(record["created_at"], created_at.as_str(), "re-registering keeps the record");

    for role in ["", "tablet", "MAC"] {
        let (status, body) = s.refused(format!("ws://{}/api/relay/rooms/{a}/connect?role={role}", s.addr)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{role}");
        assert!(body["error"].is_string());
    }
    let (status, _) = s.refused(format!("ws://{}/api/relay/rooms/{a}/connect", s.addr)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    // A plain HTTP request to a valid room is not a WebSocket handshake.
    let (status, _) = s.request(Method::GET, &format!("/api/relay/rooms/{a}/connect?role=mac"), None).await;
    assert!(status.is_client_error(), "{status}");

    // A restarted server on the same storage knows the room.
    let s = start_in(s.dir, &[], |_| {}).await;
    assert!(s.state.relay.is_registered(&a));
    let (_mac, _phone) = s.pair(&a).await;

    assert_eq!(s.unregister(&a).await, StatusCode::NO_CONTENT);
    assert!(!stored.exists());
    assert_eq!(s.unregister(&a).await, StatusCode::NO_CONTENT, "idempotent");
    assert_eq!(s.unregister(&room('b')).await, StatusCode::NO_CONTENT, "unknown rooms too");
    assert_eq!(s.refused(s.url(&a, "phone")).await.0, StatusCode::NOT_FOUND);

    let (status, info) = s.request(Method::GET, "/api/info", Some(TOKEN)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(info["relay"], true);
}

#[tokio::test]
async fn forwards_messages_both_ways() {
    let s = start(&[], |_| {}).await;
    let a = room('a');
    s.register(&a).await;
    let (mut mac, mut phone) = s.pair(&a).await;

    let big: Vec<u8> = (0..1024 * 1024 + 17).map(|i| (i % 251) as u8).collect();
    mac.send(Message::binary(big.clone())).await.unwrap();
    assert_eq!(next_data(&mut phone).await, Message::binary(big.clone()));
    phone.send(Message::binary(big.clone())).await.unwrap();
    assert_eq!(next_data(&mut mac).await, Message::binary(big));

    mac.send(Message::text("from mac")).await.unwrap();
    assert_eq!(next_data(&mut phone).await, Message::text("from mac"));
    phone.send(Message::text("from phone")).await.unwrap();
    assert_eq!(next_data(&mut mac).await, Message::text("from phone"));

    // Order is kept across many small messages.
    for i in 0..200u32 {
        phone.send(Message::binary(i.to_be_bytes().to_vec())).await.unwrap();
    }
    for i in 0..200u32 {
        assert_eq!(next_data(&mut mac).await, Message::binary(i.to_be_bytes().to_vec()));
    }

    // The phone leaves: the Mac is closed normally.
    phone.close(None).await.unwrap();
    assert_eq!(closed(&mut mac).await, (1000, String::new()));

    // The Mac leaves: the phone is closed normally.
    let (mut mac, mut phone) = s.pair(&a).await;
    mac.close(None).await.unwrap();
    assert_eq!(closed(&mut phone).await, (1000, String::new()));

    // A dropped connection (no close frame) counts as leaving too.
    let (mac, mut phone) = s.pair(&a).await;
    drop(mac);
    assert_eq!(closed(&mut phone).await.0, 1000);
}

#[tokio::test]
async fn exhausted_admission_budget_preserves_upgraded_relay_pair() {
    let s = start(&[("RATE_LIMIT_RELAY_PER_MINUTE", "1"), ("RATE_LIMIT_RELAY_BURST", "2")], |_| {}).await;
    let a = room('a');
    assert_eq!(s.register(&a).await, StatusCode::NO_CONTENT);

    // Both real upgrades succeed and exhaust the shared loopback client's budget.
    let (mut mac, mut phone) = s.pair(&a).await;
    for role in ["mac", "phone"] {
        match timeout(WAIT, tokio_tungstenite::connect_async(s.url(&a, role))).await.unwrap() {
            Err(tungstenite::Error::Http(response)) => {
                assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
                assert!(response.headers()[header::RETRY_AFTER].to_str().unwrap().parse::<u64>().unwrap() >= 1);
                assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
            }
            other => panic!("expected admission rejection, got {:?}", other.map(|(_, r)| r.status())),
        }
    }

    // Rejected upgrades do not interrupt byte forwarding on the admitted sockets.
    let bytes = vec![0, 1, 127, 128, 255];
    mac.send(Message::binary(bytes.clone())).await.unwrap();
    assert_eq!(next_data(&mut phone).await, Message::binary(bytes.clone()));
    phone.send(Message::binary(bytes.clone())).await.unwrap();
    assert_eq!(next_data(&mut mac).await, Message::binary(bytes));
    phone.close(None).await.unwrap();
    assert_eq!(closed(&mut mac).await.0, 1000);
}

#[tokio::test]
async fn phone_waits_for_a_mac() {
    let s = start(&[], |c| c.relay.phone_wait = Duration::from_millis(300)).await;
    let a = room('a');
    s.register(&a).await;

    // Nobody home.
    let started = Instant::now();
    let mut phone = s.connect(&a, "phone").await;
    assert_eq!(closed(&mut phone).await, (4404, "mac offline".to_owned()));
    assert!(started.elapsed() >= Duration::from_millis(250), "{:?}", started.elapsed());

    // A Mac that shows up while the phone waits gets the phone's first message.
    let mut phone = s.connect(&a, "phone").await;
    phone.send(Message::binary(b"handshake".to_vec())).await.unwrap();
    sleep(Duration::from_millis(100)).await;
    let mut mac = s.connect(&a, "mac").await;
    assert_eq!(next_data(&mut mac).await, Message::binary(b"handshake".to_vec()));
    mac.send(Message::binary(b"welcome".to_vec())).await.unwrap();
    assert_eq!(next_data(&mut phone).await, Message::binary(b"welcome".to_vec()));
    assert_eq!(s.state.relay.waiting_macs(&a), 0);
}

#[tokio::test]
async fn ninth_waiting_mac_replaces_the_oldest() {
    let s = start(&[], |_| {}).await;
    let a = room('a');
    s.register(&a).await;

    let mut macs = Vec::new();
    for _ in 0..8 {
        macs.push(s.connect_mac(&a).await);
    }
    let ninth = s.connect(&a, "mac").await;
    assert_eq!(closed(&mut macs[0]).await, (4409, "replaced".to_owned()));
    assert_eq!(s.state.relay.waiting_macs(&a), 8);
    macs.push(ninth);

    // Phones take the oldest waiting Mac first.
    let mut phone = s.connect(&a, "phone").await;
    phone.send(Message::binary(b"one".to_vec())).await.unwrap();
    assert_eq!(next_data(&mut macs[1]).await, Message::binary(b"one".to_vec()));
    s.wait_for_macs(&a, 7).await;

    // A waiting Mac that goes away leaves the pool.
    macs[2].close(None).await.unwrap();
    s.wait_for_macs(&a, 6).await;
    let mut phone2 = s.connect(&a, "phone").await;
    phone2.send(Message::binary(b"two".to_vec())).await.unwrap();
    assert_eq!(next_data(&mut macs[3]).await, Message::binary(b"two".to_vec()));
}

#[tokio::test]
async fn deleting_a_room_closes_its_sockets() {
    let s = start(&[], |_| {}).await;
    let (a, b) = (room('a'), room('b'));
    s.register(&a).await;
    s.register(&b).await;
    let (mut mac, mut phone) = s.pair(&a).await;
    let mut waiting = s.connect_mac(&a).await;
    let (mut other_mac, mut other_phone) = s.pair(&b).await;

    assert_eq!(s.unregister(&a).await, StatusCode::NO_CONTENT);
    assert_eq!(closed(&mut mac).await.0, 1000);
    assert_eq!(closed(&mut phone).await.0, 1000);
    assert_eq!(closed(&mut waiting).await.0, 1000);
    assert_eq!(s.refused(s.url(&a, "mac")).await.0, StatusCode::NOT_FOUND);

    // Other rooms are untouched.
    other_phone.send(Message::text("still here")).await.unwrap();
    assert_eq!(next_data(&mut other_mac).await, Message::text("still here"));
}

#[tokio::test]
async fn relay_can_be_turned_off() {
    let s = start(&[("RELAY", "off")], |_| {}).await;
    let a = room('a');
    let (status, info) = s.request(Method::GET, "/api/info", Some(TOKEN)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(info["relay"], false);
    assert_eq!(s.register(&a).await, StatusCode::NOT_FOUND);
    assert_eq!(s.unregister(&a).await, StatusCode::NOT_FOUND);
    assert_eq!(s.refused(s.url(&a, "mac")).await.0, StatusCode::NOT_FOUND);
    assert_eq!(s.refused(s.url(&a, "phone")).await.0, StatusCode::NOT_FOUND);
    assert!(!s.dir.path().join("relay").exists());
}

#[tokio::test]
async fn idle_pairs_are_closed() {
    let s = start(&[], |c| c.relay.idle_timeout = Duration::from_millis(400)).await;
    let a = room('a');
    s.register(&a).await;
    let (mut mac, mut phone) = s.pair(&a).await;

    // Traffic in either direction keeps the pair open.
    sleep(Duration::from_millis(250)).await;
    mac.send(Message::binary(vec![1])).await.unwrap();
    assert_eq!(next_data(&mut phone).await, Message::binary(vec![1]));
    sleep(Duration::from_millis(250)).await;
    phone.send(Message::binary(vec![2])).await.unwrap();
    assert_eq!(next_data(&mut mac).await, Message::binary(vec![2]));

    let quiet = Instant::now();
    assert_eq!(closed(&mut mac).await.0, 1000);
    assert_eq!(closed(&mut phone).await.0, 1000);
    assert!(quiet.elapsed() >= Duration::from_millis(300), "{:?}", quiet.elapsed());
}

#[tokio::test]
async fn pings_waiting_and_paired_sockets() {
    let s = start(&[], |c| c.relay.ping_interval = Duration::from_millis(100)).await;
    let a = room('a');
    s.register(&a).await;

    let mut waiting = s.connect_mac(&a).await;
    let message = timeout(WAIT, waiting.next()).await.unwrap().unwrap().unwrap();
    assert!(matches!(message, Message::Ping(_)), "{message:?}");
    waiting.close(None).await.unwrap();
    s.wait_for_macs(&a, 0).await;

    let (mut mac, mut phone) = s.pair(&a).await;
    for client in [&mut mac, &mut phone] {
        let message = timeout(WAIT, client.next()).await.unwrap().unwrap().unwrap();
        assert!(matches!(message, Message::Ping(_)), "{message:?}");
    }
    // Pings do not disturb data.
    phone.send(Message::binary(vec![7; 10])).await.unwrap();
    assert_eq!(next_data(&mut mac).await, Message::binary(vec![7; 10]));
}

#[tokio::test]
async fn enforces_message_size() {
    let s = start(&[("RELAY_MAX_MESSAGE", "65536")], |_| {}).await;
    let a = room('a');
    s.register(&a).await;

    let (mut mac, mut phone) = s.pair(&a).await;
    phone.send(Message::binary(vec![0; 65536])).await.unwrap();
    assert_eq!(next_data(&mut mac).await, Message::binary(vec![0; 65536]));
    phone.send(Message::binary(vec![0; 65537])).await.unwrap();
    assert_eq!(closed(&mut phone).await.0, 1009);
    assert_eq!(closed(&mut mac).await.0, 1000);

    let (mut mac, mut phone) = s.pair(&a).await;
    mac.send(Message::binary(vec![0; 200_000])).await.unwrap();
    assert_eq!(closed(&mut mac).await.0, 1009);
    assert_eq!(closed(&mut phone).await.0, 1000);
}

#[tokio::test]
async fn enforces_capacity_limits() {
    let s = start(&[("RELAY_MAX_PAIRS", "1"), ("RELAY_MAX_WAITING", "2")], |_| {}).await;
    let (a, b) = (room('a'), room('b'));
    s.register(&a).await;
    s.register(&b).await;

    let (mut mac, mut phone) = s.pair(&a).await;
    let mut busy = s.connect(&a, "phone").await;
    assert_eq!(closed(&mut busy).await, (4503, "relay busy".to_owned()));
    // The slot frees up when the pair ends.
    phone.close(None).await.unwrap();
    assert_eq!(closed(&mut mac).await.0, 1000);

    let mut m1 = s.connect_mac(&a).await;
    let _m2 = s.connect_mac(&b).await;
    let mut third = s.connect(&b, "mac").await;
    assert_eq!(closed(&mut third).await, (4503, "relay busy".to_owned()));
    assert_eq!(s.state.relay.waiting_macs(&b), 1);

    let mut phone = s.connect(&a, "phone").await;
    phone.send(Message::text("after")).await.unwrap();
    assert_eq!(next_data(&mut m1).await, Message::text("after"));
}

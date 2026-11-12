//! End-to-end tests of Walkie mailboxes over a real listener.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use xnotch_cloud::config::Config;
use xnotch_cloud::storage::Storage;
use xnotch_cloud::walkie::box_for_secret;
use xnotch_cloud::{AppState, SharedState, app};

const TOKEN: &str = "test-token-0123456789";
const WAIT: Duration = Duration::from_secs(5);

struct Server {
    addr: SocketAddr,
    state: SharedState,
    _dir: TempDir,
}

async fn start(extra: &[(&str, &str)]) -> Server {
    let dir = TempDir::new().unwrap();
    let mut env: HashMap<String, String> = HashMap::from([
        ("PUBLIC_URL".into(), "https://drop.example.com".into()),
        ("API_TOKEN".into(), TOKEN.into()),
        ("DATA_DIR".into(), dir.path().to_string_lossy().into_owned()),
    ]);
    env.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    let config = Config::from_lookup(|k| env.get(k).cloned()).unwrap();
    let storage = Storage::from_config(&config.storage).unwrap();
    let state = Arc::new(AppState::new(config, storage));
    state.walkie.load(&state.storage).await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = app(state.clone());
    tokio::spawn(async move {
        axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>()).await.unwrap()
    });
    Server { addr, state, _dir: dir }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A tiny HTTP/1.1 client, so the tests need no extra dependency.
async fn call(server: &Server, method: &str, path: &str, headers: &[(&str, String)], body: &[u8]) -> (u16, Vec<u8>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(server.addr).await.unwrap();
    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    for (name, value) in headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    let mut bytes = request.into_bytes();
    bytes.extend_from_slice(body);
    // The server may answer and close before it reads a refused body.
    let _ = stream.write_all(&bytes).await;
    let mut response = Vec::new();
    let _ = stream.read_to_end(&mut response).await;
    let split = response.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8_lossy(&response[..split]).to_string();
    let status: u16 = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    let mut body = response[split + 4..].to_vec();
    if head.to_ascii_lowercase().contains("transfer-encoding: chunked") {
        body = dechunk(&body);
    }
    (status, body)
}

fn dechunk(mut data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let line = data.windows(2).position(|w| w == b"\r\n").unwrap();
        let size = usize::from_str_radix(std::str::from_utf8(&data[..line]).unwrap().trim(), 16).unwrap();
        data = &data[line + 2..];
        if size == 0 {
            return out;
        }
        out.extend_from_slice(&data[..size]);
        data = &data[size + 2..];
    }
}

fn json_body(body: &[u8]) -> Value {
    serde_json::from_slice(body).unwrap_or(Value::Null)
}

struct Mailbox {
    id: String,
    secret: String,
    post: String,
}

fn mailbox(seed: u8) -> Mailbox {
    let secret = [seed; 32];
    Mailbox { id: box_for_secret(&secret), secret: hex(&secret), post: hex(&[seed.wrapping_add(100); 32]) }
}

async fn register(server: &Server, m: &Mailbox, listed: bool) -> u16 {
    let body = json!({ "post_token": m.post, "card": "Y2FyZA", "listed": listed }).to_string();
    call(
        server,
        "PUT",
        &format!("/api/walkie/boxes/{}", m.id),
        &[("Authorization", format!("Bearer {TOKEN}")), ("X-Walkie-Secret", m.secret.clone())],
        body.as_bytes(),
    )
    .await
    .0
}

async fn listen(
    server: &Server,
    m: &Mailbox,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let mut request = format!("ws://{}/api/walkie/boxes/{}/listen", server.addr, m.id).into_client_request().unwrap();
    request.headers_mut().insert("Authorization", format!("Bearer {}", m.secret).parse().unwrap());
    let (socket, _) = tokio_tungstenite::connect_async(request).await.unwrap();
    socket
}

#[tokio::test]
async fn registering_needs_the_api_token_and_the_secret() {
    let s = start(&[]).await;
    let m = mailbox(1);
    let body = json!({ "post_token": m.post }).to_string();
    let path = format!("/api/walkie/boxes/{}", m.id);
    let no_token = call(&s, "PUT", &path, &[("X-Walkie-Secret", m.secret.clone())], body.as_bytes()).await.0;
    assert_eq!(no_token, 401);
    let wrong_secret = call(
        &s,
        "PUT",
        &path,
        &[("Authorization", format!("Bearer {TOKEN}")), ("X-Walkie-Secret", hex(&[2; 32]))],
        body.as_bytes(),
    )
    .await
    .0;
    assert_eq!(wrong_secret, 401);
    assert_eq!(register(&s, &m, false).await, 204);
    let (status, info) = call(&s, "GET", "/api/info", &[("Authorization", format!("Bearer {TOKEN}"))], b"").await;
    assert_eq!(status, 200);
    assert_eq!(json_body(&info)["walkie"], true);
}

#[tokio::test]
async fn messages_flow_from_contact_to_owner() {
    let s = start(&[]).await;
    let m = mailbox(3);
    assert_eq!(register(&s, &m, false).await, 204);
    let mut socket = listen(&s, &m).await;

    let path = format!("/api/walkie/boxes/{}/messages", m.id);
    let wrong = call(&s, "POST", &path, &[("Authorization", format!("Bearer {}", hex(&[9; 32])))], b"x").await.0;
    assert_eq!(wrong, 401, "a wrong send token is refused");
    let owner_secret = call(&s, "POST", &path, &[("Authorization", format!("Bearer {}", m.secret))], b"x").await.0;
    assert_eq!(owner_secret, 401, "the secret is not a send token");

    // Presence: online while the socket listens.
    let ask = json!({ "boxes": [{ "box": m.id, "token": m.post }] }).to_string();
    let (_, presence) = call(&s, "POST", "/api/walkie/presence", &[], ask.as_bytes()).await;
    assert_eq!(json_body(&presence)["boxes"][0]["online"], true);

    let (status, posted) =
        call(&s, "POST", &path, &[("Authorization", format!("Bearer {}", m.post))], b"sealed bytes").await;
    assert_eq!(status, 201);
    let posted = json_body(&posted);
    assert_eq!(posted["delivered"], true);
    let id = posted["id"].as_str().unwrap().to_owned();

    let notice = loop {
        match timeout(WAIT, socket.next()).await.unwrap().unwrap().unwrap() {
            Message::Text(text) => break json_body(text.as_bytes()),
            _ => continue,
        }
    };
    assert_eq!(notice["type"], "message");
    assert_eq!(notice["id"], id.as_str());
    assert_eq!(notice["size"], 12);

    // Signals reach the listener as binary frames and are not stored.
    let signal_path = format!("/api/walkie/boxes/{}/signals", m.id);
    let (status, _) =
        call(&s, "POST", &signal_path, &[("Authorization", format!("Bearer {}", m.post))], b"talking").await;
    assert_eq!(status, 202);
    let signal = loop {
        match timeout(WAIT, socket.next()).await.unwrap().unwrap().unwrap() {
            Message::Binary(bytes) => break bytes,
            _ => continue,
        }
    };
    assert_eq!(&signal[..], b"talking");

    let read_auth = [("Authorization", format!("Bearer {}", m.secret))];
    let (status, listed) = call(&s, "GET", &path, &read_auth, b"").await;
    assert_eq!(status, 200);
    assert_eq!(json_body(&listed)["messages"].as_array().unwrap().len(), 1);
    let post_auth = [("Authorization", format!("Bearer {}", m.post))];
    assert_eq!(call(&s, "GET", &path, &post_auth, b"").await.0, 401, "contacts can't read the mailbox");

    let message_path = format!("{path}/{id}");
    let (status, bytes) = call(&s, "GET", &message_path, &read_auth, b"").await;
    assert_eq!((status, bytes.as_slice()), (200, &b"sealed bytes"[..]));
    assert_eq!(call(&s, "DELETE", &message_path, &read_auth, b"").await.0, 204);
    assert_eq!(call(&s, "GET", &message_path, &read_auth, b"").await.0, 404);

    socket.close(None).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let (_, presence) = call(&s, "POST", "/api/walkie/presence", &[], ask.as_bytes()).await;
    let presence = json_body(&presence);
    assert_eq!(presence["boxes"][0]["online"], false);
    assert!(presence["boxes"][0]["last_seen"].is_string());
}

#[tokio::test]
async fn directory_lists_only_opted_in_mailboxes() {
    let s = start(&[]).await;
    let (a, b) = (mailbox(5), mailbox(6));
    assert_eq!(register(&s, &a, true).await, 204);
    assert_eq!(register(&s, &b, false).await, 204);
    let (status, listed) =
        call(&s, "GET", "/api/walkie/directory", &[("Authorization", format!("Bearer {TOKEN}"))], b"").await;
    assert_eq!(status, 200);
    let listed = json_body(&listed);
    let listed = listed.as_array().unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["box"], a.id.as_str());
    assert_eq!(listed[0]["post_token"], a.post.as_str());
    assert_eq!(call(&s, "GET", "/api/walkie/directory", &[], b"").await.0, 401);
}

#[tokio::test]
async fn limits_size_and_backlog_and_survives_restart() {
    let s = start(&[("WALKIE_MAX_MESSAGE", "65536"), ("WALKIE_MAX_PENDING", "2")]).await;
    let m = mailbox(7);
    assert_eq!(register(&s, &m, false).await, 204);
    let path = format!("/api/walkie/boxes/{}/messages", m.id);
    let auth = [("Authorization", format!("Bearer {}", m.post))];
    assert_eq!(call(&s, "POST", &path, &auth, &vec![0u8; 65537]).await.0, 413);
    assert_eq!(call(&s, "POST", &path, &auth, b"1").await.0, 201);
    assert_eq!(call(&s, "POST", &path, &auth, b"2").await.0, 201);
    assert_eq!(call(&s, "POST", &path, &auth, b"3").await.0, 429, "a full mailbox makes senders wait");

    // A new process finds the mailbox and its backlog.
    let fresh = Arc::new(AppState::new(s.state.config.clone(), Storage::from_config(&s.state.config.storage).unwrap()));
    assert_eq!(fresh.walkie.load(&fresh.storage).await.unwrap(), 1);

    let deleted = call(
        &s,
        "DELETE",
        &format!("/api/walkie/boxes/{}", m.id),
        &[("Authorization", format!("Bearer {TOKEN}")), ("X-Walkie-Secret", m.secret.clone())],
        b"",
    )
    .await
    .0;
    assert_eq!(deleted, 204);
    assert_eq!(call(&s, "POST", &path, &auth, b"4").await.0, 401, "a removed mailbox takes nothing");
}

#[tokio::test]
async fn walkie_can_be_switched_off() {
    let s = start(&[("WALKIE", "off")]).await;
    let m = mailbox(8);
    assert_eq!(register(&s, &m, false).await, 404);
}

//! Deterministic admission tests: no sleeps or large production-rate bursts.
use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{Method, Request, StatusCode, header},
    response::Response,
};
use chrono::Utc;
use http_body_util::BodyExt;
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tempfile::TempDir;
use tower::ServiceExt;
use xnotch_cloud::{AppState, SharedState, app, config::Config, model::DropMeta, password, storage::Storage};
const TOKEN: &str = "test-token-0123456789";
const PEER: &str = "192.0.2.1:1000";
struct Harness {
    state: SharedState,
    _dir: TempDir,
}
impl Harness {
    fn new(extra: &[(&str, &str)]) -> Self {
        let dir = TempDir::new().unwrap();
        let mut env = HashMap::from([
            ("PUBLIC_URL", "https://drop.example.com".to_owned()),
            ("API_TOKEN", TOKEN.to_owned()),
            ("DATA_DIR", dir.path().to_str().unwrap().to_owned()),
        ]);
        env.extend(extra.iter().map(|(k, v)| (*k, v.to_string())));
        let config = Config::from_lookup(|k| env.get(k).cloned()).unwrap();
        let storage = Storage::from_config(&config.storage).unwrap();
        Self { state: Arc::new(AppState::new(config, storage)), _dir: dir }
    }
    fn request(method: Method, path: &str, peer: &str, headers: &[(&str, &str)], body: Body) -> Request<Body> {
        let mut builder = Request::builder().method(method).uri(path);
        for (name, value) in headers {
            builder = builder.header(*name, *value);
        }
        let mut request = builder.body(body).unwrap();
        request.extensions_mut().insert(ConnectInfo(peer.parse::<SocketAddr>().unwrap()));
        request
    }
    async fn send(&self, request: Request<Body>) -> Response {
        app(self.state.clone()).oneshot(request).await.unwrap()
    }
    async fn get(&self, path: &str, peer: &str, headers: &[(&str, &str)]) -> Response {
        self.send(Self::request(Method::GET, path, peer, headers, Body::empty())).await
    }
}
fn throttled(response: &Response) {
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(response.headers()[header::RETRY_AFTER].to_str().unwrap().parse::<u64>().unwrap() >= 1);
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
}
#[tokio::test]
async fn auth_and_management_share_budget_before_token_validation() {
    let h = Harness::new(&[("RATE_LIMIT_API_PER_MINUTE", "1"), ("RATE_LIMIT_API_BURST", "2")]);
    assert_eq!(h.get("/api/info", PEER, &[]).await.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(h.get("/api/info", PEER, &[("authorization", "Bearer wrong")]).await.status(), StatusCode::UNAUTHORIZED);
    throttled(&h.get("/api/info", PEER, &[("authorization", &format!("Bearer {TOKEN}"))]).await);
    throttled(&h.get("/api/drops", "192.0.2.1:2000", &[]).await);
    assert_eq!(
        h.get("/api/info", "192.0.2.2:1000", &[("authorization", &format!("Bearer {TOKEN}"))]).await.status(),
        StatusCode::OK
    );
    assert_eq!(h.get("/", PEER, &[]).await.status(), StatusCode::OK);
}
#[tokio::test]
async fn exhausted_api_budget_rejects_upload_without_polling_body() {
    let h = Harness::new(&[("RATE_LIMIT_API_PER_MINUTE", "1"), ("RATE_LIMIT_API_BURST", "1")]);
    h.state.storage.save(&DropMeta::new("abcdefgh".into(), None, Utc::now(), 3600)).await.unwrap();
    let auth = format!("Bearer {TOKEN}");
    assert_eq!(h.get("/api/info", PEER, &[("authorization", &auth)]).await.status(), StatusCode::OK);

    // Count when the body is polled, rather than when it is constructed or dropped.
    let polls = Arc::new(AtomicUsize::new(0));
    for (peer, expected_polls) in [(PEER, 0), ("192.0.2.2:1000", 1)] {
        let body_polls = polls.clone();
        let body = Body::from_stream(futures_util::stream::once(async move {
            body_polls.fetch_add(1, Ordering::SeqCst);
            Ok::<_, std::io::Error>("upload bytes")
        }));
        let request = Harness::request(
            Method::PUT,
            "/api/drops/abcdefgh/files/test.txt",
            peer,
            &[("authorization", &auth)],
            body,
        );
        let response = h.send(request).await;
        if expected_polls == 0 {
            throttled(&response);
        } else {
            // A fresh client proves the same valid upload really consumes the body.
            assert_eq!(response.status(), StatusCode::CREATED);
        }
        assert_eq!(polls.load(Ordering::SeqCst), expected_polls);
    }
}
#[tokio::test]
async fn password_posts_share_budget_across_drops_before_form_parsing() {
    let h = Harness::new(&[("RATE_LIMIT_PASSWORD_PER_MINUTE", "1"), ("RATE_LIMIT_PASSWORD_BURST", "1")]);
    let request = Harness::request(Method::POST, "/abcdefgh", PEER, &[], Body::empty());
    assert_eq!(h.send(request).await.status(), StatusCode::NOT_FOUND);
    let request = Harness::request(Method::POST, "/ijklmnop", PEER, &[], Body::empty());
    throttled(&h.send(request).await);
    assert_eq!(h.get("/abcdefgh", PEER, &[]).await.status(), StatusCode::NOT_FOUND);
}
#[tokio::test]
async fn spoofed_headers_cannot_bypass_limits_and_health_survives_saturation() {
    let h = Harness::new(&[
        ("RATE_LIMIT_PUBLIC_PER_MINUTE", "1"),
        ("RATE_LIMIT_PUBLIC_BURST", "1"),
        ("RATE_LIMIT_MAX_CLIENTS", "1"),
    ]);
    assert_eq!(h.get("/", PEER, &[("x-forwarded-for", "198.51.100.1")]).await.status(), StatusCode::OK);
    throttled(
        &h.get(
            "/",
            PEER,
            &[("x-forwarded-for", "198.51.100.2"), ("forwarded", "for=198.51.100.3"), ("x-real-ip", "198.51.100.4")],
        )
        .await,
    );
    throttled(&h.get("/", "192.0.2.2:1000", &[]).await);
    for _ in 0..10 {
        assert_eq!(
            h.send(Request::builder().uri("/healthz").body(Body::empty()).unwrap()).await.status(),
            StatusCode::OK
        );
    }
    throttled(&h.send(Request::builder().uri("/").body(Body::empty()).unwrap()).await);
}
#[tokio::test]
async fn trusted_chain_isolates_clients_and_ignores_attacker_prefix() {
    let h = Harness::new(&[
        ("TRUSTED_PROXIES", "10.0.0.0/24"),
        ("RATE_LIMIT_PUBLIC_PER_MINUTE", "1"),
        ("RATE_LIMIT_PUBLIC_BURST", "1"),
    ]);
    let peer = "10.0.0.2:1000";
    assert_eq!(
        h.get("/", peer, &[("x-forwarded-for", "203.0.113.1, 198.51.100.9, 10.0.0.3")]).await.status(),
        StatusCode::OK
    );
    throttled(&h.get("/", peer, &[("x-forwarded-for", "203.0.113.2, 198.51.100.9, 10.0.0.3")]).await);
    assert_eq!(h.get("/", peer, &[("x-forwarded-for", "198.51.100.10, 10.0.0.3")]).await.status(), StatusCode::OK);
}
#[tokio::test]
async fn relay_admission_is_separate_from_management() {
    let h = Harness::new(&[("RATE_LIMIT_RELAY_PER_MINUTE", "1"), ("RATE_LIMIT_RELAY_BURST", "1")]);
    let path = "/api/relay/rooms/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/connect?role=mac";
    assert_ne!(h.get(path, PEER, &[]).await.status(), StatusCode::TOO_MANY_REQUESTS);
    throttled(&h.get(path, PEER, &[]).await);
    assert_eq!(
        h.get("/api/info", PEER, &[("authorization", &format!("Bearer {TOKEN}"))]).await.status(),
        StatusCode::OK
    );
}
#[tokio::test]
async fn password_creation_and_verification_share_nonqueuing_pool() {
    let h = Harness::new(&[("PASSWORD_CONCURRENCY", "1")]);
    let mut meta = DropMeta::new("abcdefgh".into(), None, Utc::now(), 3600);
    meta.password_hash = Some("invalid-hash-must-not-be-checked".into());
    meta.unlock_key = Some("key".into());
    h.state.storage.save(&meta).await.unwrap();
    let permit = h.state.password_checks.clone().try_acquire_owned().unwrap();
    let create = Harness::request(
        Method::POST,
        "/api/drops",
        PEER,
        &[("authorization", &format!("Bearer {TOKEN}"))],
        Body::from(r#"{"password":"secret"}"#),
    );
    throttled(&h.send(create).await);
    let unlock = Harness::request(
        Method::POST,
        "/abcdefgh",
        PEER,
        &[("content-type", "application/x-www-form-urlencoded")],
        Body::from("password=secret"),
    );
    throttled(&h.send(unlock).await);
    let plain = Harness::request(
        Method::POST,
        "/api/drops",
        PEER,
        &[("authorization", &format!("Bearer {TOKEN}"))],
        Body::empty(),
    );
    assert_eq!(h.send(plain).await.status(), StatusCode::CREATED);
    drop(permit);
    assert_eq!(password::run_bounded(&h.state, || 42).await.unwrap(), 42);
}
#[tokio::test]
async fn cancelled_request_retains_running_password_worker_permit() {
    let h = Harness::new(&[("PASSWORD_CONCURRENCY", "1")]);
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let state = h.state.clone();
    let request = tokio::spawn(async move {
        password::run_bounded(&state, move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        })
        .await
    });
    started_rx.await.unwrap();
    request.abort();
    let _ = request.await;
    assert!(matches!(
        password::run_bounded(&h.state, || ()).await,
        Err(xnotch_cloud::error::ApiError::TooManyRequests(1))
    ));
    release_tx.send(()).unwrap();
    let permit = tokio::time::timeout(std::time::Duration::from_secs(5), h.state.password_checks.acquire())
        .await
        .unwrap()
        .unwrap();
    drop(permit);
}
#[tokio::test]
async fn admitted_streams_finish_when_later_requests_are_throttled() {
    let h = Harness::new(&[
        ("RATE_LIMIT_API_PER_MINUTE", "1"),
        ("RATE_LIMIT_API_BURST", "1"),
        ("RATE_LIMIT_PUBLIC_PER_MINUTE", "1"),
        ("RATE_LIMIT_PUBLIC_BURST", "1"),
    ]);
    h.state.storage.save(&DropMeta::new("abcdefgh".into(), None, Utc::now(), 3600)).await.unwrap();
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = tokio::sync::oneshot::channel();
    let stream = futures_util::stream::once(async move {
        started_tx.send(()).unwrap();
        release_rx.await.unwrap();
        Ok::<_, std::io::Error>("still streaming")
    });
    let request = Harness::request(
        Method::PUT,
        "/api/drops/abcdefgh/files/test.txt",
        PEER,
        &[("authorization", &format!("Bearer {TOKEN}"))],
        Body::from_stream(stream),
    );
    let router = app(h.state.clone());
    let upload = tokio::spawn(async move { router.oneshot(request).await.unwrap() });
    started_rx.await.unwrap();
    throttled(&h.get("/api/info", PEER, &[]).await);
    release_tx.send(()).unwrap();
    assert_eq!(upload.await.unwrap().status(), StatusCode::CREATED);
    let download = h.get("/abcdefgh/test.txt", PEER, &[]).await;
    assert_eq!(download.status(), StatusCode::OK);
    throttled(&h.get("/abcdefgh/test.txt", PEER, &[]).await);
    assert_eq!(download.into_body().collect().await.unwrap().to_bytes(), "still streaming");
}

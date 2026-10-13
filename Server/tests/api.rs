//! End-to-end tests driving the router against local storage in a temp dir.

use std::collections::HashMap;
use std::sync::Arc;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tempfile::TempDir;
use tower::ServiceExt;
use xnotch_cloud::config::Config;
use xnotch_cloud::model::{DropMeta, FileMeta};
use xnotch_cloud::storage::Storage;
use xnotch_cloud::{AppState, SharedState, app};

const TOKEN: &str = "test-token-0123456789";
const PUBLIC_URL: &str = "https://drop.example.com";

struct Harness {
    app: Router,
    state: SharedState,
    dir: TempDir,
}

fn harness(extra: &[(&str, &str)]) -> Harness {
    let dir = TempDir::new().unwrap();
    let mut env: HashMap<String, String> = HashMap::from([
        ("PUBLIC_URL".into(), format!("{PUBLIC_URL}/")),
        ("API_TOKEN".into(), TOKEN.into()),
        ("DATA_DIR".into(), dir.path().to_string_lossy().into_owned()),
        ("SITE_NAME".into(), "Test Cloud".into()),
    ]);
    env.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    let config = Config::from_lookup(|k| env.get(k).cloned()).unwrap();
    let storage = Storage::from_config(&config.storage).unwrap();
    let state = Arc::new(AppState::new(config, storage));
    Harness { app: app(state.clone()), state, dir }
}

struct Reply {
    status: StatusCode,
    headers: HeaderMap,
    body: Bytes,
}

impl Reply {
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or_else(|e| panic!("not JSON ({e}): {:?}", self.body))
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
    fn header(&self, name: &str) -> &str {
        self.headers.get(name).map(|v| v.to_str().unwrap()).unwrap_or_else(|| panic!("missing header {name}"))
    }
}

impl Harness {
    async fn send(&self, request: Request<Body>) -> Reply {
        let response = self.app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let body = response.into_body().collect().await.unwrap().to_bytes();
        Reply { status, headers, body }
    }

    async fn api(&self, method: Method, uri: &str, body: impl Into<Body>) -> Reply {
        let request = Request::builder()
            .method(method)
            .uri(uri)
            .header(header::AUTHORIZATION, format!("Bearer {TOKEN}"))
            .body(body.into())
            .unwrap();
        self.send(request).await
    }

    async fn get(&self, uri: &str, headers: &[(&str, &str)]) -> Reply {
        let mut request = Request::builder().uri(uri);
        for (k, v) in headers {
            request = request.header(*k, *v);
        }
        self.send(request.body(Body::empty()).unwrap()).await
    }

    async fn create(&self, body: Value) -> String {
        let reply = self.api(Method::POST, "/api/drops", body.to_string()).await;
        assert_eq!(reply.status, StatusCode::CREATED, "{}", reply.text());
        reply.json()["id"].as_str().unwrap().to_owned()
    }

    async fn upload(&self, id: &str, encoded_name: &str, data: impl Into<Body>) -> Reply {
        self.api(Method::PUT, &format!("/api/drops/{id}/files/{encoded_name}"), data).await
    }
}

#[tokio::test]
async fn full_drop_lifecycle() {
    let h = harness(&[]);

    let health = h.get("/healthz", &[]).await;
    assert_eq!((health.status, health.text().as_str()), (StatusCode::OK, "ok"));

    let info = h.api(Method::GET, "/api/info", Body::empty()).await;
    assert_eq!(info.status, StatusCode::OK);
    assert_eq!(
        info.json(),
        json!({
            "name": "Test Cloud",
            "version": env!("CARGO_PKG_VERSION"),
            "max_file_size": 5u64 * 1024 * 1024 * 1024,
            "default_expiry_seconds": 86400,
            "max_expiry_seconds": 2592000,
            "relay": true
        })
    );

    // Create
    let before = Utc::now();
    let created =
        h.api(Method::POST, "/api/drops", json!({"expires_in": 3600, "title": "Holiday <pics>"}).to_string()).await;
    assert_eq!(created.status, StatusCode::CREATED);
    let created = created.json();
    let id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(id.len(), 8);
    assert!(id.chars().all(|c| c.is_ascii_alphanumeric()));
    assert_eq!(created["url"], format!("{PUBLIC_URL}/{id}"));
    let expires_at = created["expires_at"].as_str().unwrap();
    assert!(expires_at.ends_with('Z') && !expires_at.contains('.'), "{expires_at}");
    let expires = chrono::DateTime::parse_from_rfc3339(expires_at).unwrap();
    let delta = (expires.with_timezone(&Utc) - before).num_seconds();
    assert!((3598..=3601).contains(&delta), "{delta}");

    // Upload
    let up = h.upload(&id, "hello%20world.txt", "Hello, old world!").await;
    assert_eq!(up.status, StatusCode::CREATED, "{}", up.text());
    let up = h.upload(&id, "hello%20world.txt", "Hello, world!").await;
    assert_eq!(up.status, StatusCode::CREATED);
    assert_eq!(
        up.json(),
        json!({"name": "hello world.txt", "size": 13, "url": format!("{PUBLIC_URL}/{id}/hello%20world.txt")})
    );
    let png = h.upload(&id, "pic.png", vec![0x89u8, b'P', b'N', b'G', 1, 2, 3]).await;
    assert_eq!(png.status, StatusCode::CREATED);
    let page_html = h.upload(&id, "evil.html", "<script>alert(1)</script>").await;
    assert_eq!(page_html.status, StatusCode::CREATED);
    let unicode = h.upload(&id, "r%C3%A9sum%C3%A9%20%231%3F.pdf", "%PDF-1.4").await;
    assert_eq!(unicode.status, StatusCode::CREATED);
    assert_eq!(unicode.json()["name"], "résumé #1?.pdf");
    assert_eq!(unicode.json()["url"], format!("{PUBLIC_URL}/{id}/r%C3%A9sum%C3%A9%20%231%3F.pdf"));

    // List
    let other = h.create(json!({})).await;
    let list = h.api(Method::GET, "/api/drops", Body::empty()).await;
    assert_eq!(list.status, StatusCode::OK);
    let list = list.json();
    let ids: Vec<&str> = list.as_array().unwrap().iter().map(|d| d["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), 2);
    assert!(ids.contains(&id.as_str()) && ids.contains(&other.as_str()));
    let ours = list.as_array().unwrap().iter().find(|d| d["id"] == id.as_str()).unwrap();
    assert_eq!(ours["title"], "Holiday <pics>");
    assert_eq!(ours["url"], format!("{PUBLIC_URL}/{id}"));
    assert_eq!(ours["expires_at"], expires_at);
    assert!(ours["created_at"].as_str().unwrap().ends_with('Z'));
    assert_eq!(
        ours["files"],
        json!([
            {"name": "hello world.txt", "size": 13},
            {"name": "pic.png", "size": 7},
            {"name": "evil.html", "size": 25},
            {"name": "résumé #1?.pdf", "size": 8}
        ])
    );
    let theirs = list.as_array().unwrap().iter().find(|d| d["id"] == other.as_str()).unwrap();
    assert_eq!(theirs["title"], Value::Null);
    assert_eq!(theirs["files"], json!([]));

    // Public page
    let page = h.get(&format!("/{id}"), &[]).await;
    assert_eq!(page.status, StatusCode::OK);
    assert_eq!(page.header("content-type"), "text/html; charset=utf-8");
    assert_eq!(page.header("referrer-policy"), "no-referrer");
    assert_eq!(page.header("x-content-type-options"), "nosniff");
    assert!(page.header("content-security-policy").contains("default-src 'none'"));
    let html = page.text();
    assert!(html.contains("Holiday &lt;pics&gt;"));
    assert!(html.contains("hello world.txt"));
    assert!(html.contains(&format!("/{id}/pic.png?inline=1")));
    assert!(html.contains("Shared with Test Cloud"));
    assert!(html.contains("4 files"));

    // Download: attachment by default
    let file = h.get(&format!("/{id}/hello%20world.txt"), &[]).await;
    assert_eq!(file.status, StatusCode::OK);
    assert_eq!(file.text(), "Hello, world!");
    assert_eq!(file.header("content-type"), "text/plain; charset=utf-8");
    assert_eq!(file.header("content-length"), "13");
    assert_eq!(file.header("x-content-type-options"), "nosniff");
    assert_eq!(file.header("accept-ranges"), "bytes");
    assert_eq!(
        file.header("content-disposition"),
        "attachment; filename=\"hello world.txt\"; filename*=UTF-8''hello%20world.txt"
    );

    // Inline only for safe types
    let inline = h.get(&format!("/{id}/pic.png?inline=1"), &[]).await;
    assert_eq!(inline.status, StatusCode::OK);
    assert_eq!(inline.header("content-type"), "image/png");
    assert!(inline.header("content-disposition").starts_with("inline;"));
    let unsafe_inline = h.get(&format!("/{id}/evil.html?inline=1"), &[]).await;
    assert_eq!(unsafe_inline.header("content-type"), "text/html");
    assert!(unsafe_inline.header("content-disposition").starts_with("attachment;"));
    assert_eq!(unsafe_inline.header("x-content-type-options"), "nosniff");
    let pdf = h.get(&format!("/{id}/r%C3%A9sum%C3%A9%20%231%3F.pdf?inline=1"), &[]).await;
    assert_eq!(pdf.status, StatusCode::OK);
    assert_eq!(pdf.text(), "%PDF-1.4");
    assert!(pdf.header("content-disposition").starts_with("inline;"));

    // Ranges
    let part = h.get(&format!("/{id}/hello%20world.txt"), &[("range", "bytes=7-11")]).await;
    assert_eq!(part.status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(part.text(), "world");
    assert_eq!(part.header("content-range"), "bytes 7-11/13");
    assert_eq!(part.header("content-length"), "5");
    let tail = h.get(&format!("/{id}/hello%20world.txt"), &[("range", "bytes=-1")]).await;
    assert_eq!((tail.status, tail.text().as_str()), (StatusCode::PARTIAL_CONTENT, "!"));
    let bad = h.get(&format!("/{id}/hello%20world.txt"), &[("range", "bytes=50-")]).await;
    assert_eq!(bad.status, StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(bad.header("content-range"), "bytes */13");

    // Unknown file in a live drop
    assert_eq!(h.get(&format!("/{id}/nope.txt"), &[]).await.status, StatusCode::NOT_FOUND);

    // Delete
    let deleted = h.api(Method::DELETE, &format!("/api/drops/{id}"), Body::empty()).await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT);
    assert!(deleted.body.is_empty());
    let gone = h.get(&format!("/{id}"), &[]).await;
    assert_eq!(gone.status, StatusCode::NOT_FOUND);
    assert!(gone.text().contains("Not found"));
    assert_eq!(h.get(&format!("/{id}/hello%20world.txt"), &[]).await.status, StatusCode::NOT_FOUND);
    let again = h.api(Method::DELETE, &format!("/api/drops/{id}"), Body::empty()).await;
    assert_eq!(again.status, StatusCode::NOT_FOUND);
    assert!(again.json()["error"].is_string());
    assert_eq!(h.upload(&id, "late.txt", "x").await.status, StatusCode::NOT_FOUND);
    assert!(!h.dir.path().join("drops").join(&id).exists(), "drop directory should be removed");

    let list = h.api(Method::GET, "/api/drops", Body::empty()).await.json();
    assert_eq!(list.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn requires_a_valid_token() {
    let h = harness(&[]);
    for auth in [None, Some("Bearer wrong-token-0123456789"), Some(TOKEN), Some("Basic dGVzdA==")] {
        for (method, uri) in [(Method::GET, "/api/info"), (Method::GET, "/api/drops"), (Method::POST, "/api/drops")] {
            let mut request = Request::builder().method(method).uri(uri);
            if let Some(auth) = auth {
                request = request.header(header::AUTHORIZATION, auth);
            }
            let reply = h.send(request.body(Body::empty()).unwrap()).await;
            assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "{uri} with {auth:?}");
            assert_eq!(reply.json()["error"], "missing or invalid API token");
            assert_eq!(reply.header("www-authenticate"), "Bearer");
        }
    }
    let reply = h.send(Request::put("/api/drops/abcdefgh/files/a.txt").body(Body::from("x")).unwrap()).await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED);

    let unknown = h.api(Method::GET, "/api/nope", Body::empty()).await;
    assert_eq!(unknown.status, StatusCode::NOT_FOUND);
    assert!(unknown.json()["error"].is_string());
}

#[tokio::test]
async fn enforces_max_file_size_while_streaming() {
    let h = harness(&[("MAX_FILE_SIZE", "10")]);
    let id = h.create(json!({})).await;

    // Rejected up front from Content-Length.
    let request = Request::put(format!("/api/drops/{id}/files/big.bin"))
        .header(header::AUTHORIZATION, format!("Bearer {TOKEN}"))
        .header(header::CONTENT_LENGTH, "11")
        .body(Body::from(vec![0u8; 11]))
        .unwrap();
    let reply = h.send(request).await;
    assert_eq!(reply.status, StatusCode::PAYLOAD_TOO_LARGE);
    assert!(reply.json()["error"].as_str().unwrap().contains("10 bytes"));

    // Rejected mid-stream when there is no Content-Length.
    let chunks = futures_util::stream::iter([
        Ok::<_, std::io::Error>(Bytes::from_static(b"123456")),
        Ok(Bytes::from_static(b"78901")),
    ]);
    let reply = h.upload(&id, "big.bin", Body::from_stream(chunks)).await;
    assert_eq!(reply.status, StatusCode::PAYLOAD_TOO_LARGE);

    let exact = h.upload(&id, "ok.bin", vec![7u8; 10]).await;
    assert_eq!(exact.status, StatusCode::CREATED);

    let list = h.api(Method::GET, "/api/drops", Body::empty()).await.json();
    assert_eq!(list[0]["files"], json!([{"name": "ok.bin", "size": 10}]));
    assert_eq!(h.get(&format!("/{id}/big.bin"), &[]).await.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn streams_large_uploads_and_ranges() {
    let h = harness(&[]);
    let id = h.create(json!({"title": "Big"})).await;
    // Larger than axum's default body limit and the multipart part size.
    let data: Vec<u8> = (0..9 * 1024 * 1024 + 123).map(|i| (i % 251) as u8).collect();
    let chunks: Vec<Result<Bytes, std::io::Error>> =
        data.chunks(64 * 1024).map(|c| Ok(Bytes::copy_from_slice(c))).collect();
    let reply = h.upload(&id, "movie.mp4", Body::from_stream(futures_util::stream::iter(chunks))).await;
    assert_eq!(reply.status, StatusCode::CREATED, "{}", reply.text());
    assert_eq!(reply.json()["size"], data.len());

    let full = h.get(&format!("/{id}/movie.mp4?inline=1"), &[]).await;
    assert_eq!(full.status, StatusCode::OK);
    assert_eq!(full.header("content-type"), "video/mp4");
    assert!(full.header("content-disposition").starts_with("inline;"));
    assert_eq!(full.body.as_ref(), data.as_slice());

    let start = 8 * 1024 * 1024 - 10;
    let part = h.get(&format!("/{id}/movie.mp4"), &[("range", &format!("bytes={start}-"))]).await;
    assert_eq!(part.status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(part.header("content-range"), format!("bytes {start}-{}/{}", data.len() - 1, data.len()));
    assert_eq!(part.body.as_ref(), &data[start..]);
}

#[tokio::test]
async fn expired_drops_are_dead_immediately() {
    let h = harness(&[]);
    let id = "Expired1".to_owned();
    let mut meta = DropMeta::new(id.clone(), None, Utc::now() - Duration::hours(2), 3600);
    meta.upsert_file(FileMeta { name: "a.txt".into(), size: 1, content_type: "text/plain".into() });
    h.state.storage.save(&meta).await.unwrap();
    std::fs::create_dir_all(h.dir.path().join(format!("drops/{id}/files"))).unwrap();
    std::fs::write(h.dir.path().join(format!("drops/{id}/files/a.txt")), "a").unwrap();
    let live = h.create(json!({})).await;

    assert_eq!(h.get(&format!("/{id}"), &[]).await.status, StatusCode::NOT_FOUND);
    assert_eq!(h.get(&format!("/{id}/a.txt"), &[]).await.status, StatusCode::NOT_FOUND);
    assert_eq!(h.upload(&id, "b.txt", "b").await.status, StatusCode::NOT_FOUND);
    let list = h.api(Method::GET, "/api/drops", Body::empty()).await.json();
    assert_eq!(list.as_array().unwrap().len(), 1);
    assert_eq!(list[0]["id"], live.as_str());

    assert_eq!(h.state.storage.sweep(Utc::now()).await.unwrap(), 1);
    assert!(!h.dir.path().join(format!("drops/{id}")).exists());
    assert!(h.state.storage.load(&live).await.unwrap().is_some());
    assert_eq!(h.api(Method::DELETE, &format!("/api/drops/{id}"), Body::empty()).await.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn validates_input() {
    let h = harness(&[("MAX_EXPIRY", "7200")]);

    // Defaults and clamping.
    let empty = h.api(Method::POST, "/api/drops", Body::empty()).await;
    assert_eq!(empty.status, StatusCode::CREATED);
    let short = h.api(Method::POST, "/api/drops", json!({"expires_in": 5}).to_string()).await.json();
    let long = h.api(Method::POST, "/api/drops", json!({"expires_in": 999999999}).to_string()).await.json();
    let lifetime = |v: &Value| {
        let t = chrono::DateTime::parse_from_rfc3339(v["expires_at"].as_str().unwrap()).unwrap();
        (t.with_timezone(&Utc) - Utc::now()).num_seconds()
    };
    assert!((55..=60).contains(&lifetime(&short)));
    assert!((7195..=7200).contains(&lifetime(&long)), "default expiry is clamped to MAX_EXPIRY too");
    assert!((7195..=7200).contains(&lifetime(&empty.json())));

    let bad = h.api(Method::POST, "/api/drops", "{not json").await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);
    assert!(bad.json()["error"].is_string());

    let id = short["id"].as_str().unwrap();
    for name in ["a%2Fb", "..", "%2E", "a%00b", "a%5Cb", "%0A", &"x".repeat(256)] {
        let reply = h.upload(id, name, "x").await;
        assert_eq!(reply.status, StatusCode::BAD_REQUEST, "{name}");
        assert!(reply.json()["error"].is_string());
    }
    assert_eq!(h.upload("abcdefgh", "a.txt", "x").await.status, StatusCode::NOT_FOUND);
    assert_eq!(h.upload("bad-id", "a.txt", "x").await.status, StatusCode::NOT_FOUND);
    assert_eq!(h.get("/nope", &[]).await.status, StatusCode::NOT_FOUND);
    assert_eq!(h.get("/a/b/c", &[]).await.status, StatusCode::NOT_FOUND);
    assert_eq!(h.get("/", &[]).await.status, StatusCode::OK);
}

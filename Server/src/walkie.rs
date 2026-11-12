//! Walkie: end-to-end encrypted voice notes, files and to-dos between Macs.
//!
//! Every Mac owns a mailbox. Its address (the box id) is
//! `hex(SHA-256("XNotch Walkie box v1" || 0x00 || secret))`, where the 32-byte
//! secret never leaves that Mac except as the bearer credential for reading the
//! mailbox. Contacts post to it with a separate send token they got from an
//! invite. Everything posted is sealed by XNotch (X-Wing post-quantum HPKE,
//! signed with ML-DSA-65 and Ed25519), so the server stores and forwards opaque
//! bytes; see `docs/WALKIE.md`.
//!
//! Registering a mailbox needs the server's API token, as creating a drop does.
//! Posting, reading and listening need only the mailbox's own credentials, so a
//! contact on another server can still reach it.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use axum::Json;
use axum::body::{Body, Bytes};
use axum::extract::rejection::PathRejection;
use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, SubsecRound, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::sync::broadcast;

use crate::config::WalkieConfig;
use crate::error::ApiError;
use crate::model::{WalkieBox, format_time};
use crate::storage::{Storage, WriteError};
use crate::{AppState, SharedState};

/// Longest public card a mailbox can publish (public keys, name, small avatar).
pub const MAX_CARD_BYTES: usize = 96 * 1024;
/// Most mailboxes a single presence request may ask about.
const MAX_PRESENCE_BOXES: usize = 64;
const BOX_DOMAIN: &[u8] = b"XNotch Walkie box v1\0";
const POST_DOMAIN: &[u8] = b"XNotch Walkie post v1\0";
/// Server pings on listening sockets, so proxies keep them open.
const PING_INTERVAL: Duration = Duration::from_secs(20);
const EVENT_BACKLOG: usize = 64;

/// A box id, a message id's random part or a credential: lowercase hex.
fn is_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn is_valid_box(id: &str) -> bool {
    is_hex(id, 64)
}

/// 16 hex digits of milliseconds since 1970, then 16 random hex digits; sorts by arrival.
pub fn is_valid_message_id(id: &str) -> bool {
    is_hex(id, 32)
}

fn decode_hex32(text: &str) -> Option<[u8; 32]> {
    if !is_hex(text, 64) {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in text.as_bytes().chunks(2).enumerate() {
        let s = std::str::from_utf8(chunk).ok()?;
        out[i] = u8::from_str_radix(s, 16).ok()?;
    }
    Some(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The box id a mailbox secret opens.
pub fn box_for_secret(secret: &[u8; 32]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(BOX_DOMAIN);
    hasher.update(secret);
    hex(&hasher.finalize())
}

/// What the server keeps of a send token.
pub fn post_token_hash(token: &[u8; 32]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(POST_DOMAIN);
    hasher.update(token);
    hex(&hasher.finalize())
}

fn new_message_id(now: DateTime<Utc>) -> String {
    let millis = now.timestamp_millis().max(0) as u64;
    let random: u64 = rand::random();
    format!("{millis:016x}{random:016x}")
}

/// When a message arrived, from its id.
pub fn message_time(id: &str) -> Option<DateTime<Utc>> {
    let millis = u64::from_str_radix(id.get(..16)?, 16).ok()?;
    DateTime::from_timestamp_millis(i64::try_from(millis).ok()?)
}

#[derive(Clone, Debug)]
enum Event {
    /// A message was stored: `{"type":"message","id":…,"size":…}`.
    Message { id: String, size: u64 },
    /// A sealed signal (someone is talking), forwarded and never stored.
    Signal(Bytes),
}

struct LiveBox {
    record: WalkieBox,
    events: broadcast::Sender<Event>,
    /// Messages waiting, as far as this process knows.
    pending: usize,
    /// When the last listener left; `None` while one is connected or never was.
    last_seen: Option<DateTime<Utc>>,
}

impl LiveBox {
    fn new(record: WalkieBox, pending: usize) -> Self {
        let (events, _) = broadcast::channel(EVENT_BACKLOG);
        Self { record, events, pending, last_seen: None }
    }

    fn online(&self) -> bool {
        self.events.receiver_count() > 0
    }
}

pub struct Walkie {
    config: WalkieConfig,
    boxes: Mutex<HashMap<String, LiveBox>>,
}

impl Walkie {
    pub fn new(config: WalkieConfig) -> Self {
        Self { config, boxes: Mutex::default() }
    }

    pub fn enabled(&self) -> bool {
        self.config.enabled
    }

    pub fn max_message(&self) -> u64 {
        self.config.max_message
    }

    fn boxes(&self) -> MutexGuard<'_, HashMap<String, LiveBox>> {
        self.boxes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Loads the registered mailboxes from storage. Returns how many there are.
    pub async fn load(&self, storage: &Storage) -> object_store::Result<usize> {
        let mut loaded = Vec::new();
        for id in storage.list_walkie_boxes().await? {
            match storage.load_walkie_box(&id).await {
                Ok(Some(record)) => {
                    let pending = storage.list_walkie_messages(&id).await.map(|m| m.len()).unwrap_or(0);
                    loaded.push((id, record, pending));
                }
                Ok(None) => {}
                Err(e) => tracing::warn!(error = %e, "skipping unreadable walkie mailbox"),
            }
        }
        let mut boxes = self.boxes();
        for (id, record, pending) in loaded {
            boxes.entry(id).or_insert_with(|| LiveBox::new(record, pending));
        }
        Ok(boxes.len())
    }

    /// Removes messages older than the retention. Returns how many went.
    pub async fn sweep(&self, storage: &Storage, now: DateTime<Utc>) -> object_store::Result<usize> {
        let cutoff = now - chrono::Duration::from_std(self.config.retention).unwrap_or(chrono::Duration::days(7));
        let ids: Vec<String> = self.boxes().keys().cloned().collect();
        let mut removed = 0;
        for id in ids {
            let messages = storage.list_walkie_messages(&id).await?;
            let mut left = messages.len();
            for (message, _) in messages {
                if message_time(&message).is_none_or(|t| t < cutoff) {
                    storage.delete_walkie_message(&id, &message).await?;
                    removed += 1;
                    left -= 1;
                }
            }
            if let Some(entry) = self.boxes().get_mut(&id) {
                entry.pending = left;
            }
        }
        Ok(removed)
    }
}

// MARK: Credentials

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().split_once(' '))
        .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer"))
        .map(|(_, token)| token.trim())
}

fn box_param(state: &AppState, path: Result<Path<String>, PathRejection>) -> Result<String, ApiError> {
    if !state.walkie.enabled() {
        return Err(ApiError::NotFound("endpoint"));
    }
    let Path(id) = path.map_err(|e| ApiError::BadRequest(e.body_text()))?;
    if !is_valid_box(&id) {
        return Err(ApiError::NotFound("mailbox"));
    }
    Ok(id)
}

/// The owner's secret: its hash must be the box id.
fn check_secret(id: &str, presented: Option<&str>) -> Result<(), ApiError> {
    let secret = presented.and_then(decode_hex32).ok_or(ApiError::Unauthorized)?;
    if bool::from(box_for_secret(&secret).as_bytes().ct_eq(id.as_bytes())) {
        Ok(())
    } else {
        Err(ApiError::Unauthorized)
    }
}

/// A send token for a registered mailbox. Unknown boxes and wrong tokens look alike.
fn check_post_token(state: &AppState, id: &str, presented: Option<&str>) -> Result<(), ApiError> {
    let token = presented.and_then(decode_hex32).ok_or(ApiError::Unauthorized)?;
    let hash = post_token_hash(&token);
    let boxes = state.walkie.boxes();
    let expected = boxes.get(id).map(|b| b.record.post_token_hash.clone()).unwrap_or_default();
    if !expected.is_empty() && bool::from(expected.as_bytes().ct_eq(hash.as_bytes())) {
        Ok(())
    } else {
        Err(ApiError::Unauthorized)
    }
}

fn storage_error(context: &'static str) -> impl FnOnce(object_store::Error) -> ApiError {
    move |e| ApiError::internal(context, e)
}

// MARK: Owner routes (API token)

#[derive(Deserialize)]
pub struct Register {
    /// 64 hex characters; contacts present it to post.
    post_token: String,
    /// The owner's signed public card, base64. Served to holders of the send token.
    card: Option<String>,
    /// List the mailbox (card and send token) to everyone holding the API token.
    #[serde(default)]
    listed: bool,
}

/// `PUT /api/walkie/boxes/{box}` (API token, plus the mailbox secret in `X-Walkie-Secret`).
pub async fn register(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let id = box_param(&state, path)?;
    check_secret(&id, headers.get("x-walkie-secret").and_then(|v| v.to_str().ok()))?;
    let request: Register =
        serde_json::from_slice(&body).map_err(|e| ApiError::BadRequest(format!("invalid JSON body: {e}")))?;
    let token = decode_hex32(&request.post_token)
        .ok_or_else(|| ApiError::BadRequest("post_token must be 64 lowercase hex characters".into()))?;
    if request.card.as_ref().is_some_and(|c| c.len() > MAX_CARD_BYTES) {
        return Err(ApiError::BadRequest(format!("card must be at most {MAX_CARD_BYTES} bytes")));
    }

    let storage = &state.storage;
    let _guard = storage.lock(&id).await;
    let created_at = state.walkie.boxes().get(&id).map_or_else(|| Utc::now().trunc_subsecs(0), |b| b.record.created_at);
    let record = WalkieBox {
        created_at,
        post_token_hash: post_token_hash(&token),
        listed_post_token: request.listed.then(|| request.post_token.clone()),
        card: request.card,
    };
    storage.save_walkie_box(&id, &record).await.map_err(storage_error("failed to save mailbox"))?;
    let mut boxes = state.walkie.boxes();
    match boxes.get_mut(&id) {
        Some(entry) => entry.record = record,
        None => {
            boxes.insert(id.clone(), LiveBox::new(record, 0));
            tracing::info!(mailbox = &id[..6], "walkie mailbox registered");
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /api/walkie/boxes/{box}` (API token and secret). Removes its messages too.
pub async fn unregister(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let id = box_param(&state, path)?;
    check_secret(&id, headers.get("x-walkie-secret").and_then(|v| v.to_str().ok()))?;
    let storage = &state.storage;
    let _guard = storage.lock(&id).await;
    storage.purge_walkie_box(&id).await.map_err(storage_error("failed to delete mailbox"))?;
    // Dropping the entry closes its event channel, which ends every listener.
    state.walkie.boxes().remove(&id);
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
pub struct Listed {
    #[serde(rename = "box")]
    id: String,
    card: String,
    post_token: String,
}

/// `GET /api/walkie/directory` (API token): the mailboxes that chose to be listed.
pub async fn directory(State(state): State<SharedState>) -> Result<Json<Vec<Listed>>, ApiError> {
    if !state.walkie.enabled() {
        return Err(ApiError::NotFound("endpoint"));
    }
    let boxes = state.walkie.boxes();
    let mut listed: Vec<(DateTime<Utc>, Listed)> = boxes
        .iter()
        .filter_map(|(id, b)| {
            Some((
                b.record.created_at,
                Listed {
                    id: id.clone(),
                    card: b.record.card.clone()?,
                    post_token: b.record.listed_post_token.clone()?,
                },
            ))
        })
        .collect();
    listed.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.id.cmp(&b.1.id)));
    Ok(Json(listed.into_iter().map(|(_, l)| l).collect()))
}

// MARK: Contact routes (send token)

/// `GET /api/walkie/boxes/{box}/card` (send token): the owner's public card.
pub async fn card(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let id = box_param(&state, path)?;
    check_post_token(&state, &id, bearer(&headers))?;
    let card = state.walkie.boxes().get(&id).and_then(|b| b.record.card.clone()).ok_or(ApiError::NotFound("card"))?;
    Ok(Json(serde_json::json!({ "card": card })).into_response())
}

#[derive(Serialize)]
struct Posted {
    id: String,
    /// Whether the owner was listening when it arrived.
    delivered: bool,
}

/// `POST /api/walkie/boxes/{box}/messages` (send token): stores a sealed message.
pub async fn post_message(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    let id = box_param(&state, path)?;
    check_post_token(&state, &id, bearer(&headers))?;
    let max = state.walkie.max_message();
    let declared =
        headers.get(header::CONTENT_LENGTH).and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|len| len > max) {
        return Err(ApiError::PayloadTooLarge(max));
    }
    {
        let boxes = state.walkie.boxes();
        if boxes.get(&id).is_some_and(|b| b.pending >= state.walkie.config.max_pending) {
            return Err(ApiError::TooManyRequests(60));
        }
    }

    let now = Utc::now();
    let message = new_message_id(now);
    let size = match state.storage.write_walkie_message(&id, &message, body.into_data_stream(), max).await {
        Ok(size) => size,
        Err(WriteError::TooLarge) => return Err(ApiError::PayloadTooLarge(max)),
        Err(WriteError::Body(e)) => return Err(ApiError::BadRequest(format!("failed to read request body: {e}"))),
        Err(WriteError::Storage(e)) => return Err(ApiError::internal("failed to store message", e)),
    };

    // `None`: unregistered while the body streamed.
    let delivered = state.walkie.boxes().get_mut(&id).map(|entry| {
        entry.pending += 1;
        entry.events.send(Event::Message { id: message.clone(), size }).is_ok()
    });
    let Some(delivered) = delivered else {
        let _ = state.storage.delete_walkie_message(&id, &message).await;
        return Err(ApiError::NotFound("mailbox"));
    };
    tracing::debug!(mailbox = &id[..6], size, delivered, "walkie message stored");
    Ok((StatusCode::CREATED, Json(Posted { id: message, delivered })).into_response())
}

/// `POST /api/walkie/boxes/{box}/signals` (send token): a small sealed signal,
/// such as "I'm talking to you", passed to whoever listens and never stored.
pub async fn post_signal(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    let id = box_param(&state, path)?;
    check_post_token(&state, &id, bearer(&headers))?;
    let max = state.walkie.config.max_signal;
    if body.len() > max {
        return Err(ApiError::PayloadTooLarge(max as u64));
    }
    let delivered = state.walkie.boxes().get(&id).is_some_and(|b| b.events.send(Event::Signal(body)).is_ok());
    Ok((StatusCode::ACCEPTED, Json(serde_json::json!({ "delivered": delivered }))).into_response())
}

#[derive(Deserialize)]
pub struct PresenceQuery {
    boxes: Vec<PresenceAsk>,
}

#[derive(Deserialize)]
struct PresenceAsk {
    #[serde(rename = "box")]
    id: String,
    token: String,
}

#[derive(Serialize)]
struct PresenceAnswer {
    #[serde(rename = "box")]
    id: String,
    online: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_seen: Option<String>,
}

/// `POST /api/walkie/presence`: which of these mailboxes is listening right now.
/// Each entry needs its send token; entries with a wrong one are left out.
pub async fn presence(State(state): State<SharedState>, body: Bytes) -> Result<Response, ApiError> {
    if !state.walkie.enabled() {
        return Err(ApiError::NotFound("endpoint"));
    }
    let query: PresenceQuery =
        serde_json::from_slice(&body).map_err(|e| ApiError::BadRequest(format!("invalid JSON body: {e}")))?;
    if query.boxes.len() > MAX_PRESENCE_BOXES {
        return Err(ApiError::BadRequest(format!("ask about at most {MAX_PRESENCE_BOXES} mailboxes")));
    }
    let answers: Vec<PresenceAnswer> = query
        .boxes
        .into_iter()
        .filter(|ask| is_valid_box(&ask.id) && check_post_token(&state, &ask.id, Some(&ask.token)).is_ok())
        .filter_map(|ask| {
            let boxes = state.walkie.boxes();
            let entry = boxes.get(&ask.id)?;
            Some(PresenceAnswer {
                online: entry.online(),
                last_seen: entry.last_seen.map(|t| format_time(&t)),
                id: ask.id,
            })
        })
        .collect();
    Ok(Json(serde_json::json!({ "boxes": answers })).into_response())
}

// MARK: Owner's inbox (mailbox secret)

#[derive(Serialize)]
struct Waiting {
    id: String,
    size: u64,
}

/// `GET /api/walkie/boxes/{box}/messages` (secret): waiting messages, oldest first.
pub async fn list_messages(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let id = box_param(&state, path)?;
    check_secret(&id, bearer(&headers))?;
    let mut messages =
        state.storage.list_walkie_messages(&id).await.map_err(storage_error("failed to list messages"))?;
    messages.sort();
    if let Some(entry) = state.walkie.boxes().get_mut(&id) {
        entry.pending = messages.len();
    }
    let messages: Vec<Waiting> = messages.into_iter().map(|(id, size)| Waiting { id, size }).collect();
    Ok(Json(serde_json::json!({ "messages": messages })).into_response())
}

fn message_params(
    state: &AppState,
    path: Result<Path<(String, String)>, PathRejection>,
) -> Result<(String, String), ApiError> {
    if !state.walkie.enabled() {
        return Err(ApiError::NotFound("endpoint"));
    }
    let Path((id, message)) = path.map_err(|e| ApiError::BadRequest(e.body_text()))?;
    if !is_valid_box(&id) || !is_valid_message_id(&message) {
        return Err(ApiError::NotFound("message"));
    }
    Ok((id, message))
}

/// `GET /api/walkie/boxes/{box}/messages/{id}` (secret): the sealed bytes.
pub async fn get_message(
    State(state): State<SharedState>,
    path: Result<Path<(String, String)>, PathRejection>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let (id, message) = message_params(&state, path)?;
    check_secret(&id, bearer(&headers))?;
    let bytes = state
        .storage
        .read_walkie_message(&id, &message)
        .await
        .map_err(storage_error("failed to read message"))?
        .ok_or(ApiError::NotFound("message"))?;
    Ok(([(header::CONTENT_TYPE, "application/octet-stream"), (header::CACHE_CONTROL, "no-store")], bytes)
        .into_response())
}

/// `DELETE /api/walkie/boxes/{box}/messages/{id}` (secret): after it was opened.
pub async fn delete_message(
    State(state): State<SharedState>,
    path: Result<Path<(String, String)>, PathRejection>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let (id, message) = message_params(&state, path)?;
    check_secret(&id, bearer(&headers))?;
    state.storage.delete_walkie_message(&id, &message).await.map_err(storage_error("failed to delete message"))?;
    if let Some(entry) = state.walkie.boxes().get_mut(&id) {
        entry.pending = entry.pending.saturating_sub(1);
    }
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /api/walkie/boxes/{box}/listen` (secret, WebSocket): new messages as JSON
/// text frames, signals as binary frames. While a socket listens the mailbox
/// shows as online to its contacts.
pub async fn listen(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let id = match box_param(&state, path) {
        Ok(id) => id,
        Err(e) => return e.into_response(),
    };
    if let Err(e) = check_secret(&id, bearer(&headers)) {
        return e.into_response();
    }
    let Some(events) = state.walkie.boxes().get(&id).map(|b| b.events.subscribe()) else {
        return ApiError::NotFound("mailbox").into_response();
    };
    let upgrade = match upgrade {
        Ok(upgrade) => upgrade,
        Err(rejection) => return rejection.into_response(),
    };
    upgrade.max_message_size(4096).on_upgrade(move |socket| async move {
        run_listener(socket, events).await;
        if let Some(entry) = state.walkie.boxes().get_mut(&id) {
            entry.last_seen = Some(Utc::now().trunc_subsecs(0));
        }
    })
}

async fn run_listener(mut socket: WebSocket, mut events: broadcast::Receiver<Event>) {
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await;
    loop {
        tokio::select! {
            event = events.recv() => match event {
                Ok(Event::Message { id, size }) => {
                    let text = serde_json::json!({ "type": "message", "id": id, "size": size }).to_string();
                    if socket.send(Message::Text(text.into())).await.is_err() { return; }
                }
                Ok(Event::Signal(bytes)) => {
                    if socket.send(Message::Binary(bytes)).await.is_err() { return; }
                }
                // Fell behind: the client lists the mailbox to catch up.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    let text = serde_json::json!({ "type": "resync" }).to_string();
                    if socket.send(Message::Text(text.into())).await.is_err() { return; }
                }
                Err(broadcast::error::RecvError::Closed) => {
                    let _ = socket.send(Message::Close(None)).await;
                    return;
                }
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return,
                Some(Ok(_)) => {}
            },
            _ = ping.tick() => {
                if socket.send(Message::Ping(Bytes::new())).await.is_err() { return; }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_box_ids_and_hashes() {
        let secret = [0xabu8; 32];
        let id = box_for_secret(&secret);
        assert!(is_valid_box(&id));
        assert!(check_secret(&id, Some(&hex(&secret))).is_ok());
        assert!(check_secret(&id, Some(&hex(&[8u8; 32]))).is_err());
        assert!(check_secret(&id, Some(&hex(&secret).to_uppercase())).is_err());
        assert!(check_secret(&id, None).is_err());
        assert_ne!(post_token_hash(&secret), id, "domains keep the two hashes apart");
    }

    #[test]
    fn message_ids_sort_by_time() {
        let early = new_message_id(DateTime::from_timestamp(1_700_000_000, 0).unwrap());
        let late = new_message_id(DateTime::from_timestamp(1_800_000_000, 0).unwrap());
        assert!(is_valid_message_id(&early) && is_valid_message_id(&late));
        assert!(early < late);
        assert_eq!(message_time(&early).unwrap().timestamp(), 1_700_000_000);
    }
}

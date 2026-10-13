//! WebSocket relay that lets an iPhone reach a Mac on another network.
//!
//! Both sides connect out to `GET /api/relay/rooms/{room}/connect`. A Mac socket
//! waits in its room's pool; a phone takes the oldest waiting Mac and from then on
//! every data message is forwarded verbatim in both directions. Payloads are
//! end-to-end encrypted by XNotch, so the server never looks inside them.
//!
//! Rooms are registered by the Mac through the authenticated API and persisted at
//! `relay/rooms/{room}`; the 256-bit room id itself is the credential for connecting.

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use axum::extract::rejection::{PathRejection, QueryRejection};
use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{CloseFrame, Message, Utf8Bytes, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::{StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use chrono::{SubsecRound, Utc};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore, oneshot, watch};
use tokio::time::{Instant, Interval, MissedTickBehavior, interval_at, sleep_until, timeout};

use crate::config::RelayConfig;
use crate::error::ApiError;
use crate::model::RelayRoom;
use crate::storage::Storage;
use crate::{AppState, SharedState};

/// WebSocket close codes sent by the relay.
pub mod close_code {
    /// The other side left, the pair was idle, or the room was removed.
    pub const NORMAL: u16 = 1000;
    /// A message exceeded `RELAY_MAX_MESSAGE`.
    pub const TOO_BIG: u16 = 1009;
    /// No Mac was waiting within `RELAY_PHONE_WAIT` (reason `mac offline`).
    pub const MAC_OFFLINE: u16 = 4404;
    /// A waiting Mac socket was replaced by a newer one in the same room.
    pub const REPLACED: u16 = 4409;
    /// `RELAY_MAX_PAIRS` or `RELAY_MAX_WAITING` reached (reason `relay busy`).
    pub const BUSY: u16 = 4503;
}

use close_code::{BUSY, MAC_OFFLINE, NORMAL, REPLACED, TOO_BIG};

/// How long the server tries to deliver a close frame and wait for the reply.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(5);
/// Characters of a room id that may appear in logs.
const LOGGED_ROOM_CHARS: usize = 6;
const ROOMS_PATH: &str = "/api/relay/rooms/";

/// A room id is 64 lowercase hex characters (256 bits derived from the pairing key).
pub fn is_valid_room(room: &str) -> bool {
    room.len() == 64 && room.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The loggable prefix of a room id.
fn short(room: &str) -> &str {
    room.get(..LOGGED_ROOM_CHARS).unwrap_or(room)
}

/// Shortens the room id in relay URIs for request logs, since it is a credential.
pub fn redact_uri(uri: &Uri) -> Cow<'_, str> {
    let Some(rest) = uri.path().strip_prefix(ROOMS_PATH) else {
        return Cow::Owned(uri.to_string());
    };
    let (room, tail) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let room: String = room.chars().take(LOGGED_ROOM_CHARS).collect();
    let query = uri.query().map(|q| format!("?{q}")).unwrap_or_default();
    Cow::Owned(format!("{ROOMS_PATH}{room}…{tail}{query}"))
}

/// Storage errors name the object path; keep the full room id out of the logs.
fn redact_error(error: impl std::fmt::Display, room: &str) -> String {
    error.to_string().replace(room, &format!("{}…", short(room)))
}

pub struct Relay {
    config: RelayConfig,
    rooms: Mutex<Rooms>,
    /// One permit per connected phone, waiting or paired.
    phones: Arc<Semaphore>,
    next_id: AtomicU64,
}

#[derive(Default)]
struct Rooms {
    map: HashMap<String, Room>,
    /// Waiting Mac sockets across all rooms.
    waiting: usize,
}

struct Room {
    /// Waiting Mac sockets, oldest first.
    macs: VecDeque<WaitingMac>,
    mac_arrived: Arc<Notify>,
    /// Never sent on; dropping it with the room closes every socket of the room.
    removed: watch::Sender<()>,
}

impl Room {
    fn new() -> Self {
        Self { macs: VecDeque::new(), mac_arrived: Arc::new(Notify::new()), removed: watch::Sender::new(()) }
    }
}

struct WaitingMac {
    id: u64,
    signal: oneshot::Sender<Signal>,
}

/// Sent to a waiting Mac's task. A dropped sender means the room was removed.
enum Signal {
    Pair(Box<Phone>),
    Replaced,
}

struct Phone {
    socket: WebSocket,
    /// The first data message, if the phone sent one while waiting for a Mac.
    pending: Option<Message>,
    /// Held until the phone leaves or its pair ends.
    permit: OwnedSemaphorePermit,
    removed: watch::Receiver<()>,
}

enum Handoff {
    Paired,
    NoMac(Box<Phone>),
    RoomGone(Box<Phone>),
}

impl Relay {
    pub fn new(config: RelayConfig) -> Self {
        let phones = Arc::new(Semaphore::new(config.max_pairs));
        Self { config, rooms: Mutex::default(), phones, next_id: AtomicU64::new(0) }
    }

    pub fn enabled(&self) -> bool {
        self.config.enabled
    }

    fn rooms(&self) -> MutexGuard<'_, Rooms> {
        // The critical sections cannot leave the map inconsistent, so a poisoned lock is still usable.
        self.rooms.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn is_registered(&self, room: &str) -> bool {
        self.rooms().map.contains_key(room)
    }

    /// Mac sockets waiting in a room.
    pub fn waiting_macs(&self, room: &str) -> usize {
        self.rooms().map.get(room).map_or(0, |r| r.macs.len())
    }

    /// Loads the registered rooms from storage. Returns how many there are.
    pub async fn load(&self, storage: &Storage) -> object_store::Result<usize> {
        let rooms = storage.list_relay_rooms().await?;
        let mut guard = self.rooms();
        for room in rooms {
            guard.map.entry(room).or_insert_with(Room::new);
        }
        Ok(guard.map.len())
    }

    /// Registers a room in storage and memory. Returns false if it already existed.
    pub async fn register(&self, storage: &Storage, room: &str) -> object_store::Result<bool> {
        let _guard = storage.lock(room).await;
        if self.is_registered(room) {
            return Ok(false);
        }
        storage.save_relay_room(room, &RelayRoom { created_at: Utc::now().trunc_subsecs(0) }).await?;
        self.rooms().map.insert(room.to_owned(), Room::new());
        Ok(true)
    }

    /// Unregisters a room and closes its sockets. Returns false if it was unknown.
    pub async fn unregister(&self, storage: &Storage, room: &str) -> object_store::Result<bool> {
        let _guard = storage.lock(room).await;
        storage.delete_relay_room(room).await?;
        let removed = {
            let mut rooms = self.rooms();
            let removed = rooms.map.remove(room);
            rooms.waiting -= removed.as_ref().map_or(0, |r| r.macs.len());
            removed
        };
        // Dropping the room wakes every task of the room, outside the lock.
        Ok(removed.is_some())
    }

    /// Puts a Mac socket in its room's pool, replacing the oldest one if the room is full.
    fn add_mac(&self, room: &str, id: u64, signal: oneshot::Sender<Signal>) -> Result<(), (u16, &'static str)> {
        let mut rooms = self.rooms();
        let Rooms { map, waiting } = &mut *rooms;
        let Some(r) = map.get_mut(room) else { return Err((NORMAL, "")) };
        if r.macs.len() >= self.config.max_waiting_per_room {
            if let Some(oldest) = r.macs.pop_front() {
                let _ = oldest.signal.send(Signal::Replaced);
                *waiting -= 1;
            }
        } else if *waiting >= self.config.max_waiting {
            return Err((BUSY, "relay busy"));
        }
        r.macs.push_back(WaitingMac { id, signal });
        *waiting += 1;
        r.mac_arrived.notify_waiters();
        Ok(())
    }

    /// Takes a Mac socket out of the pool when it went away while waiting.
    fn remove_mac(&self, room: &str, id: u64) {
        let mut rooms = self.rooms();
        let Rooms { map, waiting } = &mut *rooms;
        if let Some(r) = map.get_mut(room)
            && let Some(index) = r.macs.iter().position(|m| m.id == id)
        {
            r.macs.remove(index);
            *waiting -= 1;
        }
    }

    /// Hands a phone to the oldest waiting Mac of the room.
    fn hand_to_mac(&self, room: &str, mut phone: Box<Phone>) -> Handoff {
        let mut rooms = self.rooms();
        let Rooms { map, waiting } = &mut *rooms;
        let Some(r) = map.get_mut(room) else { return Handoff::RoomGone(phone) };
        while let Some(mac) = r.macs.pop_front() {
            *waiting -= 1;
            // Sent under the lock, so a Mac that is leaving the pool still finds the phone.
            match mac.signal.send(Signal::Pair(phone)) {
                Ok(()) => return Handoff::Paired,
                // That Mac's task is gone; try the next one.
                Err(Signal::Pair(returned)) => phone = returned,
                Err(Signal::Replaced) => unreachable!("only a pair was sent"),
            }
        }
        Handoff::NoMac(phone)
    }

    fn room_signals(&self, room: &str) -> Option<(watch::Receiver<()>, Arc<Notify>)> {
        self.rooms().map.get(room).map(|r| (r.removed.subscribe(), r.mac_arrived.clone()))
    }
}

fn room_param(state: &AppState, path: Result<Path<String>, PathRejection>) -> Result<String, ApiError> {
    if !state.relay.enabled() {
        return Err(ApiError::NotFound("endpoint"));
    }
    let Path(room) = path.map_err(|e| ApiError::BadRequest(e.body_text()))?;
    if !is_valid_room(&room) {
        return Err(ApiError::BadRequest("room must be 64 lowercase hex characters".into()));
    }
    Ok(room)
}

/// `PUT /api/relay/rooms/{room}` (authenticated).
pub async fn register_room(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
) -> Result<StatusCode, ApiError> {
    let room = room_param(&state, path)?;
    let created = state
        .relay
        .register(&state.storage, &room)
        .await
        .map_err(|e| ApiError::internal("failed to register relay room", redact_error(e, &room)))?;
    if created {
        tracing::info!(room = short(&room), "relay room registered");
    }
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /api/relay/rooms/{room}` (authenticated).
pub async fn unregister_room(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
) -> Result<StatusCode, ApiError> {
    let room = room_param(&state, path)?;
    let removed = state
        .relay
        .unregister(&state.storage, &room)
        .await
        .map_err(|e| ApiError::internal("failed to unregister relay room", redact_error(e, &room)))?;
    if removed {
        tracing::info!(room = short(&room), "relay room unregistered");
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Mac,
    Phone,
}

impl Side {
    fn other(self) -> Self {
        match self {
            Self::Mac => Self::Phone,
            Self::Phone => Self::Mac,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Mac => "mac",
            Self::Phone => "phone",
        }
    }
}

#[derive(Deserialize)]
pub struct ConnectParams {
    role: Option<String>,
}

/// `GET /api/relay/rooms/{room}/connect?role=mac|phone` (no token; the room is the credential).
pub async fn connect(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    query: Result<Query<ConnectParams>, QueryRejection>,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let room = match room_param(&state, path) {
        Ok(room) => room,
        Err(e) => return e.into_response(),
    };
    let role = match query.ok().and_then(|Query(p)| p.role).as_deref() {
        Some("mac") => Side::Mac,
        Some("phone") => Side::Phone,
        _ => return ApiError::BadRequest("role must be `mac` or `phone`".into()).into_response(),
    };
    if !state.relay.is_registered(&room) {
        return ApiError::NotFound("room").into_response();
    }
    let upgrade = match upgrade {
        Ok(upgrade) => upgrade,
        Err(rejection) => return rejection.into_response(),
    };
    let max = state.config.relay.max_message;
    upgrade.max_message_size(max).max_frame_size(max).on_upgrade(move |socket| async move {
        match role {
            Side::Mac => run_mac(&state, &room, socket).await,
            Side::Phone => run_phone(&state, &room, socket).await,
        }
    })
}

/// Whether a receive error means a message was larger than `RELAY_MAX_MESSAGE`.
fn too_big(error: &axum::Error) -> bool {
    std::error::Error::source(error)
        .and_then(|e| e.downcast_ref::<tungstenite::Error>())
        .is_some_and(|e| matches!(e, tungstenite::Error::Capacity(_)))
}

fn ping_timer(period: Duration) -> Interval {
    let mut timer = interval_at(Instant::now() + period, period);
    timer.set_missed_tick_behavior(MissedTickBehavior::Delay);
    timer
}

fn ping() -> Message {
    Message::Ping(Bytes::new())
}

/// A Mac socket: waits in the pool, then carries the pair.
async fn run_mac(state: &AppState, room: &str, mut socket: WebSocket) {
    let relay = &state.relay;
    let id = relay.next_id.fetch_add(1, Ordering::Relaxed);
    let (signal_tx, mut signal_rx) = oneshot::channel();
    if let Err((code, reason)) = relay.add_mac(room, id, signal_tx) {
        if code == BUSY {
            tracing::warn!(room = short(room), "relay busy, turned a mac away");
        }
        return close(socket, code, reason).await;
    }
    tracing::debug!(room = short(room), "mac waiting");

    enum Waited {
        Signal(Option<Signal>),
        Left(Farewell),
    }
    let mut ping_timer = ping_timer(relay.config.ping_interval);
    let waited = loop {
        tokio::select! {
            signal = &mut signal_rx => break Waited::Signal(signal.ok()),
            message = socket.recv() => match message {
                Some(Ok(Message::Close(_))) => break Waited::Left(Farewell::Flush),
                None => break Waited::Left(Farewell::Drop),
                Some(Err(e)) => break Waited::Left(error_farewell(&e)),
                // Pongs, and data sent before pairing, which has nowhere to go.
                Some(Ok(_)) => {}
            },
            _ = ping_timer.tick() => {
                if socket.send(ping()).await.is_err() {
                    break Waited::Left(Farewell::Drop);
                }
            }
        }
    };

    match waited {
        Waited::Signal(Some(Signal::Pair(phone))) => run_pair(state, room, socket, phone).await,
        Waited::Signal(Some(Signal::Replaced)) => {
            tracing::debug!(room = short(room), "waiting mac replaced");
            close(socket, REPLACED, "replaced").await;
        }
        // The room was removed.
        Waited::Signal(None) => close(socket, NORMAL, "").await,
        Waited::Left(farewell) => {
            relay.remove_mac(room, id);
            // A phone may have picked this socket just before it went away.
            if let Ok(Signal::Pair(phone)) = signal_rx.try_recv() {
                close(phone.socket, NORMAL, "").await;
            }
            say_goodbye(socket, farewell).await;
        }
    }
}

/// A phone socket: takes the oldest waiting Mac, waiting up to `RELAY_PHONE_WAIT` for one.
async fn run_phone(state: &AppState, room: &str, socket: WebSocket) {
    let relay = &state.relay;
    let Ok(permit) = relay.phones.clone().try_acquire_owned() else {
        tracing::warn!(room = short(room), "relay busy, turned a phone away");
        return close(socket, BUSY, "relay busy").await;
    };
    let Some((mut removed, mac_arrived)) = relay.room_signals(room) else {
        return close(socket, NORMAL, "").await;
    };
    let deadline = Instant::now() + relay.config.phone_wait;
    let mut phone = Box::new(Phone { socket, pending: None, permit, removed: removed.clone() });
    loop {
        // Armed before looking, so a Mac that arrives in between is not missed.
        let arrived = mac_arrived.notified();
        tokio::pin!(arrived);
        arrived.as_mut().enable();
        phone = match relay.hand_to_mac(room, phone) {
            Handoff::Paired => return,
            Handoff::NoMac(phone) => phone,
            Handoff::RoomGone(phone) => return close(phone.socket, NORMAL, "").await,
        };
        tokio::select! {
            () = &mut arrived => {}
            () = sleep_until(deadline) => return close(phone.socket, MAC_OFFLINE, "mac offline").await,
            _ = removed.changed() => return close(phone.socket, NORMAL, "").await,
            // Keep the first message for the Mac, and notice a phone that gives up.
            message = phone.socket.recv(), if phone.pending.is_none() => match message {
                Some(Ok(message @ (Message::Binary(_) | Message::Text(_)))) => phone.pending = Some(message),
                Some(Ok(Message::Close(_))) => return say_goodbye(phone.socket, Farewell::Flush).await,
                None => return,
                Some(Err(e)) => return say_goodbye(phone.socket, error_farewell(&e)).await,
                Some(Ok(_)) => {}
            },
        }
    }
}

/// Why a pair ended.
#[derive(Clone, Copy, Debug)]
enum End {
    /// That side closed the connection.
    Left(Side),
    /// That side's connection failed.
    Failed(Side),
    /// That side sent a message over the limit.
    TooBig(Side),
    Idle,
    RoomRemoved,
}

impl End {
    fn describe(self) -> String {
        match self {
            Self::Left(side) => format!("{} closed", side.name()),
            Self::Failed(side) => format!("{} connection failed", side.name()),
            Self::TooBig(side) => format!("{} sent a message over the limit", side.name()),
            Self::Idle => "idle timeout".into(),
            Self::RoomRemoved => "room removed".into(),
        }
    }

    /// How to say goodbye to one side.
    fn farewell(self, side: Side) -> Farewell {
        match self {
            Self::Left(s) if s == side => Farewell::Flush,
            Self::Failed(s) if s == side => Farewell::Drop,
            Self::TooBig(s) if s == side => Farewell::Close(TOO_BIG, "message too big"),
            _ => Farewell::Close(NORMAL, ""),
        }
    }
}

enum Farewell {
    /// Send a close frame with this code and reason.
    Close(u16, &'static str),
    /// The peer already sent its close frame; flush our reply.
    Flush,
    /// The connection is broken; just drop it.
    Drop,
}

/// Time of the last data message, shared by both directions of a pair.
struct Activity {
    start: Instant,
    last_ms: AtomicU64,
}

impl Activity {
    fn new() -> Self {
        Self { start: Instant::now(), last_ms: AtomicU64::new(0) }
    }

    fn touch(&self) {
        self.last_ms.store(self.start.elapsed().as_millis() as u64, Ordering::Relaxed);
    }

    /// Completes once no data message has been seen for `limit`.
    async fn idle(&self, limit: Duration) {
        loop {
            let deadline = self.start + Duration::from_millis(self.last_ms.load(Ordering::Relaxed)) + limit;
            if Instant::now() >= deadline {
                return;
            }
            sleep_until(deadline).await;
        }
    }
}

type Tx = SplitSink<WebSocket, Message>;
type Rx = SplitStream<WebSocket>;

async fn run_pair(state: &AppState, room: &str, mac: WebSocket, phone: Box<Phone>) {
    let config = &state.relay.config;
    let Phone { socket: phone, pending, permit, mut removed } = *phone;
    tracing::info!(room = short(room), "relay paired");

    let (mut mac_tx, mut mac_rx) = mac.split();
    let (mut phone_tx, mut phone_rx) = phone.split();
    let activity = Activity::new();
    let (mut to_mac, mut to_phone) = (0u64, 0u64);

    let end = 'pair: {
        if let Some(message) = pending {
            to_mac += message_len(&message);
            if mac_tx.send(message).await.is_err() {
                break 'pair End::Failed(Side::Mac);
            }
        }
        tokio::select! {
            end = pump(Side::Phone, &mut phone_rx, &mut mac_tx, &activity, config.ping_interval, &mut to_mac) => end,
            end = pump(Side::Mac, &mut mac_rx, &mut phone_tx, &activity, config.ping_interval, &mut to_phone) => end,
            () = activity.idle(config.idle_timeout) => End::Idle,
            _ = removed.changed() => End::RoomRemoved,
        }
    };

    // The pair is over; its slot is free even while the close handshakes finish.
    drop(permit);
    tracing::info!(
        room = short(room),
        reason = end.describe(),
        seconds = activity.start.elapsed().as_secs(),
        bytes_to_mac = to_mac,
        bytes_to_phone = to_phone,
        "relay unpaired"
    );
    tokio::join!(
        finish(mac_tx, mac_rx, end.farewell(Side::Mac)),
        finish(phone_tx, phone_rx, end.farewell(Side::Phone)),
    );
}

fn message_len(message: &Message) -> u64 {
    match message {
        Message::Binary(data) => data.len() as u64,
        Message::Text(text) => text.len() as u64,
        _ => 0,
    }
}

/// Forwards data messages from one side to the other and pings the receiving side.
/// Each send is awaited, so a slow receiver slows the sender down instead of
/// buffering messages in memory.
async fn pump(from: Side, rx: &mut Rx, tx: &mut Tx, activity: &Activity, ping_every: Duration, bytes: &mut u64) -> End {
    let mut ping_timer = ping_timer(ping_every);
    loop {
        tokio::select! {
            message = rx.next() => match message {
                Some(Ok(message @ (Message::Binary(_) | Message::Text(_)))) => {
                    activity.touch();
                    *bytes += message_len(&message);
                    if tx.send(message).await.is_err() {
                        return End::Failed(from.other());
                    }
                }
                Some(Ok(Message::Close(_))) | None => return End::Left(from),
                // Pongs need no handling; pings are answered by the WebSocket layer.
                Some(Ok(_)) => {}
                Some(Err(e)) => return if too_big(&e) { End::TooBig(from) } else { End::Failed(from) },
            },
            _ = ping_timer.tick() => {
                if tx.send(ping()).await.is_err() {
                    return End::Failed(from.other());
                }
            }
        }
    }
}

/// Closes one connection, then waits briefly for the peer's close reply so the
/// close frame is not lost to a TCP reset.
async fn finish(mut tx: Tx, mut rx: Rx, farewell: Farewell) {
    let _ = timeout(CLOSE_TIMEOUT, async {
        let sent = match farewell {
            Farewell::Close(code, reason) => {
                let frame = CloseFrame { code, reason: Utf8Bytes::from_static(reason) };
                tx.send(Message::Close(Some(frame))).await
            }
            Farewell::Flush => tx.close().await,
            Farewell::Drop => return,
        };
        if sent.is_ok() {
            while let Some(Ok(_)) = rx.next().await {}
        }
    })
    .await;
}

async fn say_goodbye(socket: WebSocket, farewell: Farewell) {
    let (tx, rx) = socket.split();
    finish(tx, rx, farewell).await;
}

async fn close(socket: WebSocket, code: u16, reason: &'static str) {
    say_goodbye(socket, Farewell::Close(code, reason)).await;
}

/// How to end a socket whose receive failed.
fn error_farewell(error: &axum::Error) -> Farewell {
    if too_big(error) { Farewell::Close(TOO_BIG, "message too big") } else { Farewell::Drop }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_rooms() {
        assert!(is_valid_room(&"0123456789abcdef".repeat(4)));
        assert!(!is_valid_room(&"0123456789ABCDEF".repeat(4)));
        assert!(!is_valid_room(&"a".repeat(63)));
        assert!(!is_valid_room(&"a".repeat(65)));
        assert!(!is_valid_room(&"g".repeat(64)));
        assert!(!is_valid_room(""));
    }

    #[test]
    fn redacts_rooms_in_uris() {
        let room = "ab12cd".to_owned() + &"e".repeat(58);
        let uri: Uri = format!("/api/relay/rooms/{room}/connect?role=mac").parse().unwrap();
        assert_eq!(redact_uri(&uri), "/api/relay/rooms/ab12cd…/connect?role=mac");
        let uri: Uri = format!("/api/relay/rooms/{room}").parse().unwrap();
        assert_eq!(redact_uri(&uri), "/api/relay/rooms/ab12cd…");
        let uri: Uri = "/api/drops/abcdefgh".parse().unwrap();
        assert_eq!(redact_uri(&uri), "/api/drops/abcdefgh");
    }
}

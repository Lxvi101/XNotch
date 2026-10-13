//! XNotch Cloud: a minimal, self-hostable file-drop server with a WebSocket relay.

pub mod api;
pub mod config;
pub mod error;
pub mod ids;
pub mod model;
pub mod names;
pub mod pages;
pub mod public;
pub mod range;
pub mod relay;
pub mod storage;

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::Request;
use axum::routing::get;
use chrono::Utc;
use tower_http::trace::{DefaultOnResponse, TraceLayer};
use tracing::Level;

use crate::config::Config;
use crate::relay::Relay;
use crate::storage::Storage;

/// How often expired drops are swept from storage.
pub const SWEEP_INTERVAL: Duration = Duration::from_secs(10 * 60);

pub struct AppState {
    pub config: Config,
    pub storage: Storage,
    pub relay: Relay,
}

pub type SharedState = Arc<AppState>;

impl AppState {
    pub fn new(config: Config, storage: Storage) -> Self {
        let relay = Relay::new(config.relay.clone());
        Self { config, storage, relay }
    }

    pub fn drop_url(&self, id: &str) -> String {
        format!("{}/{id}", self.config.public_url)
    }
}

/// Builds the full HTTP application.
pub fn app(state: SharedState) -> Router {
    Router::new()
        .nest("/api", api::router(state.clone()))
        .merge(public::router())
        .fallback(public::not_found)
        .layer(
            TraceLayer::new_for_http()
                // Like `DefaultMakeSpan`, but relay room ids (credentials) are shortened.
                .make_span_with(|request: &Request<Body>| {
                    tracing::info_span!(
                        "request",
                        method = %request.method(),
                        uri = %relay::redact_uri(request.uri()),
                        version = ?request.version(),
                    )
                })
                .on_response(DefaultOnResponse::new().level(Level::INFO)),
        )
        // Added after the trace layer so container health checks do not flood the logs.
        .route("/healthz", get(|| async { "ok" }))
        .with_state(state)
}

/// Sweeps expired drops once now and then every [`SWEEP_INTERVAL`].
pub fn spawn_sweeper(state: SharedState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(SWEEP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            match state.storage.sweep(Utc::now()).await {
                Ok(0) => tracing::debug!("sweep finished, nothing expired"),
                Ok(removed) => tracing::info!(removed, "swept expired drops"),
                Err(e) => tracing::warn!(error = %e, "sweep failed"),
            }
        }
    })
}

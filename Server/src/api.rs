//! Authenticated JSON API used by the Mac app, plus the relay's WebSocket endpoint.

use axum::Json;
use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::rejection::PathRejection;
use axum::extract::{Path, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, put};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;

use crate::error::ApiError;
use crate::model::{self, DropMeta, FileMeta};
use crate::storage::WriteError;
use crate::{SharedState, ids, names, password, relay};

/// Longest stored title, in characters. Longer titles are truncated.
const MAX_TITLE_CHARS: usize = 200;

pub fn router(state: SharedState) -> Router<SharedState> {
    Router::new()
        .route("/info", get(info))
        .route("/drops", get(list_drops).post(create_drop))
        .route("/drops/{id}", axum::routing::delete(delete_drop))
        .route("/drops/{id}/files/{name}", put(upload_file))
        .route("/relay/rooms/{room}", put(relay::register_room).delete(relay::unregister_room))
        // Explicit catch-all so unknown `/api/...` paths get a JSON 404 instead of
        // falling through to the public `/{id}/{name}` route.
        .route("/{*rest}", any(|| async { ApiError::NotFound("endpoint") }))
        .layer(middleware::from_fn_with_state(state, require_token))
        // Added after the token layer: devices connect with the room id as their credential.
        .route("/relay/rooms/{room}/connect", get(relay::connect))
}

async fn require_token(State(state): State<SharedState>, request: Request, next: Next) -> Response {
    let presented = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().split_once(' '))
        .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer"))
        .map(|(_, token)| token.trim());
    let valid = presented.is_some_and(|token| bool::from(token.as_bytes().ct_eq(state.config.api_token.as_bytes())));
    if valid { next.run(request).await } else { ApiError::Unauthorized.into_response() }
}

#[derive(Serialize)]
struct Info {
    name: String,
    version: &'static str,
    max_file_size: u64,
    default_expiry_seconds: u64,
    max_expiry_seconds: u64,
    relay: bool,
    /// Drops can have a password.
    passwords: bool,
}

async fn info(State(state): State<SharedState>) -> Json<Info> {
    let c = &state.config;
    Json(Info {
        name: c.site_name.clone(),
        version: env!("CARGO_PKG_VERSION"),
        max_file_size: c.max_file_size,
        default_expiry_seconds: c.default_expiry,
        max_expiry_seconds: c.max_expiry,
        relay: c.relay.enabled,
        passwords: true,
    })
}

#[derive(Deserialize, Default)]
struct CreateDrop {
    /// Seconds; fractional values are accepted and truncated.
    expires_in: Option<f64>,
    title: Option<String>,
    /// Visitors must enter it before they see or download anything. Empty means none.
    password: Option<String>,
}

#[derive(Serialize)]
struct Created {
    id: String,
    url: String,
    expires_at: String,
    /// Echoed so clients can tell a server that ignored the password.
    protected: bool,
}

async fn create_drop(State(state): State<SharedState>, body: Bytes) -> Result<Response, ApiError> {
    // An empty body (or `{}`) means "all defaults".
    let request: CreateDrop = if body.iter().all(u8::is_ascii_whitespace) {
        CreateDrop::default()
    } else {
        serde_json::from_slice(&body).map_err(|e| ApiError::BadRequest(format!("invalid JSON body: {e}")))?
    };
    if request.expires_in.is_some_and(|s| !s.is_finite()) {
        return Err(ApiError::BadRequest("expires_in must be a number of seconds".into()));
    }

    let config = &state.config;
    let expires_in =
        model::clamp_expiry(request.expires_in.map(|s| s as i64), config.default_expiry, config.max_expiry);
    let title =
        request.title.map(|t| t.trim().chars().take(MAX_TITLE_CHARS).collect::<String>()).filter(|t| !t.is_empty());
    let password_hash = match request.password.filter(|p| !p.is_empty()) {
        None => None,
        Some(p) if p.len() > password::MAX_PASSWORD_BYTES => {
            return Err(ApiError::BadRequest(format!(
                "password must be at most {} bytes",
                password::MAX_PASSWORD_BYTES
            )));
        }
        Some(p) => Some(
            password::run_bounded(&state, move || password::hash(&p))
                .await?
                .map_err(|e| ApiError::internal("failed to hash password", e))?,
        ),
    };

    for _ in 0..8 {
        let id = ids::generate(config.id_length);
        let _guard = state.storage.lock(&id).await;
        if state.storage.exists(&id).await.map_err(|e| ApiError::internal("failed to check drop id", e))? {
            continue;
        }
        let mut meta = DropMeta::new(id, title, Utc::now(), expires_in);
        if let Some(hash) = password_hash {
            meta.password_hash = Some(hash);
            meta.unlock_key = Some(password::new_unlock_key());
        }
        state.storage.save(&meta).await.map_err(|e| ApiError::internal("failed to create drop", e))?;
        tracing::info!(drop = %meta.id, expires_in, protected = meta.is_protected(), "drop created");
        let body = Created {
            url: state.drop_url(&meta.id),
            expires_at: model::format_time(&meta.expires_at),
            protected: meta.is_protected(),
            id: meta.id,
        };
        return Ok((StatusCode::CREATED, Json(body)).into_response());
    }
    Err(ApiError::Internal("could not allocate a drop id".into()))
}

#[derive(Serialize)]
struct Uploaded {
    name: String,
    size: u64,
    url: String,
}

async fn upload_file(
    State(state): State<SharedState>,
    path: Result<Path<(String, String)>, PathRejection>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    let Path((id, name)) = path.map_err(|e| ApiError::BadRequest(e.body_text()))?;
    if !ids::is_valid(&id) {
        return Err(ApiError::NotFound("drop"));
    }
    names::validate(&name).map_err(|e| ApiError::BadRequest(e.into()))?;

    let max = state.config.max_file_size;
    let declared_len =
        headers.get(header::CONTENT_LENGTH).and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok());
    if declared_len.is_some_and(|len| len > max) {
        return Err(ApiError::PayloadTooLarge(max));
    }

    let storage = &state.storage;
    let now = Utc::now();
    if storage.load_active(&id, now).await.map_err(|e| ApiError::internal("failed to load drop", e))?.is_none() {
        return Err(ApiError::NotFound("drop"));
    }

    let size = match storage.write_file(&id, &name, body.into_data_stream(), max).await {
        Ok(size) => size,
        Err(WriteError::TooLarge) => return Err(ApiError::PayloadTooLarge(max)),
        Err(WriteError::Body(e)) => return Err(ApiError::BadRequest(format!("failed to read request body: {e}"))),
        Err(WriteError::Storage(e)) => return Err(ApiError::internal("failed to store file", e)),
    };

    let declared_type = headers.get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok());
    let file = FileMeta { name: name.clone(), size, content_type: names::guess_content_type(&name, declared_type) };

    {
        let _guard = storage.lock(&id).await;
        let meta = storage.load(&id).await.map_err(|e| ApiError::internal("failed to load drop", e))?;
        // The drop may have been deleted or expired while the body was streaming.
        let Some(mut meta) = meta.filter(|m| !m.is_expired(Utc::now())) else {
            drop(_guard);
            let _ = storage.delete_file(&id, &name).await;
            return Err(ApiError::NotFound("drop"));
        };
        meta.upsert_file(file);
        storage.save(&meta).await.map_err(|e| ApiError::internal("failed to update drop", e))?;
    }

    tracing::info!(drop = %id, size, "file uploaded");
    let body = Uploaded { url: format!("{}/{}", state.drop_url(&id), names::encode_segment(&name)), name, size };
    Ok((StatusCode::CREATED, Json(body)).into_response())
}

async fn delete_drop(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
) -> Result<StatusCode, ApiError> {
    let Path(id) = path.map_err(|e| ApiError::BadRequest(e.body_text()))?;
    if !ids::is_valid(&id) {
        return Err(ApiError::NotFound("drop"));
    }
    let storage = &state.storage;
    let _guard = storage.lock(&id).await;
    let Some(meta) = storage.load(&id).await.map_err(|e| ApiError::internal("failed to load drop", e))? else {
        return Err(ApiError::NotFound("drop"));
    };
    storage.purge(&id).await.map_err(|e| ApiError::internal("failed to delete drop", e))?;
    if meta.is_expired(Utc::now()) {
        // Already dead from the client's point of view; cleaned up anyway.
        return Err(ApiError::NotFound("drop"));
    }
    tracing::info!(drop = %id, "drop deleted");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
struct DropSummary {
    id: String,
    url: String,
    title: Option<String>,
    created_at: String,
    expires_at: String,
    protected: bool,
    files: Vec<FileSummary>,
}

#[derive(Serialize)]
struct FileSummary {
    name: String,
    size: u64,
}

async fn list_drops(State(state): State<SharedState>) -> Result<Json<Vec<DropSummary>>, ApiError> {
    let drops =
        state.storage.list_active(Utc::now()).await.map_err(|e| ApiError::internal("failed to list drops", e))?;
    Ok(Json(
        drops
            .into_iter()
            .map(|m| DropSummary {
                url: state.drop_url(&m.id),
                created_at: model::format_time(&m.created_at),
                expires_at: model::format_time(&m.expires_at),
                protected: m.is_protected(),
                files: m.files.into_iter().map(|f| FileSummary { name: f.name, size: f.size }).collect(),
                id: m.id,
                title: m.title,
            })
            .collect(),
    ))
}

//! Public, unauthenticated routes: drop pages and file downloads.

use axum::Router;
use axum::body::Body;
use axum::extract::rejection::PathRejection;
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use chrono::Utc;

use crate::range::{self, ByteRange};
use crate::{SharedState, ids, names, pages};

pub fn router() -> Router<SharedState> {
    Router::new()
        .route("/", get(home))
        .route("/robots.txt", get(|| async { "User-agent: *\nDisallow: /\n" }))
        .route("/favicon.ico", get(|| async { StatusCode::NOT_FOUND }))
        .route("/{id}", get(drop_page))
        .route("/{id}/{name}", get(download))
}

/// Shared headers for responses a browser may render.
fn harden(headers: &mut HeaderMap) {
    headers.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(header::REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    headers.insert("x-robots-tag", HeaderValue::from_static("noindex, nofollow"));
}

fn html(status: StatusCode, render: impl FnOnce(&str) -> String) -> Response {
    let nonce = ids::generate(22);
    let body = render(&nonce);
    let csp = format!(
        "default-src 'none'; img-src 'self'; style-src 'nonce-{nonce}'; script-src 'nonce-{nonce}'; \
         base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    );
    let mut response = (status, body).into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/html; charset=utf-8"));
    headers.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_str(&csp).expect("valid CSP"));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    harden(headers);
    response
}

/// Styled 404 page, also used as the router fallback.
pub async fn not_found(State(state): State<SharedState>) -> Response {
    html(StatusCode::NOT_FOUND, |nonce| pages::not_found_page(&state.config.site_name, nonce))
}

fn internal_error(context: &str, err: impl std::fmt::Display) -> Response {
    tracing::error!(error = %err, "{context}");
    (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error").into_response()
}

async fn home(State(state): State<SharedState>) -> Response {
    html(StatusCode::OK, |nonce| pages::home_page(&state.config.site_name, nonce))
}

async fn drop_page(State(state): State<SharedState>, path: Result<Path<String>, PathRejection>) -> Response {
    let Ok(Path(id)) = path else { return not_found(State(state)).await };
    if !ids::is_valid(&id) {
        return not_found(State(state)).await;
    }
    let now = Utc::now();
    match state.storage.load_active(&id, now).await {
        Ok(Some(meta)) => html(StatusCode::OK, |nonce| pages::drop_page(&meta, &state.config.site_name, now, nonce)),
        Ok(None) => not_found(State(state)).await,
        Err(e) => internal_error("failed to load drop", e),
    }
}

fn wants_inline(query: Option<&str>) -> bool {
    query.is_some_and(|q| q.split('&').any(|pair| matches!(pair, "inline=1" | "inline=true")))
}

async fn download(
    State(state): State<SharedState>,
    path: Result<Path<(String, String)>, PathRejection>,
    RawQuery(query): RawQuery,
    headers: HeaderMap,
) -> Response {
    let Ok(Path((id, name))) = path else { return not_found(State(state)).await };
    if !ids::is_valid(&id) || names::validate(&name).is_err() {
        return not_found(State(state)).await;
    }

    let meta = match state.storage.load_active(&id, Utc::now()).await {
        Ok(Some(meta)) => meta,
        Ok(None) => return not_found(State(state)).await,
        Err(e) => return internal_error("failed to load drop", e),
    };
    let Some(file) = meta.file(&name) else { return not_found(State(state)).await };

    // Honour a single range unless the client made it conditional (we send no validators).
    let range = match headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
        Some(value) if !headers.contains_key(header::IF_RANGE) => range::parse(value, file.size),
        _ => ByteRange::Full,
    };
    let requested = match range {
        ByteRange::Full => None,
        ByteRange::Partial(r) => Some(r),
        ByteRange::Unsatisfiable => {
            let mut response = StatusCode::RANGE_NOT_SATISFIABLE.into_response();
            let value = format!("bytes */{}", file.size);
            response.headers_mut().insert(header::CONTENT_RANGE, HeaderValue::from_str(&value).expect("ascii"));
            harden(response.headers_mut());
            return response;
        }
    };

    let partial = requested.is_some();
    let result = match state.storage.read_file(&id, &name, requested).await {
        Ok(Some(result)) => result,
        Ok(None) => return not_found(State(state)).await,
        Err(e) => return internal_error("failed to read file", e),
    };
    let (served, total) = (result.range.clone(), result.meta.size);

    let inline = wants_inline(query.as_deref()) && names::is_inline_safe(&file.content_type);
    let content_type = if file.content_type == "text/plain" { "text/plain; charset=utf-8" } else { &file.content_type };
    let disposition = names::content_disposition(if inline { "inline" } else { "attachment" }, &file.name);

    let mut response = Response::new(Body::from_stream(result.into_stream()));
    *response.status_mut() = if partial { StatusCode::PARTIAL_CONTENT } else { StatusCode::OK };
    let h = response.headers_mut();
    let value =
        |s: &str| HeaderValue::from_str(s).unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    h.insert(header::CONTENT_TYPE, value(content_type));
    h.insert(header::CONTENT_LENGTH, HeaderValue::from(served.end - served.start));
    h.insert(header::CONTENT_DISPOSITION, HeaderValue::from_str(&disposition).expect("ascii disposition"));
    h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static("private, no-cache"));
    if partial {
        let content_range = format!("bytes {}-{}/{}", served.start, served.end.saturating_sub(1), total);
        h.insert(header::CONTENT_RANGE, HeaderValue::from_str(&content_range).expect("ascii"));
    }
    if !inline {
        // Belt and braces: even if a browser renders an attachment, it gets no script and no origin.
        h.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static("sandbox; default-src 'none'"));
    }
    harden(h);
    response
}

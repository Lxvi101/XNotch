//! Public, unauthenticated routes: drop pages and file downloads.

use axum::Form;
use axum::Router;
use axum::body::Body;
use axum::extract::rejection::{FormRejection, PathRejection};
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use chrono::Utc;
use serde::Deserialize;

use crate::model::DropMeta;
use crate::range::{self, ByteRange};
use crate::{SharedState, ids, names, pages, password};

/// Added to every wrong password, so guessing is slow even within the
/// concurrency limit on hash checks.
const WRONG_PASSWORD_DELAY: std::time::Duration = std::time::Duration::from_millis(750);

pub fn router() -> Router<SharedState> {
    Router::new()
        .route("/", get(home))
        .route("/robots.txt", get(|| async { "User-agent: *\nDisallow: /\n" }))
        .route("/favicon.ico", get(|| async { StatusCode::NOT_FOUND }))
        .route("/{id}", get(drop_page).post(unlock))
        .route("/{id}/{name}", get(download))
}

/// Shared headers for responses a browser may render.
fn harden(headers: &mut HeaderMap) {
    headers.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(header::REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    headers.insert("x-robots-tag", HeaderValue::from_static("noindex, nofollow"));
}

fn html(status: StatusCode, render: impl FnOnce(&str) -> String) -> Response {
    html_page(status, "'none'", render)
}

/// `form_action` is the CSP source list for forms; only the password page posts one.
fn html_page(status: StatusCode, form_action: &str, render: impl FnOnce(&str) -> String) -> Response {
    let nonce = ids::generate(22);
    let body = render(&nonce);
    let csp = format!(
        "default-src 'none'; img-src 'self'; style-src 'nonce-{nonce}'; script-src 'nonce-{nonce}'; \
         base-uri 'none'; form-action {form_action}; frame-ancestors 'none'"
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

async fn drop_page(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    headers: HeaderMap,
) -> Response {
    let Ok(Path(id)) = path else { return not_found(State(state)).await };
    if !ids::is_valid(&id) {
        return not_found(State(state)).await;
    }
    let now = Utc::now();
    match state.storage.load_active(&id, now).await {
        Ok(Some(meta)) if !password::is_unlocked(&meta, &headers) => locked(&state, &meta, StatusCode::OK, false),
        Ok(Some(meta)) => html(StatusCode::OK, |nonce| pages::drop_page(&meta, &state.config.site_name, now, nonce)),
        Ok(None) => not_found(State(state)).await,
        Err(e) => internal_error("failed to load drop", e),
    }
}

fn locked(state: &SharedState, meta: &DropMeta, status: StatusCode, wrong: bool) -> Response {
    html_page(status, "'self'", |nonce| pages::locked_page(meta, &state.config.site_name, wrong, nonce))
}

fn see_other(location: &str) -> Response {
    let mut response = StatusCode::SEE_OTHER.into_response();
    response.headers_mut().insert(header::LOCATION, HeaderValue::from_str(location).expect("ascii id"));
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

#[derive(Deserialize)]
struct Unlock {
    password: String,
}

/// The password form posts here; a right password sets the unlock cookie.
async fn unlock(
    State(state): State<SharedState>,
    path: Result<Path<String>, PathRejection>,
    form: Result<Form<Unlock>, FormRejection>,
) -> Response {
    let Ok(Path(id)) = path else { return not_found(State(state)).await };
    if !ids::is_valid(&id) {
        return not_found(State(state)).await;
    }
    let now = Utc::now();
    let meta = match state.storage.load_active(&id, now).await {
        Ok(Some(meta)) => meta,
        Ok(None) => return not_found(State(state)).await,
        Err(e) => return internal_error("failed to load drop", e),
    };
    let (Some(hash), Some(key)) = (meta.password_hash.clone(), meta.unlock_key.clone()) else {
        return see_other(&format!("/{id}"));
    };

    let attempt = form.map(|Form(f)| f.password).unwrap_or_default();
    let right = if attempt.is_empty() || attempt.len() > password::MAX_PASSWORD_BYTES {
        false
    } else {
        match password::run_bounded(&state, move || password::verify(&attempt, &hash)).await {
            Ok(right) => right,
            Err(e) => return e.into_response(),
        }
    };
    if !right {
        tokio::time::sleep(WRONG_PASSWORD_DELAY).await;
        return locked(&state, &meta, StatusCode::FORBIDDEN, true);
    }

    let secure = state.config.public_url.starts_with("https://");
    let cookie = password::unlock_cookie(&meta, &key, (meta.expires_at - now).num_seconds(), secure);
    let mut response = see_other(&format!("/{id}"));
    response.headers_mut().insert(header::SET_COOKIE, HeaderValue::from_str(&cookie).expect("ascii cookie"));
    response
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
    if !password::is_unlocked(&meta, &headers) {
        // Not the file's existence, only the drop's: send them to the password page.
        return see_other(&format!("/{id}"));
    }
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

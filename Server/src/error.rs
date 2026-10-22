//! JSON errors for the `/api` routes.

use axum::Json;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    Unauthorized,
    NotFound(&'static str),
    BadRequest(String),
    PayloadTooLarge(u64),
    TooManyRequests(u64),
    Internal(String),
}

impl ApiError {
    /// Logs the underlying error and hides details from the client.
    pub fn internal(context: &str, err: impl std::fmt::Display) -> Self {
        tracing::error!(error = %err, "{context}");
        Self::Internal(context.to_owned())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let retry_after = if let Self::TooManyRequests(seconds) = &self { Some((*seconds).max(1)) } else { None };
        let (status, message) = match self {
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "missing or invalid API token".to_owned()),
            Self::NotFound(what) => (StatusCode::NOT_FOUND, format!("{what} not found")),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, message),
            Self::PayloadTooLarge(max) => {
                (StatusCode::PAYLOAD_TOO_LARGE, format!("file exceeds the maximum size of {max} bytes"))
            }
            Self::Internal(context) => (StatusCode::INTERNAL_SERVER_ERROR, context),
            Self::TooManyRequests(_) => (StatusCode::TOO_MANY_REQUESTS, "too many requests".to_owned()),
        };
        let mut response = (status, Json(json!({ "error": message }))).into_response();
        if status == StatusCode::UNAUTHORIZED {
            response.headers_mut().insert(header::WWW_AUTHENTICATE, header::HeaderValue::from_static("Bearer"));
        }
        if let Some(seconds) = retry_after {
            response.headers_mut().insert(header::RETRY_AFTER, header::HeaderValue::from(seconds));
            response.headers_mut().insert(header::CACHE_CONTROL, header::HeaderValue::from_static("no-store"));
        }
        response
    }
}

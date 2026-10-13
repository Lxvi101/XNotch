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
        let (status, message) = match self {
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "missing or invalid API token".to_owned()),
            Self::NotFound(what) => (StatusCode::NOT_FOUND, format!("{what} not found")),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, message),
            Self::PayloadTooLarge(max) => {
                (StatusCode::PAYLOAD_TOO_LARGE, format!("file exceeds the maximum size of {max} bytes"))
            }
            Self::Internal(context) => (StatusCode::INTERNAL_SERVER_ERROR, context),
        };
        let mut response = (status, Json(json!({ "error": message }))).into_response();
        if status == StatusCode::UNAUTHORIZED {
            response.headers_mut().insert(header::WWW_AUTHENTICATE, header::HeaderValue::from_static("Bearer"));
        }
        response
    }
}

//! IDFK what this is lol chatGPT wrote it and it does literally nothing. 0/10

// errors.rs
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    // client-side / input
    #[error("validation failed: {0}")]
    Validation(String),

    // talking to your server
    #[error("network error: {0}")]
    Network(String),

    // server said “no” (4xx/5xx)
    #[error("server error: {status} {message}")]
    Server {
        status: u16,
        message: String,
    },

    // auth/session
    #[error("unauthorized")]
    Unauthorized,

    // (de)serializing JSON from server
    #[error("serialization error: {0}")]
    Serialization(String),

    // catch-all
    #[error("internal error")]
    Internal,
}

impl From<reqwest::Error> for AppError {
    fn from(e: reqwest::Error) -> Self {
        if let Some(status) = e.status() {
            AppError::Server {
                status: status.as_u16(),
                message: e.to_string(),
            }
        } else {
            AppError::Network(e.to_string())
        }
    }
}

impl From<serde_json::Error> for AppError {
    fn from(e: serde_json::Error) -> Self {
        AppError::Serialization(e.to_string())
    }
}

pub struct FfiError {
    pub code: i32,
    pub message: String,
}

impl From<AppError> for FfiError {
    fn from(e: AppError) -> Self {
        match e {
            AppError::Validation(msg) =>
                FfiError { code: 1, message: msg },
            AppError::Network(msg) =>
                FfiError { code: 2, message: msg },
            AppError::Server { status, message } =>
                FfiError { code: 3, message: format!("{status} {message}") },
            AppError::Unauthorized =>
                FfiError { code: 4, message: "unauthorized".into() },
            AppError::Serialization(msg) =>
                FfiError { code: 5, message: msg },
            AppError::Internal =>
                FfiError { code: 999, message: "internal".into() },
        }
    }
}

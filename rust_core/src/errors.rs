//! Error helpers shared by the FFI and the internal logic layers.

use std::ffi::CString;
use std::io;
use std::os::raw::c_char;

use thiserror::Error;

/// High level error type used across the Rust core.
#[derive(Debug, Error)]
pub enum AppError {
    /// Invalid input provided by the caller.
    #[error("validation failed: {0}")]
    Validation(String),

    /// Failure when communicating with the remote API.
    #[error("network error: {0}")]
    Network(String),

    /// The server explicitly returned an error.
    #[error("server error: {status} {message}")]
    Server { status: u16, message: String },

    /// Authentication or authorization failed.
    #[error("unauthorized")]
    Unauthorized,

    /// Serialization or deserialization failed.
    #[error("serialization error: {0}")]
    Serialization(String),

    /// Any other unclassified error.
    #[error("internal error: {0}")]
    Internal(String),
}

impl From<anyhow::Error> for AppError {
    fn from(value: anyhow::Error) -> Self {
        AppError::Internal(value.to_string())
    }
}

impl From<serde_json::Error> for AppError {
    fn from(value: serde_json::Error) -> Self {
        AppError::Serialization(value.to_string())
    }
}

impl From<csv::Error> for AppError {
    fn from(value: csv::Error) -> Self {
        AppError::Internal(value.to_string())
    }
}

impl From<io::Error> for AppError {
    fn from(value: io::Error) -> Self {
        AppError::Internal(value.to_string())
    }
}

/// A small error container that is safe to transfer across the C FFI boundary.
#[repr(C)]
#[derive(Debug)]
pub struct FfiError {
    /// Application specific error code. `0` represents success.
    pub code: i32,
    /// Heap allocated, null terminated UTF-8 message. The caller is responsible for
    /// releasing it via [`sparkwms_string_free`].
    pub message: *mut c_char,
}

impl FfiError {
    /// Helper returned when an operation succeeds.
    pub fn success() -> Self {
        Self {
            code: 0,
            message: std::ptr::null_mut(),
        }
    }

    fn from_message(code: i32, message: String) -> Self {
        let cstring = CString::new(message).unwrap_or_else(|_| CString::new("invalid error").unwrap());
        Self {
            code,
            message: cstring.into_raw(),
        }
    }
}

impl From<AppError> for FfiError {
    fn from(value: AppError) -> Self {
        match value {
            AppError::Validation(msg) => Self::from_message(1, msg),
            AppError::Network(msg) => Self::from_message(2, msg),
            AppError::Server { status, message } => {
                Self::from_message(3, format!("{status} {message}"))
            }
            AppError::Unauthorized => Self::from_message(4, "unauthorized".into()),
            AppError::Serialization(msg) => Self::from_message(5, msg),
            AppError::Internal(msg) => Self::from_message(999, msg),
        }
    }
}

/// Release a C string that originated from this library.
#[unsafe(no_mangle)]
pub extern "C" fn sparkwms_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }

    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_error_success_has_null_message() {
        let err = FfiError::success();
        assert_eq!(err.code, 0);
        assert!(err.message.is_null());
    }

    #[test]
    fn converts_internal_error() {
        let error = AppError::Internal("boom".into());
        let ffi: FfiError = error.into();
        assert_eq!(ffi.code, 999);
        unsafe {
            assert_eq!(std::ffi::CStr::from_ptr(ffi.message).to_str().unwrap(), "boom");
        }
        sparkwms_string_free(ffi.message);
    }
}


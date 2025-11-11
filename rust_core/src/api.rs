//! Public FFI surface that Dart/Flutter can call into.

use std::ffi::{CStr, CString};
use std::future::Future;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::ptr;
use std::thread;

use tokio::runtime::{Builder, Runtime};

use crate::commit_manager::{self, enqueue_commit, queue_len};
use crate::errors::{AppError, FfiError};
use crate::server::{Commit, NeonAPI};

const DEFAULT_QUEUE_PATH: &str = "commit_queue.json";

/// Handle that keeps the API client and the Tokio runtime alive for FFI callers.
pub struct ApiHandle {
    runtime: Runtime,
    api: NeonAPI,
}

impl ApiHandle {
    fn new(connect_string: &str) -> Result<Self, AppError> {
        let runtime = Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|err| AppError::Internal(format!("failed to create runtime: {err}")))?;

        let api = NeonAPI::new(connect_string).map_err(AppError::from)?;

        Ok(Self { runtime, api })
    }

    fn block_on<F, T>(&self, future: F) -> Result<T, AppError>
    where
        F: Future<Output = Result<T, anyhow::Error>>,
    {
        self.runtime.block_on(future).map_err(AppError::from)
    }

    fn block_on_unit<F>(&self, future: F) -> Result<(), AppError>
    where
        F: Future<Output = Result<(), anyhow::Error>>,
    {
        self.runtime.block_on(future).map_err(AppError::from)
    }
}

#[repr(C)]
pub struct FfiCommit {
    pub device_id: *const c_char,
    pub location: *const c_char,
    pub delta: i32,
    pub item_id: i16,
}

fn cstr_to_string(ptr: *const c_char, field: &str) -> Result<String, AppError> {
    if ptr.is_null() {
        return Err(AppError::Validation(format!("{field} pointer was null")));
    }

    unsafe {
        let cstr = CStr::from_ptr(ptr);
        cstr.to_str()
            .map(|s| s.to_owned())
            .map_err(|_| AppError::Validation(format!("{field} was not valid UTF-8")))
    }
}

impl TryFrom<FfiCommit> for Commit {
    type Error = AppError;

    fn try_from(value: FfiCommit) -> Result<Self, Self::Error> {
        Ok(Commit {
            device_id: cstr_to_string(value.device_id, "device_id")?,
            location: cstr_to_string(value.location, "location")?,
            delta: value.delta,
            item_id: value.item_id,
        })
    }
}

fn path_from_ptr(ptr: *const c_char) -> Result<PathBuf, AppError> {
    if ptr.is_null() {
        return Ok(PathBuf::from(DEFAULT_QUEUE_PATH));
    }

    Ok(PathBuf::from(cstr_to_string(ptr, "path")?))
}

fn write_success(err_out: *mut FfiError) {
    if let Some(slot) = unsafe { err_out.as_mut() } {
        *slot = FfiError::success();
    }
}

fn write_error(err_out: *mut FfiError, error: AppError) {
    if let Some(slot) = unsafe { err_out.as_mut() } {
        *slot = FfiError::from(error);
    }
}

/// Create a new API handle. Returns a null pointer on failure and populates `err_out`.
#[no_mangle]
pub extern "C" fn sparkwms_api_new(
    connect_string: *const c_char,
    err_out: *mut FfiError,
) -> *mut ApiHandle {
    match (|| -> Result<ApiHandle, AppError> {
        let connect = cstr_to_string(connect_string, "connect_string")?;
        ApiHandle::new(&connect)
    })() {
        Ok(handle) => {
            write_success(err_out);
            Box::into_raw(Box::new(handle))
        }
        Err(err) => {
            write_error(err_out, err);
            ptr::null_mut()
        }
    }
}

/// Release a handle that was previously created via [`sparkwms_api_new`].
#[no_mangle]
pub extern "C" fn sparkwms_api_free(handle: *mut ApiHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(handle));
    }
}

fn with_handle<F>(handle: *mut ApiHandle, err_out: *mut FfiError, f: F) -> bool
where
    F: FnOnce(&ApiHandle) -> Result<bool, AppError>,
{
    if handle.is_null() {
        write_error(
            err_out,
            AppError::Validation("handle pointer was null".into()),
        );
        return false;
    }

    let handle_ref = unsafe { &*handle };

    match f(handle_ref) {
        Ok(result) => {
            write_success(err_out);
            result
        }
        Err(err) => {
            write_error(err_out, err);
            false
        }
    }
}

/// Send a commit immediately without touching the queue.
#[no_mangle]
pub extern "C" fn sparkwms_api_send_commit(
    handle: *mut ApiHandle,
    commit: FfiCommit,
    err_out: *mut FfiError,
) -> bool {
    with_handle(handle, err_out, |api| {
        let commit = Commit::try_from(commit)?;
        api.block_on_unit(api.api.send_commit(&commit))?;
        Ok(true)
    })
}

/// Export the overview view to a CSV file at `path`.
#[no_mangle]
pub extern "C" fn sparkwms_api_export_overview(
    handle: *mut ApiHandle,
    path: *const c_char,
    err_out: *mut FfiError,
) -> bool {
    with_handle(handle, err_out, |api| {
        let path = cstr_to_string(path, "path")?;
        api.block_on_unit(api.api.export_overview_to_csv(&path))?;
        Ok(true)
    })
}

/// Export the locations view to a CSV file at `path`.
#[no_mangle]
pub extern "C" fn sparkwms_api_export_locations(
    handle: *mut ApiHandle,
    path: *const c_char,
    err_out: *mut FfiError,
) -> bool {
    with_handle(handle, err_out, |api| {
        let path = cstr_to_string(path, "path")?;
        api.block_on_unit(api.api.export_location_data_to_csv(&path))?;
        Ok(true)
    })
}

/// Export the items table to a CSV file at `path`.
#[no_mangle]
pub extern "C" fn sparkwms_api_export_items(
    handle: *mut ApiHandle,
    path: *const c_char,
    err_out: *mut FfiError,
) -> bool {
    with_handle(handle, err_out, |api| {
        let path = cstr_to_string(path, "path")?;
        api.block_on_unit(api.api.export_items_to_csv(&path))?;
        Ok(true)
    })
}

/// Check if the API is reachable. Returns `true` if the check query succeeded.
#[no_mangle]
pub extern "C" fn sparkwms_api_check(handle: *mut ApiHandle, err_out: *mut FfiError) -> bool {
    with_handle(handle, err_out, |api| {
        let result = api.runtime.block_on(api.api.check());
        Ok(result)
    })
}

/// Add a commit to the on-disk queue.
#[no_mangle]
pub extern "C" fn sparkwms_queue_enqueue(
    path: *const c_char,
    commit: FfiCommit,
    err_out: *mut FfiError,
) -> bool {
    match (|| -> Result<(), AppError> {
        let path = path_from_ptr(path)?;
        let commit = Commit::try_from(commit)?;
        enqueue_commit(&path, commit)?;
        Ok(())
    })() {
        Ok(()) => {
            write_success(err_out);
            true
        }
        Err(err) => {
            write_error(err_out, err);
            false
        }
    }
}

/// Return the number of commits currently persisted in the queue file.
#[no_mangle]
pub extern "C" fn sparkwms_queue_len(path: *const c_char, err_out: *mut FfiError) -> i32 {
    match (|| -> Result<usize, AppError> {
        let path = path_from_ptr(path)?;
        Ok(queue_len(&path)?)
    })() {
        Ok(len) => {
            write_success(err_out);
            len as i32
        }
        Err(err) => {
            write_error(err_out, err);
            -1
        }
    }
}

/// Start the commit manager loop on a background thread. Returns `false` if the thread
/// could not be spawned or the inputs were invalid.
#[no_mangle]
pub extern "C" fn sparkwms_start_commit_manager(
    connect_string: *const c_char,
    queue_path: *const c_char,
    err_out: *mut FfiError,
) -> bool {
    let setup = (|| -> Result<(NeonAPI, PathBuf), AppError> {
        let connect = cstr_to_string(connect_string, "connect_string")?;
        let api = NeonAPI::new(&connect).map_err(AppError::from)?;
        let path = path_from_ptr(queue_path)?;
        Ok((api, path))
    })();

    let (api, path) = match setup {
        Ok(tuple) => tuple,
        Err(err) => {
            write_error(err_out, err);
            return false;
        }
    };

    match thread::Builder::new()
        .name("sparkwms-commit-manager".into())
        .spawn(move || {
            let runtime = Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("runtime");

            if let Err(err) = runtime.block_on(commit_manager::commit_manager(api, path)) {
                eprintln!("commit manager loop exited: {err}");
            }
        }) {
        Ok(_) => {
            write_success(err_out);
            true
        }
        Err(err) => {
            write_error(
                err_out,
                AppError::Internal(format!("failed to spawn commit manager: {err}")),
            );
            false
        }
    }
}

/// Convenience helper for Dart/Flutter to dispose FFI owned strings.
#[no_mangle]
pub extern "C" fn sparkwms_string_from_rust(value: *const c_char) -> *mut c_char {
    if value.is_null() {
        return ptr::null_mut();
    }

    unsafe {
        let cstr = CStr::from_ptr(value);
        CString::new(cstr.to_bytes())
            .map(|s| s.into_raw())
            .unwrap_or(ptr::null_mut())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_commit_from_ffi() {
        let device = CString::new("device").unwrap();
        let location = CString::new("loc").unwrap();
        let commit = FfiCommit {
            device_id: device.as_ptr(),
            location: location.as_ptr(),
            delta: 5,
            item_id: 42,
        };

        let rust_commit = Commit::try_from(commit).unwrap();
        assert_eq!(rust_commit.device_id, "device");
        assert_eq!(rust_commit.location, "loc");
        assert_eq!(rust_commit.delta, 5);
        assert_eq!(rust_commit.item_id, 42);
    }

    #[test]
    fn null_pointer_returns_error() {
        let result = Commit::try_from(FfiCommit {
            device_id: ptr::null(),
            location: ptr::null(),
            delta: 0,
            item_id: 0,
        });

        assert!(matches!(result, Err(AppError::Validation(_))));
    }
}

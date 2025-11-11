//! Queue functions and main queue uploading loop.
use std::{
    collections::VecDeque,
    fs, io,
    path::{Path, PathBuf},
    time::Duration,
};

use serde::{Deserialize, Serialize};
use tokio::time::sleep;

use crate::server::*;

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct Queue {
    pub items: VecDeque<Commit>,
}

#[allow(dead_code)]
impl Queue {
    /// Save the queue to the path specified.
    /// Path should end in ".json".
    pub fn save_as(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = path.as_ref();
        let tmp = path.with_extension("tmp");

        let data = serde_json::to_vec_pretty(self).expect("serialize queue");

        fs::write(&tmp, &data)?;
        fs::rename(&tmp, path)?;
        Ok(())
    }

    /// Load the queue from file.
    /// Path must lead to a valid json.
    pub fn load(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        if !path.exists() {
            return Ok(Self::default());
        }

        let data = fs::read(path)?;
        let queue: Self = serde_json::from_slice(&data).unwrap_or_default();
        Ok(queue)
    }

    /// Add a commit to the queue.
    /// Path should end in ".json".
    pub fn enqueue(&mut self, commit: Commit, path: &Path) -> io::Result<()> {
        self.items.push_back(commit);
        self.save_as(path)
    }

    /// Look at the first item on the queue.
    pub fn peek(&self) -> Option<&Commit> {
        self.items.front()
    }

    /// Remove the first item in the queue.
    pub fn pop_front(&mut self, path: &Path) -> io::Result<Option<Commit>> {
        let item = self.items.pop_front();
        if item.is_some() {
            self.save_as(path)?;
        }
        Ok(item)
    }
}

#[allow(dead_code)]
pub fn enqueue_commit(path: impl AsRef<Path>, commit: Commit) -> io::Result<()> {
    let path = path.as_ref();
    let mut queue = Queue::load(path)?;
    queue.enqueue(commit, path)
}

#[allow(dead_code)]
pub fn queue_len(path: impl AsRef<Path>) -> io::Result<usize> {
    Ok(Queue::load(path)?.items.len())
}

#[allow(dead_code)]
pub async fn commit_manager(api: NeonAPI, path: impl AsRef<Path>) -> io::Result<()> {
    //! Background Loop to monitor queue and send new commits at all times.
    //! Should be run in a thread separate from the GUI (obv lol).
    let path_buf: PathBuf = path.as_ref().to_path_buf();
    let mut queue = Queue::load(&path_buf)?;

    loop {
        if queue.items.len() > 0 {
            if queue.items.is_empty() {
                sleep(Duration::from_secs(1)).await;
                continue;
            }

            let commit = match queue.peek().clone() {
                Some(c) => c,
                None => continue,
            };

            if !api.check().await {
                sleep(Duration::from_secs(5)).await;
                continue;
            }

            if let Err(err) = api.send_commit(&commit).await {
                eprintln!("send_commit failed: {err}");
                sleep(Duration::from_secs(5)).await;
                continue;
            }

            queue.pop_front(&path_buf)?;
        }
    }
}

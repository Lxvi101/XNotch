//! Object storage for drops, shared by the local disk and S3 backends.
//!
//! Layout (under an optional prefix):
//! - `drops/{id}/meta.json`   drop metadata ([`DropMeta`])
//! - `drops/{id}/files/{name}` file contents
//! - `drops/{id}/manifest`     encrypted manifest of an end-to-end encrypted drop
//! - `relay/rooms/{room}`      a registered relay room ([`RelayRoom`])

use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use chrono::{DateTime, Utc};
use futures_util::{Stream, StreamExt, TryStreamExt};
use object_store::aws::AmazonS3Builder;
use object_store::buffered::BufWriter;
use object_store::local::LocalFileSystem;
use object_store::path::Path;
use object_store::{ClientOptions, GetOptions, GetRange, GetResult, ObjectStore, ObjectStoreExt, PutPayload};
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, MutexGuard};

use crate::config::StorageConfig;
use crate::ids;
use crate::model::{DropMeta, RelayRoom};
use crate::relay;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;
type Result<T, E = object_store::Error> = std::result::Result<T, E>;

/// Upload part size. S3 and B2 need at least 5 MiB per part; this also bounds
/// memory use per upload (`PART_SIZE * (UPLOAD_CONCURRENCY + 1)`).
const PART_SIZE: usize = 8 * 1024 * 1024;
const UPLOAD_CONCURRENCY: usize = 2;
const LOCK_STRIPES: usize = 64;
/// Objects of a drop without metadata older than this are removed by the sweeper.
const ORPHAN_GRACE: chrono::Duration = chrono::Duration::hours(1);

#[derive(Debug)]
pub enum WriteError {
    TooLarge,
    Body(BoxError),
    Storage(BoxError),
}

pub struct Storage {
    store: Arc<dyn ObjectStore>,
    drops: Path,
    relay_rooms: Path,
    /// Striped locks that serialize metadata read-modify-write per drop.
    locks: Vec<Mutex<()>>,
}

impl Storage {
    pub fn new(store: Arc<dyn ObjectStore>, prefix: Option<&str>) -> Self {
        let root = prefix.map(Path::from).unwrap_or_default();
        Self {
            store,
            drops: root.clone().join("drops"),
            relay_rooms: root.join("relay").join("rooms"),
            locks: (0..LOCK_STRIPES).map(|_| Mutex::new(())).collect(),
        }
    }

    pub fn from_config(config: &StorageConfig) -> Result<Self, String> {
        match config {
            StorageConfig::Local { data_dir } => {
                std::fs::create_dir_all(data_dir)
                    .map_err(|e| format!("cannot create DATA_DIR {}: {e}", data_dir.display()))?;
                // Fail at startup rather than on the first upload.
                let probe = data_dir.join(".write-test");
                std::fs::write(&probe, b"")
                    .and_then(|()| std::fs::remove_file(&probe))
                    .map_err(|e| format!("DATA_DIR {} is not writable by this user: {e}", data_dir.display()))?;
                let store = LocalFileSystem::new_with_prefix(data_dir)
                    .map_err(|e| format!("cannot open DATA_DIR {}: {e}", data_dir.display()))?
                    .with_automatic_cleanup(true);
                Ok(Self::new(Arc::new(store), None))
            }
            StorageConfig::S3 {
                bucket,
                endpoint,
                region,
                access_key_id,
                secret_access_key,
                prefix,
                virtual_hosted_style,
            } => {
                // No overall request timeout: downloads stream for as long as they need.
                let mut client =
                    ClientOptions::new().with_timeout_disabled().with_connect_timeout(Duration::from_secs(10));
                let mut builder = AmazonS3Builder::new()
                    .with_bucket_name(bucket)
                    .with_region(region)
                    .with_virtual_hosted_style_request(*virtual_hosted_style);
                if let Some(endpoint) = endpoint {
                    client = client.with_allow_http(endpoint.starts_with("http://"));
                    builder = builder.with_endpoint(endpoint);
                }
                if let Some(key) = access_key_id {
                    builder = builder.with_access_key_id(key);
                }
                if let Some(secret) = secret_access_key {
                    builder = builder.with_secret_access_key(secret);
                }
                let store = builder
                    .with_client_options(client)
                    .build()
                    .map_err(|e| format!("invalid S3 configuration: {e}"))?;
                Ok(Self::new(Arc::new(store), prefix.as_deref()))
            }
        }
    }

    fn drop_dir(&self, id: &str) -> Path {
        self.drops.clone().join(id)
    }

    fn meta_path(&self, id: &str) -> Path {
        self.drop_dir(id).join("meta.json")
    }

    fn file_path(&self, id: &str, name: &str) -> Path {
        self.drop_dir(id).join("files").join(name)
    }

    fn manifest_path(&self, id: &str) -> Path {
        self.drop_dir(id).join("manifest")
    }

    fn relay_room_path(&self, room: &str) -> Path {
        self.relay_rooms.clone().join(room)
    }

    /// Locks a drop's metadata (or a relay room) for a read-modify-write cycle.
    pub async fn lock(&self, id: &str) -> MutexGuard<'_, ()> {
        let mut hasher = DefaultHasher::new();
        id.hash(&mut hasher);
        self.locks[hasher.finish() as usize % LOCK_STRIPES].lock().await
    }

    pub async fn exists(&self, id: &str) -> Result<bool> {
        match self.store.head(&self.meta_path(id)).await {
            Ok(_) => Ok(true),
            Err(object_store::Error::NotFound { .. }) => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// Loads a drop's metadata, expired or not.
    pub async fn load(&self, id: &str) -> Result<Option<DropMeta>> {
        let bytes = match self.store.get(&self.meta_path(id)).await {
            Ok(result) => result.bytes().await?,
            Err(object_store::Error::NotFound { .. }) => return Ok(None),
            Err(e) => return Err(e),
        };
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| object_store::Error::Generic { store: "meta.json", source: Box::new(e) })
    }

    /// Loads a drop only if it exists and has not expired.
    pub async fn load_active(&self, id: &str, now: DateTime<Utc>) -> Result<Option<DropMeta>> {
        Ok(self.load(id).await?.filter(|m| !m.is_expired(now)))
    }

    pub async fn save(&self, meta: &DropMeta) -> Result<()> {
        let json = serde_json::to_vec_pretty(meta).expect("metadata serializes");
        self.store.put(&self.meta_path(&meta.id), PutPayload::from(json)).await?;
        Ok(())
    }

    /// Streams a request body into `drops/{id}/files/{name}`, failing with
    /// [`WriteError::TooLarge`] as soon as more than `limit` bytes arrive.
    /// Returns the number of bytes written.
    pub async fn write_file<S, E>(&self, id: &str, name: &str, body: S, limit: u64) -> Result<u64, WriteError>
    where
        S: Stream<Item = std::result::Result<Bytes, E>> + Unpin,
        E: Into<BoxError>,
    {
        self.write_object(id, self.file_path(id, name), body, limit).await
    }

    /// Streams the encrypted manifest of a drop into `drops/{id}/manifest`, like [`Self::write_file`].
    pub async fn write_manifest<S, E>(&self, id: &str, body: S, limit: u64) -> Result<u64, WriteError>
    where
        S: Stream<Item = std::result::Result<Bytes, E>> + Unpin,
        E: Into<BoxError>,
    {
        self.write_object(id, self.manifest_path(id), body, limit).await
    }

    async fn write_object<S, E>(&self, id: &str, path: Path, mut body: S, limit: u64) -> Result<u64, WriteError>
    where
        S: Stream<Item = std::result::Result<Bytes, E>> + Unpin,
        E: Into<BoxError>,
    {
        let mut writer =
            BufWriter::with_capacity(self.store.clone(), path, PART_SIZE).with_max_concurrency(UPLOAD_CONCURRENCY);

        let mut written = 0u64;
        let streamed = async {
            while let Some(chunk) = body.next().await {
                let chunk = chunk.map_err(|e| WriteError::Body(e.into()))?;
                written += chunk.len() as u64;
                if written > limit {
                    return Err(WriteError::TooLarge);
                }
                writer.put(chunk).await.map_err(|e| WriteError::Storage(e.into()))?;
            }
            Ok(())
        }
        .await;

        match streamed {
            Ok(()) => {
                writer.shutdown().await.map_err(|e| WriteError::Storage(e.into()))?;
                Ok(written)
            }
            Err(e) => {
                if let Err(abort) = writer.abort().await {
                    tracing::warn!(drop = id, error = %abort, "failed to abort upload");
                }
                Err(e)
            }
        }
    }

    /// Opens a file for reading, optionally a byte range of it.
    pub async fn read_file(&self, id: &str, name: &str, range: Option<Range<u64>>) -> Result<Option<GetResult>> {
        let options = GetOptions { range: range.map(GetRange::Bounded), ..Default::default() };
        match self.store.get_opts(&self.file_path(id, name), options).await {
            Ok(result) => Ok(Some(result)),
            Err(object_store::Error::NotFound { .. }) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Reads the whole encrypted manifest (at most [`crate::e2ee::MAX_MANIFEST_BYTES`]).
    pub async fn read_manifest(&self, id: &str) -> Result<Option<Bytes>> {
        match self.store.get(&self.manifest_path(id)).await {
            Ok(result) => Ok(Some(result.bytes().await?)),
            Err(object_store::Error::NotFound { .. }) => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub async fn delete_file(&self, id: &str, name: &str) -> Result<()> {
        ignore_not_found(self.store.delete(&self.file_path(id, name)).await)
    }

    /// Deletes a drop: metadata first so links die immediately, then every
    /// object under its directory (including files missing from the metadata).
    pub async fn purge(&self, id: &str) -> Result<()> {
        ignore_not_found(self.store.delete(&self.meta_path(id)).await)?;
        self.delete_objects(id, None).await
    }

    /// Deletes objects under a drop's directory, optionally only those last
    /// modified before `older_than`.
    async fn delete_objects(&self, id: &str, older_than: Option<DateTime<Utc>>) -> Result<()> {
        let objects: Vec<Path> = self
            .store
            .list(Some(&self.drop_dir(id)))
            .try_filter(|o| std::future::ready(older_than.is_none_or(|t| o.last_modified < t)))
            .map_ok(|o| o.location)
            .try_collect()
            .await?;
        futures_util::stream::iter(objects)
            .map(|path| async move { ignore_not_found(self.store.delete(&path).await) })
            .buffer_unordered(8)
            .try_collect()
            .await
    }

    /// Ids of every drop directory in storage, expired or not.
    pub async fn list_ids(&self) -> Result<Vec<String>> {
        let listing = match self.store.list_with_delimiter(Some(&self.drops)).await {
            Ok(listing) => listing,
            Err(object_store::Error::NotFound { .. }) => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        Ok(listing
            .common_prefixes
            .iter()
            .filter_map(|p| p.filename())
            .filter(|id| ids::is_valid(id))
            .map(str::to_owned)
            .collect())
    }

    /// Every active drop, newest first.
    pub async fn list_active(&self, now: DateTime<Utc>) -> Result<Vec<DropMeta>> {
        let ids = self.list_ids().await?;
        let mut drops: Vec<DropMeta> = futures_util::stream::iter(ids)
            .map(|id| async move { self.load_active(&id, now).await })
            .buffer_unordered(16)
            .try_filter_map(|m| std::future::ready(Ok(m)))
            .try_collect()
            .await?;
        drops.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| a.id.cmp(&b.id)));
        Ok(drops)
    }

    /// Removes expired drops and stale orphaned objects. Returns how many drops were removed.
    pub async fn sweep(&self, now: DateTime<Utc>) -> Result<usize> {
        let mut removed = 0;
        for id in self.list_ids().await? {
            let _guard = self.lock(&id).await;
            match self.load(&id).await {
                Ok(Some(meta)) if meta.is_expired(now) => {
                    self.purge(&id).await?;
                    removed += 1;
                }
                Ok(Some(_)) => {}
                Ok(None) => self.delete_objects(&id, Some(now - ORPHAN_GRACE)).await?,
                Err(e) => tracing::warn!(drop = %id, error = %e, "skipping drop with unreadable metadata"),
            }
        }
        Ok(removed)
    }
}

impl Storage {
    pub async fn save_relay_room(&self, room: &str, record: &RelayRoom) -> Result<()> {
        let json = serde_json::to_vec(record).expect("relay room serializes");
        self.store.put(&self.relay_room_path(room), PutPayload::from(json)).await?;
        Ok(())
    }

    pub async fn delete_relay_room(&self, room: &str) -> Result<()> {
        ignore_not_found(self.store.delete(&self.relay_room_path(room)).await)
    }

    /// Every registered relay room.
    pub async fn list_relay_rooms(&self) -> Result<Vec<String>> {
        let objects: Vec<Path> =
            match self.store.list(Some(&self.relay_rooms)).map_ok(|o| o.location).try_collect().await {
                Ok(objects) => objects,
                Err(object_store::Error::NotFound { .. }) => return Ok(Vec::new()),
                Err(e) => return Err(e),
            };
        Ok(objects.iter().filter_map(|p| p.filename()).filter(|r| relay::is_valid_room(r)).map(str::to_owned).collect())
    }
}

fn ignore_not_found(result: Result<()>) -> Result<()> {
    match result {
        Err(object_store::Error::NotFound { .. }) => Ok(()),
        other => other,
    }
}

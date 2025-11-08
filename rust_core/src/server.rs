//! General server-related functions for things like
//! submitting items to the queue,
//! exporting csv files of views, etc.
use anyhow::Result;
use csv::Writer;
use neon_wasi_http::{Client, QueryBuilder};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Commit {
    pub device_id: String,
    pub location: String,
    pub delta: i32,
    pub item_id: i16,
}

#[allow(dead_code)]
pub struct NeonAPI {
    client: Client,
    connect_string: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct OverviewRow {
    location: String,
    item_id: i16,
    current_qty: i64,
}

#[derive(Debug, Serialize, Deserialize)]
struct LocationsRow {
    location: String,
    items: Vec<i16>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ItemsRow {
    id: i64,
    name: String,
}

#[allow(dead_code)]
impl NeonAPI {
    pub fn new(connect_string: impl Into<String>) -> Result<Self> {
        let connect_string = connect_string.into();
        let client = Client::new(&connect_string)?;

        Ok(Self {
            client,
            connect_string,
        })
    }

    pub async fn send_commit(&self, commit: &Commit) -> Result<()> {
        QueryBuilder::new(
            "INSERT INTO commits (device_id, location, delta, item_id) \
            VALUES ($1, $2, $3, $4)",
        )
        .bind(&commit.device_id)
        .bind(&commit.location)
        .bind(commit.delta)
        .bind(commit.item_id)
        .execute(&self.client)
        .await
    }

    pub async fn export_overview_to_csv(&self, path: &String) -> Result<()> {
        let rows: Vec<OverviewRow> = QueryBuilder::new("SELECT * FROM overview")
            .fetch_all(&self.client)
            .await?;

        let mut wtr = Writer::from_path(path)?;

        for row in rows {
            wtr.serialize(row)?;
        }

        wtr.flush()?;
        Ok(())
    }

    pub async fn export_location_data_to_csv(&self, path: &String) -> Result<()> {
        let rows: Vec<LocationsRow> = QueryBuilder::new("SELECT * FROM locations")
            .fetch_all(&self.client)
            .await?;

        let mut wtr = Writer::from_path(path)?;

        for row in rows {
            wtr.serialize(row)?;
        }

        wtr.flush()?;
        Ok(())
    }

    pub async fn export_items_to_csv(&self, path: &String) -> Result<()> {
        let rows: Vec<ItemsRow> = QueryBuilder::new("SELECT * FROM locations")
            .fetch_all(&self.client)
            .await?;

        let mut wtr = Writer::from_path(path)?;

        for row in rows {
            wtr.serialize(row)?;
        }

        wtr.flush()?;
        Ok(())
    }

    pub async fn check(&self) -> bool {
        QueryBuilder::new("SELECT id FROM items LIMIT 1")
            .execute(&self.client)
            .await
            .is_ok()
    }
}

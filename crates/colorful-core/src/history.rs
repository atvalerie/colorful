use crate::media::{MediaId, Track};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListenEvent {
    pub event_id: String,
    pub device_id: String,
    pub media_id: MediaId,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub listened_ms: u64,
    pub track_duration_ms: Option<u64>,
}

impl ListenEvent {
    pub fn is_valid(&self) -> bool {
        !self.event_id.trim().is_empty()
            && !self.device_id.trim().is_empty()
            && self.started_at_ms >= 0
            && self.ended_at_ms >= self.started_at_ms
            && self.listened_ms > 0
            && self.track_duration_ms.is_none_or(|duration| duration > 0)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TopTrack {
    pub track: Track,
    pub listened_ms: u64,
    pub play_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TopArtist {
    pub id: Option<MediaId>,
    pub name: String,
    pub listened_ms: u64,
    pub play_count: u64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListenStats {
    pub total_listened_ms: u64,
    pub play_count: u64,
    pub top_tracks: Vec<TopTrack>,
    pub top_artists: Vec<TopArtist>,
}

use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Tidal,
    SoundCloud,
    YouTube,
    Local,
}

impl fmt::Display for Provider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Tidal => "tidal",
            Self::SoundCloud => "soundcloud",
            Self::YouTube => "youtube",
            Self::Local => "local",
        })
    }
}

impl Provider {
    pub fn from_wire_name(value: &str) -> Option<Self> {
        match value {
            "tidal" => Some(Self::Tidal),
            "soundcloud" => Some(Self::SoundCloud),
            "youtube" => Some(Self::YouTube),
            "local" => Some(Self::Local),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaId {
    pub provider: Provider,
    pub provider_id: String,
}

impl MediaId {
    pub fn new(provider: Provider, provider_id: impl Into<String>) -> Option<Self> {
        let provider_id = provider_id.into();
        (!provider_id.trim().is_empty()).then_some(Self {
            provider,
            provider_id,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtistCredit {
    pub id: Option<MediaId>,
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Artwork {
    pub url: Option<String>,
    pub local_key: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: MediaId,
    pub title: String,
    pub version: Option<String>,
    pub artists: Vec<ArtistCredit>,
    pub album_id: Option<MediaId>,
    pub album_title: Option<String>,
    pub artwork: Option<Artwork>,
    pub duration_ms: Option<u64>,
    pub isrc: Option<String>,
    pub explicit: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_blank_provider_ids() {
        assert_eq!(MediaId::new(Provider::Tidal, "  "), None);
    }

    #[test]
    fn provider_names_are_stable_wire_values() {
        assert_eq!(Provider::SoundCloud.to_string(), "soundcloud");
        assert_eq!(
            Provider::from_wire_name("soundcloud"),
            Some(Provider::SoundCloud)
        );
        assert_eq!(Provider::from_wire_name("unknown"), None);
    }
}

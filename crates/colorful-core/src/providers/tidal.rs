use crate::media::{ArtistCredit, Artwork, MediaId, Provider, Track};
use serde_json::Value;
use std::collections::HashMap;
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TidalMappingError {
    InvalidDocument,
    InvalidTrackId,
}

impl fmt::Display for TidalMappingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidDocument => "TIDAL returned an invalid catalog document",
            Self::InvalidTrackId => "TIDAL returned a track without an ID",
        })
    }
}

impl std::error::Error for TidalMappingError {}

pub fn format_track_title(title: &str, version: Option<&str>) -> String {
    let title = match title.trim() {
        "" => "Unknown title",
        title => title,
    };
    let Some(version) = version.map(str::trim).filter(|version| !version.is_empty()) else {
        return title.to_owned();
    };
    let suffix = format!("({version})");
    if title.to_lowercase().ends_with(&suffix.to_lowercase()) {
        title.to_owned()
    } else {
        format!("{title} {suffix}")
    }
}

pub fn iso_duration_to_ms(duration: &str) -> Option<u64> {
    let value = duration.strip_prefix("PT")?;
    let mut number = String::new();
    let mut seconds = 0.0;
    for character in value.chars() {
        if character.is_ascii_digit() || character == '.' {
            number.push(character);
            continue;
        }
        if number.is_empty() {
            return None;
        }
        let part: f64 = number.parse().ok()?;
        number.clear();
        seconds += match character {
            'H' => part * 3600.0,
            'M' => part * 60.0,
            'S' => part,
            _ => return None,
        };
    }
    if !number.is_empty() || !seconds.is_finite() || seconds < 0.0 {
        return None;
    }
    Some((seconds * 1000.0).round() as u64)
}

pub fn map_tracks(document: &Value) -> Result<Vec<Track>, TidalMappingError> {
    let mut resources = HashMap::<(String, String), &Value>::new();
    for collection in [document.get("data"), document.get("included")] {
        match collection {
            Some(Value::Array(items)) => {
                for resource in items {
                    insert_resource(&mut resources, resource);
                }
            }
            Some(Value::Object(_)) => insert_resource(&mut resources, collection.unwrap()),
            Some(Value::Null) | None => {}
            _ => return Err(TidalMappingError::InvalidDocument),
        }
    }

    let mut track_ids = Vec::new();
    if let Some(data) = document.get("data") {
        let items: Vec<&Value> = match data {
            Value::Array(items) => items.iter().collect(),
            Value::Object(_) => vec![data],
            _ => return Err(TidalMappingError::InvalidDocument),
        };
        for item in items {
            if item.get("type").and_then(Value::as_str) == Some("tracks") {
                let id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or(TidalMappingError::InvalidTrackId)?;
                track_ids.push(id.to_owned());
            }
        }
    }
    if track_ids.is_empty() {
        track_ids.extend(
            resources
                .keys()
                .filter(|(resource_type, _)| resource_type == "tracks")
                .map(|(_, id)| id.clone()),
        );
        track_ids.sort();
    }

    track_ids
        .into_iter()
        .map(|id| map_track(&id, &resources))
        .collect()
}

fn insert_resource<'a>(resources: &mut HashMap<(String, String), &'a Value>, resource: &'a Value) {
    let Some(resource_type) = resource.get("type").and_then(Value::as_str) else {
        return;
    };
    let Some(id) = resource.get("id").and_then(Value::as_str) else {
        return;
    };
    let key = (resource_type.to_owned(), id.to_owned());
    let replace = resources.get(&key).is_none_or(|existing| {
        existing.get("attributes").is_none() && resource.get("attributes").is_some()
    });
    if replace {
        resources.insert(key, resource);
    }
}

fn map_track(
    id: &str,
    resources: &HashMap<(String, String), &Value>,
) -> Result<Track, TidalMappingError> {
    let resource = resources
        .get(&("tracks".to_owned(), id.to_owned()))
        .ok_or(TidalMappingError::InvalidTrackId)?;
    let attributes = resource.get("attributes").and_then(Value::as_object);
    let base_title = attributes
        .and_then(|attributes| attributes.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("Unknown title");
    let version = attributes
        .and_then(|attributes| attributes.get("version"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|version| !version.is_empty())
        .map(str::to_owned);

    let artist_ids = relationship_ids(resource, "artists");
    let artists = artist_ids
        .into_iter()
        .filter_map(|artist_id| {
            let artist = resources.get(&("artists".to_owned(), artist_id.clone()))?;
            let name = artist.get("attributes")?.get("name")?.as_str()?.trim();
            (!name.is_empty()).then(|| ArtistCredit {
                id: MediaId::new(Provider::Tidal, artist_id),
                name: name.to_owned(),
            })
        })
        .collect();

    let album_provider_id = relationship_ids(resource, "albums").into_iter().next();
    let album = album_provider_id
        .as_ref()
        .and_then(|album_id| resources.get(&("albums".to_owned(), album_id.clone())))
        .copied();
    let album_title = album
        .and_then(|album| album.get("attributes"))
        .and_then(|attributes| attributes.get("title"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(str::to_owned);
    let artwork = album
        .and_then(|album| relationship_ids(album, "coverArt").into_iter().next())
        .and_then(|artwork_id| resources.get(&("artworks".to_owned(), artwork_id)).copied())
        .and_then(map_artwork);

    Ok(Track {
        id: MediaId::new(Provider::Tidal, id).ok_or(TidalMappingError::InvalidTrackId)?,
        title: format_track_title(base_title, version.as_deref()),
        version,
        artists,
        album_id: album_provider_id.and_then(|id| MediaId::new(Provider::Tidal, id)),
        album_title,
        artwork,
        duration_ms: attributes
            .and_then(|attributes| attributes.get("duration"))
            .and_then(Value::as_str)
            .and_then(iso_duration_to_ms),
        isrc: attributes
            .and_then(|attributes| attributes.get("isrc"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        explicit: attributes
            .and_then(|attributes| attributes.get("explicit"))
            .and_then(Value::as_bool),
    })
}

fn relationship_ids(resource: &Value, relationship: &str) -> Vec<String> {
    resource
        .get("relationships")
        .and_then(|relationships| relationships.get(relationship))
        .and_then(|relationship| relationship.get("data"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| item.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

fn map_artwork(resource: &Value) -> Option<Artwork> {
    let file = resource
        .get("attributes")?
        .get("files")?
        .as_array()?
        .first()?;
    let url = file.get("href").and_then(Value::as_str).map(str::to_owned);
    let width = file
        .get("meta")
        .and_then(|meta| meta.get("width"))
        .and_then(Value::as_u64)
        .and_then(|value| value.try_into().ok());
    let height = file
        .get("meta")
        .and_then(|meta| meta.get("height"))
        .and_then(Value::as_u64)
        .and_then(|value| value.try_into().ok());
    Some(Artwork {
        url,
        local_key: None,
        width,
        height,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEARCH_FIXTURE: &str = include_str!("../../../../fixtures/tidal/search-tracks.json");

    #[test]
    fn parses_iso_durations_without_a_time_runtime() {
        assert_eq!(iso_duration_to_ms("PT3M12.5S"), Some(192_500));
        assert_eq!(iso_duration_to_ms("PT1H2M3S"), Some(3_723_000));
        assert_eq!(iso_duration_to_ms("nope"), None);
    }

    #[test]
    fn maps_the_shared_tidal_search_fixture() {
        let document: Value = serde_json::from_str(SEARCH_FIXTURE).unwrap();
        let tracks = map_tracks(&document).unwrap();

        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[0].title, "Brutal (Instrumental)");
        assert_eq!(tracks[0].duration_ms, Some(151_000));
        assert_eq!(tracks[0].artwork.as_ref().unwrap().width, Some(1280));
        assert_eq!(tracks[1].title, "Brutal (Live)");
        assert_eq!(tracks[1].artists.len(), 2);
        assert_eq!(tracks[1].explicit, Some(true));
    }
}

use crate::media::MediaId;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RepeatMode {
    #[default]
    Off,
    All,
    One,
}

/// Frequencies used by every colorful platform's graphic equalizer.
pub const EQUALIZER_FREQUENCIES_HZ: [u32; 10] =
    [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000];

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioProcessingSettings {
    pub normalization_enabled: bool,
    pub equalizer_db: [f32; 10],
}

impl Default for AudioProcessingSettings {
    fn default() -> Self {
        Self {
            normalization_enabled: false,
            equalizer_db: [0.0; 10],
        }
    }
}

impl AudioProcessingSettings {
    pub fn sanitized(mut self) -> Self {
        for gain in &mut self.equalizer_db {
            *gain = if gain.is_finite() {
                gain.clamp(-12.0, 12.0)
            } else {
                0.0
            };
        }
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlaybackCommand {
    Play,
    Pause,
    SeekTo { position_ms: u64 },
    SkipNext,
    SkipPrevious,
    SetRepeat(RepeatMode),
    SetShuffle(bool),
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackState {
    pub current: Option<MediaId>,
    pub position_ms: u64,
    pub playing: bool,
    pub repeat: RepeatMode,
    pub shuffle: bool,
}

impl PlaybackState {
    pub fn apply_control(&mut self, command: PlaybackCommand) {
        match command {
            PlaybackCommand::Play if self.current.is_some() => self.playing = true,
            PlaybackCommand::Pause => self.playing = false,
            PlaybackCommand::SeekTo { position_ms } if self.current.is_some() => {
                self.position_ms = position_ms;
            }
            PlaybackCommand::SetRepeat(repeat) => self.repeat = repeat,
            PlaybackCommand::SetShuffle(shuffle) => self.shuffle = shuffle,
            PlaybackCommand::Play
            | PlaybackCommand::SeekTo { .. }
            | PlaybackCommand::SkipNext
            | PlaybackCommand::SkipPrevious => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Provider;

    #[test]
    fn cannot_play_an_empty_queue() {
        let mut state = PlaybackState::default();
        state.apply_control(PlaybackCommand::Play);
        assert!(!state.playing);
    }

    #[test]
    fn control_changes_are_deterministic() {
        let mut state = PlaybackState {
            current: MediaId::new(Provider::Tidal, "42"),
            ..PlaybackState::default()
        };
        state.apply_control(PlaybackCommand::Play);
        state.apply_control(PlaybackCommand::SeekTo { position_ms: 1234 });
        state.apply_control(PlaybackCommand::SetRepeat(RepeatMode::All));
        assert!(state.playing);
        assert_eq!(state.position_ms, 1234);
        assert_eq!(state.repeat, RepeatMode::All);
    }

    #[test]
    fn audio_processing_values_are_portable_and_bounded() {
        let settings = AudioProcessingSettings {
            normalization_enabled: true,
            equalizer_db: [f32::NAN, -20.0, 20.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
        }
        .sanitized();
        assert_eq!(settings.equalizer_db[0], 0.0);
        assert_eq!(settings.equalizer_db[1], -12.0);
        assert_eq!(settings.equalizer_db[2], 12.0);
    }
}

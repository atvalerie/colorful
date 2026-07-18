use crate::media::MediaId;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum RepeatMode {
    #[default]
    Off,
    All,
    One,
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
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
}

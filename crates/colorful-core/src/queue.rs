use crate::media::MediaId;
use crate::playback::RepeatMode;

/// Identifies one occurrence of a track in the queue.
///
/// A media ID is not sufficient because the same track may be queued more than
/// once. Entry IDs remain stable while entries are reordered or shuffle is
/// toggled.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct QueueEntryId(u64);

impl QueueEntryId {
    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueueEntry {
    pub id: QueueEntryId,
    pub media_id: MediaId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlaybackQueue {
    entries: Vec<QueueEntry>,
    play_order: Vec<QueueEntryId>,
    current: Option<QueueEntryId>,
    shuffle: bool,
    shuffle_seed: u64,
    next_entry_id: u64,
}

impl Default for PlaybackQueue {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            play_order: Vec::new(),
            current: None,
            shuffle: false,
            shuffle_seed: 0,
            next_entry_id: 1,
        }
    }
}

impl PlaybackQueue {
    pub fn new() -> Self {
        Self::default()
    }

    /// User-visible queue order. Shuffle changes playback order, not this list.
    pub fn entries(&self) -> &[QueueEntry] {
        &self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn current(&self) -> Option<&QueueEntry> {
        let current = self.current?;
        self.entry(current)
    }

    pub fn current_id(&self) -> Option<QueueEntryId> {
        self.current
    }

    pub fn shuffle_enabled(&self) -> bool {
        self.shuffle
    }

    pub fn replace(&mut self, media: impl IntoIterator<Item = MediaId>) {
        self.entries.clear();
        self.play_order.clear();
        self.current = None;

        for media_id in media {
            let entry = self.make_entry(media_id);
            self.play_order.push(entry.id);
            self.entries.push(entry);
        }

        self.current = self.play_order.first().copied();
        if self.shuffle {
            self.rebuild_play_order();
        }
    }

    pub fn append(&mut self, media_id: MediaId) -> QueueEntryId {
        let entry = self.make_entry(media_id);
        let id = entry.id;
        self.entries.push(entry);
        self.play_order.push(id);
        if self.current.is_none() {
            self.current = Some(id);
        }
        id
    }

    /// Adds an item immediately after the current item in playback order.
    pub fn play_next(&mut self, media_id: MediaId) -> QueueEntryId {
        let entry = self.make_entry(media_id);
        let id = entry.id;

        let visible_index = self
            .current
            .and_then(|current| self.visible_index(current))
            .map_or(self.entries.len(), |index| index + 1);
        self.entries.insert(visible_index, entry);

        let playback_index = self
            .current
            .and_then(|current| self.playback_index(current))
            .map_or(self.play_order.len(), |index| index + 1);
        self.play_order.insert(playback_index, id);

        if self.current.is_none() {
            self.current = Some(id);
        }
        id
    }

    pub fn remove(&mut self, id: QueueEntryId) -> Option<QueueEntry> {
        let visible_index = self.visible_index(id)?;
        let playback_index = self.playback_index(id);
        let was_current = self.current == Some(id);
        let removed = self.entries.remove(visible_index);
        if let Some(index) = playback_index {
            self.play_order.remove(index);
            if was_current {
                self.current = self
                    .play_order
                    .get(index)
                    .or_else(|| self.play_order.last())
                    .copied();
            }
        }
        Some(removed)
    }

    /// Reorders the user-visible queue without disrupting an active shuffle.
    pub fn move_entry(&mut self, id: QueueEntryId, target_index: usize) -> bool {
        let Some(source_index) = self.visible_index(id) else {
            return false;
        };
        if self.entries.len() < 2 {
            return true;
        }

        let entry = self.entries.remove(source_index);
        let target_index = target_index.min(self.entries.len());
        self.entries.insert(target_index, entry);

        if !self.shuffle {
            self.play_order = self.entries.iter().map(|entry| entry.id).collect();
        }
        true
    }

    pub fn select(&mut self, id: QueueEntryId) -> bool {
        if self.entry(id).is_none() {
            return false;
        }
        self.current = Some(id);
        true
    }

    /// Advances after a track completes or the user presses Next.
    ///
    /// At the end with repeat disabled, the current entry remains selected and
    /// `None` signals that playback should stop.
    pub fn advance(&mut self, repeat: RepeatMode) -> Option<&QueueEntry> {
        let current = self.current?;
        if repeat == RepeatMode::One {
            return self.entry(current);
        }

        let index = self.playback_index(current)?;
        let next = self.play_order.get(index + 1).copied().or_else(|| {
            (repeat == RepeatMode::All)
                .then(|| self.play_order.first().copied())
                .flatten()
        });
        if let Some(next) = next {
            self.current = Some(next);
        }
        next.and_then(|id| self.entry(id))
    }

    /// Goes back in playback order. At the start, Repeat All wraps to the end.
    pub fn retreat(&mut self, repeat: RepeatMode) -> Option<&QueueEntry> {
        let current = self.current?;
        let index = self.playback_index(current)?;
        let previous = index
            .checked_sub(1)
            .and_then(|i| self.play_order.get(i).copied())
            .or_else(|| {
                (repeat == RepeatMode::All)
                    .then(|| self.play_order.last().copied())
                    .flatten()
            });
        if let Some(previous) = previous {
            self.current = Some(previous);
        }
        previous.and_then(|id| self.entry(id))
    }

    /// Enables reproducible shuffle. Supplying the seed makes queue behavior
    /// testable and allows a persisted session to reconstruct its play order.
    pub fn set_shuffle(&mut self, enabled: bool, seed: u64) {
        if self.shuffle == enabled && (!enabled || self.shuffle_seed == seed) {
            return;
        }
        self.shuffle = enabled;
        self.shuffle_seed = seed;
        self.rebuild_play_order();
    }

    fn rebuild_play_order(&mut self) {
        self.play_order = self.entries.iter().map(|entry| entry.id).collect();
        if !self.shuffle || self.play_order.len() < 2 {
            return;
        }

        let mut state = self.shuffle_seed;
        for upper in (1..self.play_order.len()).rev() {
            state = splitmix64(state);
            let other = (state % (upper as u64 + 1)) as usize;
            self.play_order.swap(upper, other);
        }

        // Toggling shuffle must not unexpectedly replace what is playing.
        if let Some(current) = self.current
            && let Some(index) = self.playback_index(current)
        {
            self.play_order.rotate_left(index);
        }
    }

    fn make_entry(&mut self, media_id: MediaId) -> QueueEntry {
        let id = QueueEntryId(self.next_entry_id);
        self.next_entry_id = self
            .next_entry_id
            .checked_add(1)
            .expect("queue entry ID space exhausted");
        QueueEntry { id, media_id }
    }

    fn entry(&self, id: QueueEntryId) -> Option<&QueueEntry> {
        self.entries.iter().find(|entry| entry.id == id)
    }

    fn visible_index(&self, id: QueueEntryId) -> Option<usize> {
        self.entries.iter().position(|entry| entry.id == id)
    }

    fn playback_index(&self, id: QueueEntryId) -> Option<usize> {
        self.play_order
            .iter()
            .position(|candidate| *candidate == id)
    }
}

fn splitmix64(mut value: u64) -> u64 {
    value = value.wrapping_add(0x9e3779b97f4a7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d049bb133111eb);
    value ^ (value >> 31)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Provider;

    fn media(id: &str) -> MediaId {
        MediaId::new(Provider::Tidal, id).unwrap()
    }

    fn current_provider_id(queue: &PlaybackQueue) -> Option<&str> {
        queue
            .current()
            .map(|entry| entry.media_id.provider_id.as_str())
    }

    #[test]
    fn duplicate_tracks_have_distinct_stable_entry_ids() {
        let mut queue = PlaybackQueue::new();
        let first = queue.append(media("42"));
        let second = queue.append(media("42"));

        assert_ne!(first, second);
        assert_eq!(queue.entries()[0].media_id, queue.entries()[1].media_id);
        queue.move_entry(second, 0);
        assert_eq!(queue.entries()[0].id, second);
    }

    #[test]
    fn play_next_inserts_after_current_even_while_shuffled() {
        let mut queue = PlaybackQueue::new();
        queue.replace([media("a"), media("b"), media("c"), media("d")]);
        queue.set_shuffle(true, 123);

        let inserted = queue.play_next(media("next"));
        assert_eq!(
            queue.advance(RepeatMode::Off).map(|entry| entry.id),
            Some(inserted)
        );
    }

    #[test]
    fn removing_current_selects_its_successor_then_predecessor() {
        let mut queue = PlaybackQueue::new();
        queue.replace([media("a"), media("b"), media("c")]);
        let middle = queue.entries()[1].id;
        queue.select(middle);

        queue.remove(middle);
        assert_eq!(current_provider_id(&queue), Some("c"));
        let last = queue.current_id().unwrap();
        queue.remove(last);
        assert_eq!(current_provider_id(&queue), Some("a"));
    }

    #[test]
    fn repeat_modes_have_distinct_end_of_queue_behavior() {
        let mut queue = PlaybackQueue::new();
        queue.replace([media("a"), media("b")]);
        queue.advance(RepeatMode::Off);

        assert!(queue.advance(RepeatMode::Off).is_none());
        assert_eq!(current_provider_id(&queue), Some("b"));
        assert_eq!(
            queue
                .advance(RepeatMode::All)
                .map(|entry| entry.media_id.provider_id.as_str()),
            Some("a")
        );
        assert_eq!(
            queue
                .advance(RepeatMode::One)
                .map(|entry| entry.media_id.provider_id.as_str()),
            Some("a")
        );
    }

    #[test]
    fn shuffle_is_reproducible_and_keeps_current_track() {
        let tracks = [media("a"), media("b"), media("c"), media("d"), media("e")];
        let mut first = PlaybackQueue::new();
        let mut second = PlaybackQueue::new();
        first.replace(tracks.clone());
        second.replace(tracks);
        let selected = first.entries()[2].id;
        first.select(selected);
        second.select(second.entries()[2].id);

        first.set_shuffle(true, 99);
        second.set_shuffle(true, 99);
        assert_eq!(current_provider_id(&first), Some("c"));
        assert_eq!(current_provider_id(&second), Some("c"));

        let first_order: Vec<_> = std::iter::from_fn(|| {
            first
                .advance(RepeatMode::All)
                .map(|entry| entry.media_id.provider_id.clone())
        })
        .take(4)
        .collect();
        let second_order: Vec<_> = std::iter::from_fn(|| {
            second
                .advance(RepeatMode::All)
                .map(|entry| entry.media_id.provider_id.clone())
        })
        .take(4)
        .collect();
        assert_eq!(first_order, second_order);
    }

    #[test]
    fn disabling_shuffle_resumes_visible_order_after_current() {
        let mut queue = PlaybackQueue::new();
        queue.replace([media("a"), media("b"), media("c")]);
        let middle = queue.entries()[1].id;
        queue.select(middle);
        queue.set_shuffle(true, 7);
        queue.set_shuffle(false, 0);

        assert_eq!(
            queue
                .advance(RepeatMode::Off)
                .map(|entry| entry.media_id.provider_id.as_str()),
            Some("c")
        );
    }
}

import { useMemo, useState } from "react";
import { Icon, type IconName } from "./Icon";
import { palettes, tracks, type Palette, type Track } from "./mock";

type Viewport = "desktop" | "mobile";
type Screen = "discover" | "album" | "player";

const screenLabels: Record<Screen, string> = {
  discover: "Discover",
  album: "Album",
  player: "Player",
};

function Cover({ palette, size = "regular" }: { palette: Palette; size?: "small" | "regular" | "hero" }) {
  return (
    <div
      className={`cover cover--${size}`}
      style={{
        "--cover-a": palette.primary,
        "--cover-b": palette.secondary,
        "--cover-deep": palette.deep,
      } as React.CSSProperties}
    >
      <span className="cover__orb cover__orb--one" />
      <span className="cover__orb cover__orb--two" />
      <span className="cover__grain" />
    </div>
  );
}

function ToolIcon({ name }: { name: IconName }) {
  return <Icon className="icon" name={name} />;
}

function TrackRow({
  track,
  active,
  number,
  onPlay,
  onQueue,
}: {
  track: Track;
  active: boolean;
  number?: number;
  onPlay: () => void;
  onQueue: () => void;
}) {
  return (
    <div className={`track-row ${active ? "is-active" : ""}`}>
      <button className="track-row__main" onClick={onPlay}>
        {number === undefined
          ? <Cover palette={palettes[track.palette]!} size="small" />
          : <span className="track-row__number">{active ? <ToolIcon name="pause" /> : number}</span>}
        <span className="track-row__copy">
          <strong>{track.title}</strong>
          <span>{track.artist} · {track.album}</span>
        </span>
      </button>
      <span className="track-row__duration">{track.duration}</span>
      <button className="icon-button" onClick={onQueue} aria-label={`Queue ${track.title}`}><ToolIcon name="add" /></button>
    </div>
  );
}

function PlayerDock({
  current,
  playing,
  queueCount,
  onToggle,
  onExpand,
}: {
  current: Track;
  playing: boolean;
  queueCount: number;
  onToggle: () => void;
  onExpand: () => void;
}) {
  return (
    <div className="player-dock">
      <div className="player-dock__identity">
        <button className="player-dock__track" onClick={onExpand}>
          <Cover palette={palettes[current.palette]!} size="small" />
          <span><strong>{current.title}</strong><small>{current.artist}</small></span>
        </button>
        <button className="transport-button player-dock__like" aria-label="Save track"><ToolIcon name="heart" /></button>
      </div>
      <div className="player-dock__center">
        <div className="player-dock__controls">
          <button className="transport-button" aria-label="Shuffle"><ToolIcon name="shuffle" /></button>
          <button className="transport-button" aria-label="Previous"><ToolIcon name="previous" /></button>
          <button className="play-button" onClick={onToggle} aria-label={playing ? "Pause" : "Play"}><ToolIcon name={playing ? "pause" : "play"} /></button>
          <button className="transport-button" aria-label="Next"><ToolIcon name="next" /></button>
          <button className="transport-button" aria-label="Repeat"><ToolIcon name="repeat" /></button>
        </div>
        <div className="player-dock__timeline">
          <span>1:17</span><i><b style={{ width: "38%" }} /></i><span>{current.duration}</span>
        </div>
      </div>
      <div className="player-dock__utilities">
        <button className="transport-button" aria-label="Volume"><ToolIcon name="volume" /></button>
        <i className="volume"><b style={{ width: "72%" }} /></i>
        <button className="transport-button" aria-label="Available devices"><ToolIcon name="device" /></button>
        <button className="transport-button queue-button" aria-label={`Queue, ${queueCount} tracks`}><ToolIcon name="queue" />{queueCount > 0 && <span>{queueCount}</span>}</button>
      </div>
    </div>
  );
}

function Navigation({ screen, onScreen }: { screen: Screen; onScreen: (screen: Screen) => void }) {
  return (
    <nav className="navigation">
      <div className="navigation__items">
        <button className={screen === "discover" ? "is-active" : ""} onClick={() => onScreen("discover")}><ToolIcon name="discover" /><span>Discover</span></button>
        <button className={screen === "album" ? "is-active" : ""} onClick={() => onScreen("album")}><ToolIcon name="library" /><span>Library</span></button>
        <button><ToolIcon name="download" /><span>Offline</span></button>
      </div>
      <button className="avatar">V</button>
    </nav>
  );
}

function Discover({ current, onOpenAlbum, onPlay, onQueue }: { current: Track; onOpenAlbum: (track: Track) => void; onPlay: (track: Track) => void; onQueue: (track: Track) => void }) {
  return (
    <main className="screen discover-screen">
      <header className="topbar">
        <div className="history-controls">
          <button className="round-button" aria-label="Go back"><ToolIcon name="back" /></button>
          <button className="round-button" aria-label="Go forward"><ToolIcon name="forward" /></button>
        </div>
        <label className="search"><ToolIcon name="search" /><input placeholder="Search music, artists, albums" /></label>
        <button className="round-button"><ToolIcon name="more" /></button>
      </header>
      <section className="welcome">
        <h1>Good evening, Valerie</h1>
      </section>
      <section className="section-block">
        <div className="section-heading"><div><h2>Recently played</h2></div><button>See all</button></div>
        <div className="album-strip">
          {palettes.map((palette, index) => (
            <button className="album-card" key={palette.name} onClick={() => onOpenAlbum(tracks[index] ?? tracks[0]!)}>
              <Cover palette={palette} />
              <strong>{tracks[index]?.album ?? palette.name}</strong>
              <span>{tracks[index]?.artist ?? "colorful mix"}</span>
            </button>
          ))}
        </div>
      </section>
      <section className="section-block tracks-block">
        <div className="section-heading"><div><h2>Keep listening</h2></div></div>
        <div className="track-list">
          {tracks.slice(0, 4).map((track) => <TrackRow key={track.id} track={track} active={track.id === current.id} onPlay={() => onPlay(track)} onQueue={() => onQueue(track)} />)}
        </div>
      </section>
    </main>
  );
}

function AlbumScreen({ current, onBack, onPlay, onQueue }: { current: Track; onBack: () => void; onPlay: (track: Track) => void; onQueue: (track: Track) => void }) {
  const palette = palettes[current.palette]!;
  return (
    <main className="screen album-screen">
      <header className="topbar"><button className="round-button" onClick={onBack}><ToolIcon name="back" /></button><span /><button className="round-button"><ToolIcon name="more" /></button></header>
      <section className="album-hero">
        <Cover palette={palette} size="hero" />
        <div className="album-hero__copy"><span className="eyebrow">ALBUM · 2026</span><h1>{current.album}</h1><p>{current.artist}</p><div><button className="primary-action" onClick={() => onPlay(current)}><ToolIcon name="play" /> Play</button><button className="round-button"><ToolIcon name="add" /></button></div></div>
      </section>
      <section className="album-tracks">
        {tracks.filter((track) => track.palette === current.palette).concat(tracks.slice(0, 3)).map((track, index) => (
          <TrackRow key={`${track.id}-${index}`} track={track} number={index + 1} active={track.id === current.id} onPlay={() => onPlay(track)} onQueue={() => onQueue(track)} />
        ))}
      </section>
    </main>
  );
}

function FullPlayer({ current, playing, onCollapse, onToggle }: { current: Track; playing: boolean; onCollapse: () => void; onToggle: () => void }) {
  const palette = palettes[current.palette]!;
  return (
    <main className="screen full-player">
      <header className="topbar"><button className="round-button" onClick={onCollapse}><ToolIcon name="collapse" /></button><span /><button className="round-button"><ToolIcon name="more" /></button></header>
      <section className="full-player__body">
        <Cover palette={palette} size="hero" />
        <div className="full-player__info"><h1>{current.title}</h1><p>{current.artist} · {current.album}</p><div className="big-controls"><button><ToolIcon name="shuffle" /></button><button><ToolIcon name="previous" /></button><button className="play-button play-button--large" onClick={onToggle}><ToolIcon name={playing ? "pause" : "play"} /></button><button><ToolIcon name="next" /></button><button><ToolIcon name="repeat" /></button></div><div className="big-timeline"><i><b style={{ width: "38%" }} /></i><span>1:17</span><span>{current.duration}</span></div><div className="player-secondary"><button><ToolIcon name="heart" /> Save</button><button><ToolIcon name="queue" /> Queue</button><button><ToolIcon name="device" /> This device</button></div></div>
      </section>
    </main>
  );
}

function Prototype({ viewport, screen, paletteIndex, onScreen }: { viewport: Viewport; screen: Screen; paletteIndex: number; onScreen: (screen: Screen) => void }) {
  const initial = tracks.find((track) => track.palette === paletteIndex) ?? tracks[0]!;
  const [current, setCurrent] = useState(initial);
  const [playing, setPlaying] = useState(true);
  const [queue, setQueue] = useState<Track[]>([tracks[1]!, tracks[4]!]);
  const palette = palettes[current.palette]!;

  const queueTrack = (track: Track) => setQueue((value) => value.some((item) => item.id === track.id) ? value : [...value, track]);
  const playTrack = (track: Track) => { setCurrent(track); setPlaying(true); };
  const openAlbum = (track: Track) => { setCurrent(track); onScreen("album"); };

  return (
    <div className={`prototype is-${viewport}`} style={{ "--accent": palette.primary, "--accent-2": palette.secondary, "--deep": palette.deep, "--glow": palette.glow } as React.CSSProperties}>
      <div className="prototype__wash" />
      <Navigation screen={screen} onScreen={onScreen} />
      {screen === "discover" && <Discover current={current} onOpenAlbum={openAlbum} onPlay={playTrack} onQueue={queueTrack} />}
      {screen === "album" && <AlbumScreen current={current} onBack={() => onScreen("discover")} onPlay={playTrack} onQueue={queueTrack} />}
      {screen === "player" && <FullPlayer current={current} playing={playing} onCollapse={() => onScreen("discover")} onToggle={() => setPlaying((value) => !value)} />}
      {screen !== "player" && <PlayerDock current={current} playing={playing} queueCount={queue.length} onToggle={() => setPlaying((value) => !value)} onExpand={() => onScreen("player")} />}
    </div>
  );
}

export function App() {
  const [viewport, setViewport] = useState<Viewport>("desktop");
  const [screen, setScreen] = useState<Screen>("discover");
  const [paletteIndex, setPaletteIndex] = useState(0);
  const palette = useMemo(() => palettes[paletteIndex]!, [paletteIndex]);

  return (
    <div className="lab" style={{ "--lab-accent": palette.primary } as React.CSSProperties}>
      <header className="lab-toolbar">
        <div className="lab-toolbar__title"><div><strong>colorful Design Lab</strong><small>Disposable UI prototype</small></div></div>
        <div className="lab-control"><span>Canvas</span><div className="segmented"><button className={viewport === "desktop" ? "is-active" : ""} onClick={() => setViewport("desktop")}>Desktop</button><button className={viewport === "mobile" ? "is-active" : ""} onClick={() => setViewport("mobile")}>Mobile</button></div></div>
        <div className="lab-control"><span>Screen</span><div className="segmented">{(Object.keys(screenLabels) as Screen[]).map((value) => <button key={value} className={screen === value ? "is-active" : ""} onClick={() => setScreen(value)}>{screenLabels[value]}</button>)}</div></div>
        <div className="lab-control palette-control"><span>Album color</span><div>{palettes.map((value, index) => <button key={value.name} className={index === paletteIndex ? "is-active" : ""} style={{ background: value.primary }} onClick={() => setPaletteIndex(index)} aria-label={value.name} />)}</div></div>
      </header>
      <div className="lab-stage"><Prototype key={paletteIndex} viewport={viewport} screen={screen} paletteIndex={paletteIndex} onScreen={setScreen} /></div>
      <footer className="lab-note">Everything inside the canvas is fake and safe to throw away. Pick it apart.</footer>
    </div>
  );
}

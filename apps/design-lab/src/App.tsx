import { useMemo, useState } from "react";
import { palettes, tracks, type Palette, type Track } from "./mock";

type Viewport = "desktop" | "mobile";
type Screen = "discover" | "album" | "player";

const screenLabels: Record<Screen, string> = {
  discover: "Discover",
  album: "Album",
  player: "Full player",
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

function Glyph({ children }: { children: React.ReactNode }) {
  return <span className="glyph" aria-hidden="true">{children}</span>;
}

function TrackRow({
  track,
  active,
  onPlay,
  onQueue,
}: {
  track: Track;
  active: boolean;
  onPlay: () => void;
  onQueue: () => void;
}) {
  return (
    <div className={`track-row ${active ? "is-active" : ""}`}>
      <button className="track-row__main" onClick={onPlay}>
        <Cover palette={palettes[track.palette]!} size="small" />
        <span className="track-row__copy">
          <strong>{track.title}</strong>
          <span>{track.artist} · {track.album}</span>
        </span>
      </button>
      <span className="track-row__duration">{track.duration}</span>
      <button className="icon-button" onClick={onQueue} aria-label={`Queue ${track.title}`}><Glyph>＋</Glyph></button>
    </div>
  );
}

function PlayerDock({
  current,
  playing,
  onToggle,
  onExpand,
}: {
  current: Track;
  playing: boolean;
  onToggle: () => void;
  onExpand: () => void;
}) {
  return (
    <div className="player-dock">
      <button className="player-dock__track" onClick={onExpand}>
        <Cover palette={palettes[current.palette]!} size="small" />
        <span><strong>{current.title}</strong><small>{current.artist}</small></span>
      </button>
      <div className="player-dock__controls">
        <button className="icon-button"><Glyph>‹</Glyph></button>
        <button className="play-button" onClick={onToggle}>{playing ? "Ⅱ" : "▶"}</button>
        <button className="icon-button"><Glyph>›</Glyph></button>
      </div>
      <div className="player-dock__timeline">
        <span>1:17</span><i><b style={{ width: "38%" }} /></i><span>{current.duration}</span>
      </div>
      <button className="icon-button player-dock__queue"><Glyph>≡</Glyph></button>
    </div>
  );
}

function Navigation({ screen, onScreen }: { screen: Screen; onScreen: (screen: Screen) => void }) {
  return (
    <nav className="navigation">
      <button className="brand" onClick={() => onScreen("discover")}><span>c</span><strong>colorful</strong></button>
      <div className="navigation__items">
        <button className={screen === "discover" ? "is-active" : ""} onClick={() => onScreen("discover")}><Glyph>⌁</Glyph><span>Discover</span></button>
        <button className={screen === "album" ? "is-active" : ""} onClick={() => onScreen("album")}><Glyph>◫</Glyph><span>Library</span></button>
        <button><Glyph>↓</Glyph><span>Offline</span></button>
      </div>
      <button className="avatar">V</button>
    </nav>
  );
}

function Discover({ current, onPlay, onQueue }: { current: Track; onPlay: (track: Track) => void; onQueue: (track: Track) => void }) {
  return (
    <main className="screen discover-screen">
      <header className="topbar">
        <label className="search"><Glyph>⌕</Glyph><input placeholder="What do you want to hear?" /></label>
        <button className="round-button"><Glyph>⋯</Glyph></button>
      </header>
      <section className="welcome">
        <span className="eyebrow">GOOD EVENING, VALERIE</span>
        <h1>Pick a color.<br />Find a feeling.</h1>
      </section>
      <section className="section-block">
        <div className="section-heading"><div><span className="eyebrow">MADE FOR RIGHT NOW</span><h2>Recently glowing</h2></div><button>See all</button></div>
        <div className="album-strip">
          {palettes.map((palette, index) => (
            <button className="album-card" key={palette.name} onClick={() => onPlay(tracks[index] ?? tracks[0]!)}>
              <Cover palette={palette} />
              <strong>{tracks[index]?.album ?? palette.name}</strong>
              <span>{tracks[index]?.artist ?? "Colorful mix"}</span>
            </button>
          ))}
        </div>
      </section>
      <section className="section-block tracks-block">
        <div className="section-heading"><div><span className="eyebrow">BACK IN ROTATION</span><h2>Keep listening</h2></div></div>
        <div className="track-list">
          {tracks.slice(0, 4).map((track) => <TrackRow key={track.id} track={track} active={track.id === current.id} onPlay={() => onPlay(track)} onQueue={() => onQueue(track)} />)}
        </div>
      </section>
    </main>
  );
}

function AlbumScreen({ current, onPlay, onQueue }: { current: Track; onPlay: (track: Track) => void; onQueue: (track: Track) => void }) {
  const palette = palettes[current.palette]!;
  return (
    <main className="screen album-screen">
      <header className="topbar"><button className="round-button"><Glyph>←</Glyph></button><span /><button className="round-button"><Glyph>⋯</Glyph></button></header>
      <section className="album-hero">
        <Cover palette={palette} size="hero" />
        <div className="album-hero__copy"><span className="eyebrow">ALBUM · 2026</span><h1>{current.album}</h1><p>{current.artist}</p><div><button className="primary-action" onClick={() => onPlay(current)}>▶ Play</button><button className="round-button">＋</button></div></div>
      </section>
      <section className="album-tracks">
        {tracks.filter((track) => track.palette === current.palette).concat(tracks.slice(0, 3)).map((track, index) => (
          <TrackRow key={`${track.id}-${index}`} track={track} active={track.id === current.id} onPlay={() => onPlay(track)} onQueue={() => onQueue(track)} />
        ))}
      </section>
    </main>
  );
}

function FullPlayer({ current, playing, queue, onToggle }: { current: Track; playing: boolean; queue: Track[]; onToggle: () => void }) {
  const palette = palettes[current.palette]!;
  return (
    <main className="screen full-player">
      <header className="topbar"><button className="round-button"><Glyph>⌄</Glyph></button><span className="eyebrow">NOW PLAYING</span><button className="round-button"><Glyph>⋯</Glyph></button></header>
      <section className="full-player__body">
        <Cover palette={palette} size="hero" />
        <div className="full-player__info"><span className="eyebrow">FROM {current.album.toUpperCase()}</span><h1>{current.title}</h1><p>{current.artist}</p><div className="big-timeline"><i><b style={{ width: "38%" }} /></i><span>1:17</span><span>{current.duration}</span></div><div className="big-controls"><button><Glyph>↝</Glyph></button><button><Glyph>‹</Glyph></button><button className="play-button play-button--large" onClick={onToggle}>{playing ? "Ⅱ" : "▶"}</button><button><Glyph>›</Glyph></button><button><Glyph>↻</Glyph></button></div></div>
        <aside className="up-next"><span className="eyebrow">UP NEXT</span><h2>{queue[0]?.title ?? tracks[1]!.title}</h2><p>{queue[0]?.artist ?? tracks[1]!.artist}</p></aside>
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

  return (
    <div className={`prototype is-${viewport}`} style={{ "--accent": palette.primary, "--accent-2": palette.secondary, "--deep": palette.deep, "--glow": palette.glow } as React.CSSProperties}>
      <div className="prototype__wash" />
      <Navigation screen={screen} onScreen={onScreen} />
      {screen === "discover" && <Discover current={current} onPlay={playTrack} onQueue={queueTrack} />}
      {screen === "album" && <AlbumScreen current={current} onPlay={playTrack} onQueue={queueTrack} />}
      {screen === "player" && <FullPlayer current={current} playing={playing} queue={queue} onToggle={() => setPlaying((value) => !value)} />}
      {screen !== "player" && <PlayerDock current={current} playing={playing} onToggle={() => setPlaying((value) => !value)} onExpand={() => onScreen("player")} />}
      {queue.length > 0 && <div className="queue-toast">{queue.length} queued</div>}
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
        <div className="lab-toolbar__title"><span>c</span><div><strong>Colorful Design Lab</strong><small>Disposable UI prototype</small></div></div>
        <div className="lab-control"><span>Canvas</span><div className="segmented"><button className={viewport === "desktop" ? "is-active" : ""} onClick={() => setViewport("desktop")}>Desktop</button><button className={viewport === "mobile" ? "is-active" : ""} onClick={() => setViewport("mobile")}>Mobile</button></div></div>
        <div className="lab-control"><span>Screen</span><div className="segmented">{(Object.keys(screenLabels) as Screen[]).map((value) => <button key={value} className={screen === value ? "is-active" : ""} onClick={() => setScreen(value)}>{screenLabels[value]}</button>)}</div></div>
        <div className="lab-control palette-control"><span>Album color</span><div>{palettes.map((value, index) => <button key={value.name} className={index === paletteIndex ? "is-active" : ""} style={{ background: value.primary }} onClick={() => setPaletteIndex(index)} aria-label={value.name} />)}</div></div>
      </header>
      <div className="lab-stage"><Prototype key={paletteIndex} viewport={viewport} screen={screen} paletteIndex={paletteIndex} onScreen={setScreen} /></div>
      <footer className="lab-note">Everything inside the canvas is fake and safe to throw away. Pick it apart.</footer>
    </div>
  );
}

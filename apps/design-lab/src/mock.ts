export type Palette = {
  name: string;
  primary: string;
  secondary: string;
  deep: string;
  glow: string;
};

export type Track = {
  id: string;
  title: string;
  artist: string;
  album: string;
  duration: string;
  palette: number;
};

export const palettes: Palette[] = [
  { name: "Tangerine", primary: "#ff713d", secondary: "#ffb45d", deep: "#381119", glow: "#ff477e" },
  { name: "Lagoon", primary: "#22d3c5", secondary: "#77f2cf", deep: "#092931", glow: "#3f8cff" },
  { name: "Violet", primary: "#9d72ff", secondary: "#f08cff", deep: "#24163e", glow: "#5f70ff" },
  { name: "Lemon", primary: "#eadb45", secondary: "#ffad4d", deep: "#29230b", glow: "#d5ff68" },
];

export const tracks: Track[] = [
  { id: "one", title: "Slow Motion Satellite", artist: "Mira Vale", album: "Afterglow", duration: "3:48", palette: 0 },
  { id: "two", title: "Glasshouse Weather", artist: "Soft Static", album: "Indoor Seasons", duration: "4:12", palette: 1 },
  { id: "three", title: "Everything Is Purple", artist: "Night Tennis", album: "Ultraviolet", duration: "2:57", palette: 2 },
  { id: "four", title: "Sunday on Mercury", artist: "Mira Vale", album: "Afterglow", duration: "3:21", palette: 0 },
  { id: "five", title: "Unreasonably Happy", artist: "Peel & Bloom", album: "Good Problems", duration: "3:05", palette: 3 },
  { id: "six", title: "Blue Hour Hotline", artist: "Soft Static", album: "Indoor Seasons", duration: "5:01", palette: 1 },
];


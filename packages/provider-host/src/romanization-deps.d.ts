declare module "kuroshiro" {
  type ConvertOptions = {
    to: "hiragana" | "katakana" | "romaji";
    mode?: "normal" | "spaced" | "okurigana" | "furigana";
    romajiSystem?: "nippon" | "passport" | "hepburn";
  };

  export default class Kuroshiro {
    static Util: {
      kanaToRomaji(value: string, system?: "nippon" | "passport" | "hepburn"): string;
    };
    init(analyzer: unknown): Promise<void>;
    convert(value: string, options: ConvertOptions): Promise<string>;
  }
}

declare module "kuroshiro-analyzer-kuromoji" {
  export default class KuromojiAnalyzer {
    constructor(options?: { dictPath?: string });
    parse(value: string): Promise<unknown[]>;
  }
}

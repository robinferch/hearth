// Hearth App Store slides.
// Open index.html for the gallery; index.html?slide=<id> renders a single slide at full size (used by export.sh).

// `?screens=` / `?covers=` override the asset folders (handy while iterating on layouts).
const params = new URLSearchParams(location.search);
const SCREENS = params.get("screens") ?? (params.get("lang") === "de" ? "assets/screens/de/" : "assets/screens/");
const COVERS = params.get("covers") ?? "assets/covers/";

// Native pixel widths of the captured screenshots.
const SHOT_WIDTH = { iphone: 1320, ipad: 2752, watch: 416 };

const icon = {
  flame: (size, fill = "#fff") => `<svg width="${size}" height="${size * 1.39}" viewBox="0 0 21.1133 29.3262" aria-hidden="true"><path fill="${fill}" d="M9.80469 27.0215C16.3672 27.0215 20.752 22.5781 20.752 15.8594C20.752 4.69727 11.25 0 4.53125 0C3.44727 0 2.7832 0.380859 2.7832 1.11328C2.7832 1.39648 2.91016 1.68945 3.16406 1.98242C4.66797 3.78906 6.18164 5.95703 6.20117 8.37891C6.20117 9.00391 6.10352 9.57031 5.66406 10.2539L6.25 10.1367C5.66406 8.32031 4.08203 7.06055 2.83203 7.06055C2.37305 7.06055 2.07031 7.39258 2.07031 7.88086C2.07031 8.21289 2.16797 8.98438 2.16797 9.54102C2.16797 12.5098 0 14.0723 0 18.5645C0 23.6523 3.88672 27.0215 9.80469 27.0215ZM10.0586 23.4766C7.76367 23.4766 6.25 22.0996 6.25 20.0293C6.25 17.8711 7.77344 17.0898 7.97852 15.7031C7.99805 15.5859 8.06641 15.5566 8.16406 15.625C8.73047 16.123 9.11133 16.748 9.42383 17.4609C10.0781 16.582 10.3906 14.7266 10.1562 12.6855C10.1367 12.5781 10.2148 12.5098 10.3223 12.5586C13.0078 13.8379 14.4141 16.4941 14.4141 18.8965C14.4141 21.3379 12.9883 23.4766 10.0586 23.4766Z"/></svg>`,
  moon: (size, fill = "currentColor") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path fill="${fill}" d="M20.2 15.4A8.6 8.6 0 0 1 8.6 3.8a.7.7 0 0 0-.9-.9A9.6 9.6 0 1 0 21.1 16.3a.7.7 0 0 0-.9-.9Z"/></svg>`,
  plus: (size, stroke = "#fff") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" stroke="${stroke}" stroke-width="2.6" stroke-linecap="round"/></svg>`,
  xmark: (size, stroke = "#fff") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11" stroke="${stroke}" stroke-width="2.6" stroke-linecap="round"/></svg>`,
  play: (size, fill = "#fff") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path fill="${fill}" d="M7 4.8v14.4c0 .8.9 1.3 1.6.9l11.3-7.2c.6-.4.6-1.3 0-1.7L8.6 3.9C7.9 3.5 7 4 7 4.8Z"/></svg>`,
  pause: (size, fill = "#fff") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><rect x="5.5" y="4" width="4.5" height="16" rx="1.4" fill="${fill}"/><rect x="14" y="4" width="4.5" height="16" rx="1.4" fill="${fill}"/></svg>`,
  airplane: (size, fill = "#fff") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path fill="${fill}" d="M21.2 15.6v-1.7l-7.7-4.8V4.1a1.5 1.5 0 0 0-3 0v5L2.8 13.9v1.7l7.7-2.4v5.3l-2.2 1.6v1.3l3.7-1 3.7 1v-1.3l-2.2-1.6v-5.3l7.7 2.4Z"/></svg>`,
  skipBack: (size, stroke = "#fff") => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3" fill="none" stroke="${stroke}" stroke-width="2.2" stroke-linecap="round"/><path d="M6.7 2.7v4.2h4.2" fill="none" stroke="${stroke}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><text x="12" y="15.2" font-size="7.4" font-family="-apple-system, system-ui" font-weight="700" fill="${stroke}" text-anchor="middle">15</text></svg>`,
};

// MARK: - Copy

const TEXT = {
  "en": {
    "slides": {
      "iphone-01-hero": [
        "Every book on your server, right in your pocket.",
        "A native audiobookshelf player for iPhone, iPad, Apple Watch and CarPlay."
      ],
      "iphone-02-player": [
        "Made for the long listen.",
        "Chapters, bookmarks and speed control, right under your thumb."
      ],
      "iphone-03-sleep": [
        "Fall asleep. Hearth stops at the end of the chapter.",
        "Gentle fade-out, shake to keep listening, and the timer on your Lock Screen."
      ],
      "iphone-04-library": [
        "Series, authors and narrators, all connected.",
        "Follow a series from the first book to the last, and see what's next."
      ],
      "iphone-05-podcasts": [
        "Your podcasts live here too.",
        "Seasons, filters and Up Next, in sync with your server."
      ],
      "iphone-06-offline": [
        "Download it. Lose signal. Keep listening.",
        "Progress and listening time sync back the moment you're online."
      ],
      "iphone-07-goals": [
        "See how much you listened.",
        "Set a daily goal, keep your streak, and check in from your Lock Screen."
      ],
      "iphone-08-everywhere": [
        "On your wrist, in the car, on your Home Screen.",
        "Apple Watch, CarPlay, widgets, Live Activities and Siri."
      ],
      "iphone-09-open": [
        "Open source. No tracking. Your server.",
        "Connect several servers and accounts, with a password or single sign-on."
      ],
      "ipad-01-hero": [
        "Your library, laid out on iPad.",
        "A sidebar for every server and library, and multiple windows when you need them."
      ],
      "ipad-02-player": [
        "Chapters and queue, side by side.",
        ""
      ],
      "ipad-03-library": [
        "Browse the way you think about books.",
        "Series, authors, narrators, collections and playlists."
      ]
    },
    "labels": {
      "sleepTimer": "Sleep timer",
      "today": "Today",
      "ofGoal": "of {goal} min",
      "minutes": "min",
      "siri": "“Resume Hearth”"
    }
  },
  "de": {
    "slides": {
      "iphone-01-hero": [
        "Jedes Buch deines Servers, immer in der Tasche.",
        "Ein nativer audiobookshelf-Player für iPhone, iPad, Apple Watch und CarPlay."
      ],
      "iphone-02-player": [
        "Gemacht für lange Hörstunden.",
        "Kapitel, Lesezeichen und Tempo, genau unter deinem Daumen."
      ],
      "iphone-03-sleep": [
        "Einschlafen. Hearth stoppt am Kapitelende.",
        "Sanftes Ausblenden, Schütteln zum Weiterhören und der Timer auf dem Sperrbildschirm."
      ],
      "iphone-04-library": [
        "Reihen, Autoren und Sprecher, alles verknüpft.",
        "Folge einer Reihe vom ersten bis zum letzten Band und sieh, was als Nächstes kommt."
      ],
      "iphone-05-podcasts": [
        "Auch deine Podcasts sind hier zu Hause.",
        "Staffeln, Filter und „Als Nächstes“, synchron mit deinem Server."
      ],
      "iphone-06-offline": [
        "Laden. Funkloch. Weiterhören.",
        "Fortschritt und Hörzeit landen wieder auf dem Server, sobald du online bist."
      ],
      "iphone-07-goals": [
        "Sieh, wie viel du gehört hast.",
        "Setz dir ein Tagesziel, halte deine Serie und behalte sie auf dem Sperrbildschirm im Blick."
      ],
      "iphone-08-everywhere": [
        "Am Handgelenk, im Auto, auf dem Home‑Bildschirm.",
        "Apple Watch, CarPlay, Widgets, Live‑Aktivitäten und Siri."
      ],
      "iphone-09-open": [
        "Open Source. Kein Tracking. Dein Server.",
        "Verbinde mehrere Server und Konten, per Passwort oder Single Sign-on."
      ],
      "ipad-01-hero": [
        "Deine Bibliothek, ausgebreitet auf dem iPad.",
        "Eine Seitenleiste für jeden Server und jede Bibliothek, und mehrere Fenster, wenn du sie brauchst."
      ],
      "ipad-02-player": [
        "Kapitel und Warteschlange, Seite an Seite.",
        ""
      ],
      "ipad-03-library": [
        "Stöbere so, wie du über Bücher denkst.",
        "Reihen, Autoren, Sprecher, Sammlungen und Playlists."
      ]
    },
    "labels": {
      "sleepTimer": "Schlaftimer",
      "today": "Heute",
      "ofGoal": "von {goal} Min.",
      "minutes": "Min.",
      "siri": "„Hearth fortsetzen“"
    }
  }
};

const LANG = TEXT[params.get("lang")] ? params.get("lang") : "en";
const L = TEXT[LANG].labels;
document.documentElement.lang = LANG;

// MARK: - Building blocks

const style = (props) => Object.entries(props)
  .filter(([, value]) => value !== undefined)
  .map(([key, value]) => `${key}:${typeof value === "number" ? `${value}px` : value}`)
  .join(";");

/** Absolutely positioned layer on the artboard. */
function layer(content, { left, top, right, bottom, rotate = 0, z = 1, extra = "" } = {}) {
  const css = style({ left, top, right, bottom, "z-index": `${z}`, transform: rotate ? `rotate(${rotate}deg)` : undefined });
  return `<div class="layer" style="${css};${extra}">${content}</div>`;
}

function phone(screen, width) {
  return `<div class="phone" style="--w:${width}px"><div class="bezel"><img class="screen" src="${SCREENS}${screen}" alt=""><div class="island"></div></div></div>`;
}

function tablet(screen, width) {
  return `<div class="tablet" style="--w:${width}px"><div class="bezel"><img class="screen" src="${SCREENS}${screen}" alt=""></div></div>`;
}

function watch(screen, width) {
  return `<div class="watch" style="--w:${width}px"><div class="case"><div class="glass"><img class="screen" src="${SCREENS}${screen}" alt=""></div></div><div class="crown"></div><div class="button"></div></div>`;
}

/**
 * A fragment of a screenshot. `x`, `y`, `w`, `h` are in screenshot pixels; `width` is the rendered width.
 */
function crop({ screen, device = "iphone", x, y, w, h, width, radius = 44 }) {
  const k = width / w;
  const css = style({
    width,
    height: h * k,
    "background-image": `url('${SCREENS}${screen}')`,
    "background-size": `${SHOT_WIDTH[device] * k}px auto`,
    "background-position": `${-x * k}px ${-y * k}px`,
    "--r": `${radius}px`,
  });
  return `<div class="crop" style="${css}"></div>`;
}

function cover(slug, size, radius = 28) {
  return `<img class="cover-tile" src="${COVERS}${slug}.jpg" alt="" style="width:${size}px;height:${size}px;border-radius:${radius}px">`;
}

function copyFor(id, width) {
  const [title, text] = TEXT[LANG].slides[id];
  const css = width ? ` style="width:${width}px"` : "";
  return `<div class="copy"${css}><h1>${title}</h1>${text ? `<p>${text}</p>` : ""}</div>`;
}

function gauge({ size, stroke, progress, track = "rgba(255,255,255,.14)", color = "#f28a2e", inner = "" }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return `<div class="gauge" style="width:${size}px;height:${size}px">
    <svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
      <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${track}" stroke-width="${stroke}"/>
      <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="${stroke}" stroke-linecap="round"
        stroke-dasharray="${c * progress} ${c}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
    </svg>
    <div class="value">${inner}</div>
  </div>`;
}

// MARK: - HTML mocks of system surfaces

const DEMO = {
  sleepBook: { title: "Moby-Dick", cover: "moby-dick" },
  listenedMinutes: 22,
  goalMinutes: 30,
  listenNow: [
    { title: "Pride and Prejudice", author: "Jane Austen", cover: "pride-and-prejudice", progress: 0.62 },
    { title: "Moby-Dick", author: "Herman Melville", cover: "moby-dick", progress: 0.35 },
  ],
};

function liveActivity() {
  const book = DEMO.sleepBook;
  return `<div class="live-activity">
    <img class="cover" src="${COVERS}${book.cover}.jpg" alt="">
    <div class="meta">
      <strong>${book.title}</strong>
      <span>${icon.moon(34, "#ffb560")} ${L.sleepTimer}</span>
    </div>
    <div class="countdown">14:52</div>
    <div class="round">${icon.plus(46)}</div>
  </div>`;
}

function listenedTodayWidget() {
  const progress = DEMO.listenedMinutes / DEMO.goalMinutes;
  return `<div class="widget small dark" style="display:flex;flex-direction:column;justify-content:space-between">
    <div style="display:flex;justify-content:space-between;align-items:center;font-size:34px;font-weight:600;color:#ffb560">
      <span>${L.today}</span>${icon.flame(30, "#f28a2e")}
    </div>
    <div style="display:flex;justify-content:center">
      ${gauge({ size: 260, stroke: 30, progress, inner: `<div style="font-size:80px;font-weight:700;letter-spacing:-.03em">${DEMO.listenedMinutes}</div><div style="font-size:28px;color:#a39caa">${L.ofGoal.replace("{goal}", DEMO.goalMinutes)}</div>` })}
    </div>
  </div>`;
}

function lockScreenGauge() {
  const progress = DEMO.listenedMinutes / DEMO.goalMinutes;
  return gauge({
    size: 230, stroke: 20, progress, color: "#fff", track: "rgba(255,255,255,.28)",
    inner: `<div style="font-size:64px;font-weight:700;color:#fff">${DEMO.listenedMinutes}</div><div style="font-size:24px;color:rgba(255,255,255,.75)">${L.minutes}</div>`,
  }).replace('class="gauge"', 'class="gauge" ' + 'style="width:230px;height:230px;border-radius:50%;background:rgba(255,255,255,.12);backdrop-filter:blur(30px);box-shadow:0 30px 70px rgba(6,3,10,.45)"');
}

function listenNowWidget() {
  const rows = DEMO.listenNow.map((item) => `
    <div style="display:flex;align-items:center;gap:30px">
      <img src="${COVERS}${item.cover}.jpg" alt="" style="width:150px;height:150px;border-radius:22px;object-fit:cover">
      <div style="flex:1;min-width:0">
        <div style="font-size:38px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${item.title}</div>
        <div style="font-size:30px;color:#7d7684;margin-top:4px">${item.author}</div>
        <div style="height:10px;border-radius:5px;background:#ebe5ee;margin-top:20px;overflow:hidden"><div style="width:${item.progress * 100}%;height:100%;background:#f28a2e"></div></div>
      </div>
      <div style="width:96px;height:96px;border-radius:50%;background:#f28a2e;display:grid;place-items:center">${icon.play(44)}</div>
    </div>`).join("");
  return `<div class="widget medium" style="display:flex;flex-direction:column;justify-content:space-between">${rows}</div>`;
}

function control(svg, on = false) {
  return `<div class="control${on ? " on" : ""}">${svg}</div>`;
}

function appIcon(size) {
  return `<div class="app-icon" style="--w:${size}px">${icon.flame(size * 0.48, "rgba(255,255,255,.92)")}</div>`;
}

// MARK: - Slides

const SLIDES = [
  {
    id: "iphone-01-hero",
    device: "iphone",
    glowX: "58%",
    body: () => [
      copyFor("iphone-01-hero"),
      layer(cover("pride-and-prejudice", 360), { left: 900, top: 900, rotate: 9, z: 1 }),
      layer(cover("moby-dick", 360), { left: 980, top: 1240, rotate: 3, z: 1 }),
      layer(phone("iphone-home.png", 960), { left: 230, top: 1000, rotate: -3, z: 2 }),
      layer(watch("watch-player.png", 470), { left: 40, top: 2080, rotate: -6, z: 3 }),
    ].join(""),
  },
  {
    id: "iphone-02-player",
    device: "iphone",
    glowX: "36%",
    body: () => [
      copyFor("iphone-02-player"),
      layer(phone("iphone-player.png", 960), { left: 60, top: 920, z: 2 }),
      layer(crop({ screen: "iphone-player-chapters.png", x: 40, y: 1120, w: 1240, h: 900, width: 700 }), { left: 620, top: 1640, rotate: 2.5, z: 3 }),
    ].join(""),
  },
  {
    id: "iphone-03-sleep",
    device: "iphone",
    glowX: "50%",
    body: () => [
      copyFor("iphone-03-sleep"),
      layer(phone("iphone-sleep-timer.png", 980), { left: 170, top: 1220, z: 2 }),
      layer(liveActivity(), { left: 100, top: 1000, z: 3 }),
    ].join(""),
  },
  {
    id: "iphone-04-library",
    device: "iphone",
    glowX: "45%",
    body: () => [
      copyFor("iphone-04-library"),
      layer(phone("iphone-series.png", 820), { left: 470, top: 880, z: 1, extra: "filter:brightness(.82)" }),
      layer(phone("iphone-audiobook.png", 900), { left: 50, top: 1180, z: 2 }),
    ].join(""),
  },
  {
    id: "iphone-05-podcasts",
    device: "iphone",
    glowX: "62%",
    body: () => [
      copyFor("iphone-05-podcasts"),
      layer(phone("iphone-podcast.png", 960), { left: 330, top: 920, z: 2 }),
      // Magnified over its own spot on the phone, so the duplicated rows stay hidden underneath.
      layer(crop({ screen: "iphone-podcast.png", x: 0, y: 1700, w: 1320, h: 590, width: 1060, radius: 40 }), { left: 280, top: 2081, rotate: -1.5, z: 3 }),
    ].join(""),
  },
  {
    id: "iphone-06-offline",
    device: "iphone",
    glowX: "50%",
    body: () => [
      copyFor("iphone-06-offline"),
      layer(phone("iphone-downloads.png", 960), { left: 180, top: 960, z: 2 }),
      layer(control(icon.airplane(110), true), { left: 990, top: 880, rotate: 6, z: 3 }),
    ].join(""),
  },
  {
    id: "iphone-07-goals",
    device: "iphone",
    glowX: "40%",
    body: () => [
      copyFor("iphone-07-goals"),
      layer(phone("iphone-statistics.png", 940), { left: 60, top: 980, z: 2 }),
      layer(listenedTodayWidget(), { left: 790, top: 1480, rotate: 3, z: 3 }),
      layer(lockScreenGauge(), { left: 950, top: 2050, z: 3 }),
    ].join(""),
  },
  {
    id: "iphone-08-everywhere",
    device: "iphone",
    glowX: "50%",
    body: () => [
      copyFor("iphone-08-everywhere"),
      layer(listenNowWidget(), { left: 160, top: 880, rotate: -2, z: 2 }),
      layer(watch("watch-player.png", 600), { left: 140, top: 1520, rotate: -4, z: 3 }),
      layer(control(icon.pause(100)), { left: 860, top: 1560, z: 2 }),
      layer(control(icon.moon(100, "#fff"), true), { left: 860, top: 1830, z: 2 }),
      layer(control(icon.skipBack(110)), { left: 860, top: 2100, z: 2 }),
      layer(`<div class="bubble">${L.siri}</div>`, { left: 380, top: 2520, rotate: -1.5, z: 4 }),
    ].join(""),
  },
  {
    id: "iphone-09-open",
    device: "iphone",
    glowX: "50%",
    body: () => [
      copyFor("iphone-09-open"),
      layer(phone("iphone-home-dark.png", 900), { left: 390, top: 1060, rotate: 4, z: 1 }),
      layer(appIcon(420), { left: 150, top: 1420, rotate: -6, z: 2 }),
    ].join(""),
  },
  {
    id: "ipad-01-hero",
    device: "ipad",
    glowX: "70%",
    body: () => [
      copyFor("ipad-01-hero"),
      layer(tablet("ipad-home.png", 1720), { left: 1100, top: 360, z: 2 }),
      layer(phone("iphone-player.png", 520), { left: 820, top: 1050, rotate: -4, z: 3 }),
    ].join(""),
  },
  {
    id: "ipad-02-player",
    device: "ipad",
    glowX: "50%",
    body: () => [
      copyFor("ipad-02-player", 2400),
      layer(tablet("ipad-player.png", 2060), { left: 346, top: 470, z: 2 }),
    ].join(""),
  },
  {
    id: "ipad-03-library",
    device: "ipad",
    glowX: "65%",
    body: () => [
      copyFor("ipad-03-library"),
      layer(tablet("ipad-library.png", 1700), { left: 1150, top: 260, rotate: 0, z: 1, extra: "filter:brightness(.85)" }),
      layer(tablet("ipad-audiobook.png", 1500), { left: 900, top: 900, z: 2 }),
    ].join(""),
  },
];

// MARK: - Rendering

function artboard(slide) {
  return `<div class="artboard ${slide.device}" style="--glow-x:${slide.glowX}" data-slide="${slide.id}">${slide.body()}</div>`;
}

const gallery = document.getElementById("gallery");
const requested = params.get("slide");

if (requested) {
  const slide = SLIDES.find((candidate) => candidate.id === requested);
  document.body.classList.add("export");
  gallery.innerHTML = slide ? artboard(slide) : `<p>Unknown slide ${requested}</p>`;
} else {
  const previewWidth = { iphone: 330, ipad: 690 };
  const languageLink = (code, name) => code === LANG
    ? `<strong>${name}</strong>`
    : `<a href="?${new URLSearchParams({ ...Object.fromEntries(params), lang: code })}">${name}</a>`;
  document.body.insertAdjacentHTML("afterbegin", `<nav class="languages">${languageLink("en", "English")} ${languageLink("de", "Deutsch")}</nav>`);
  gallery.innerHTML = SLIDES.map((slide) => {
    const [width, height] = slide.device === "iphone" ? [1320, 2868] : [2752, 2064];
    const scale = previewWidth[slide.device] / width;
    return `<figure class="preview">
      <a href="?${new URLSearchParams({ ...Object.fromEntries(params), slide: slide.id })}">
        <div class="frame-holder" style="width:${width * scale}px;height:${height * scale}px">
          <div class="artboard ${slide.device}" style="--glow-x:${slide.glowX};transform:scale(${scale})">${slide.body()}</div>
        </div>
      </a>
      <figcaption>${slide.id}.png, ${width} × ${height} px</figcaption>
    </figure>`;
  }).join("");
}

window.SLIDE_IDS = SLIDES.map((slide) => slide.id);

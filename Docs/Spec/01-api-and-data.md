# Hearth – API & data layer spec

Behavioural spec of the audiobookshelf (ABS) API surface and the client-side data model Hearth needs.
Derived from a feature analysis of an existing client; **no code was copied**. All Hearth code is written from scratch.

Client name sent to the server: `Hearth`. OAuth callback: `hearth://oauth`.

---

## 1. HTTP API surface

### 1.1 Shared client behaviour
- URL = stored host (trailing slash trimmed; host may contain a sub-path like `https://x.y/abs`) + path such as `api/libraries`, plus query items.
- Every request: connection custom headers (sorted by key) → `Authorization: Bearer <accessToken>` (if any) → per-request headers. JSON body → `Content-Type: application/json`.
- Default timeout 45 s. One `URLSession` per connection (ephemeral, no URL cache). Cookies shared via app-group cookie storage (required by OpenID).
- Do not follow redirects for `/auth/openid` (read `Location` header manually).
- Deduplicate identical in-flight GETs. Optional in-memory TTL cache (~12 s) for list endpoints.
- Concurrency limit ~6 requests per connection. Login/status/refresh/authorize bypass the limiter and the "unreachable" gate.
- Offline mode: requests fail with `.offline` unless explicitly allowed.
- 401 → refresh token once (single-flight per connection; skip if token already changed since request was sent) → retry. Tokens are refreshed proactively when the JWT `exp` is close (1 min for API calls, 15 min for download/stream/cover requests). Only idempotent requests (GET and explicitly marked calls) are retried on network errors / 5xx / 408 / 429, up to 3 attempts. Valid status range 200–299.
- Refresh failure → mark connection unavailable for this run, post "connection unauthorized" notification (UI offers re-login).

### 1.2 Authentication & server
| Method | Path | Request | Response fields | Purpose |
|---|---|---|---|---|
| GET | `status` (no auth) | – | `isInit`, `authMethods[]` (`local`, `openid`), `serverVersion`, (`authFormData.authOpenIDButtonText`, `authOpenIDAutoLaunch` optional) | Pre-login check. Fail if `isInit == false`. Warn if server < **2.26.0** (no refresh tokens). |
| POST | `login` | `{username, password}` + header `x-return-tokens: true` | `user.username`, `user.accessToken` (2.26+) else `user.token` (legacy), `user.refreshToken?` | Local login |
| POST | `auth/refresh` | header `x-refresh-token: <refreshToken>` | `user.accessToken`/`user.token`, `user.refreshToken` | Token refresh; new refresh token replaces old |
| POST | `api/authorize` | – | `user.mediaProgress[]`, `user.bookmarks[]`, `user.id`, `user.username` | Full sync of progress + bookmarks |
| GET | `api/me` | – | `id`, `username`, `type`, `isActive`, `isLocked`, `permissions` | User ID (needed for local session upload) |
| GET | `auth/openid` | query `client_id=Hearth`, `redirect_uri=hearth://oauth`, `code_challenge_method=S256`, `response_type=code`, `code_challenge=…` | `Location` header of 302 | IdP authorize URL |
| GET | `auth/openid/callback` | query `code`, `state`, `code_verifier` | same `user.*` token fields as login | Code → tokens |

**OpenID (PKCE):** verifier = 64–128 random alphanumerics; challenge = base64url(SHA256(verifier)) without padding. Clear cookies → `GET auth/openid` (custom headers, no bearer, no redirect follow) → open `Location` in `ASWebAuthenticationSession` (callback scheme `hearth`, ephemeral, custom headers as `additionalHeaderFields`) → callback has `code` + `state` → `GET auth/openid/callback` reusing cookie from step 1 → tokens.

No refresh token stored ⇒ "legacy auth" hint in UI.

### 1.3 Libraries & home
| Method | Path | Query | Read | Purpose |
|---|---|---|---|---|
| GET | `api/libraries` | – | `libraries[].id, name, mediaType ("book"/"podcast"), displayOrder, icon` | Library list; sort by `displayOrder`. **Ignore unknown media types (don't crash).** |
| GET | `api/libraries/{lib}` | `include=filterdata` | `filterdata.genres[]`, `filterdata.tags[]`, `filterdata.languages[]` | Filter values |
| GET | `api/libraries/{lib}/personalized` | – | array `{id, label, labelStringKey?, type, entities[]}` | Home shelves. Book libs: `type=="book"` rows, `"authors"` rows, `"series"` rows. Podcast libs: `"episode"` rows (entity is library item, `recentEpisode` = episode), `"podcast"` rows. Skip empty rows. |
| GET | `api/libraries/{lib}/recent-episodes` | `page`, `limit` | `episodes[]` (with nested `podcast`) | "Latest" tab in podcast libs |

### 1.4 Item lists – `GET api/libraries/{lib}/items`
Paging: `page` (0-based), `limit` → `{ total, results[] }`.
- Audiobooks: `sort=<field>`, `desc=0|1`, `collapseseries=0|1`, optional `filter`:
  - progress: `progress.` + base64(`in-progress` | `finished` | `not-started` | `not-finished`) — **URL-encode the base64 properly**
  - genre: `genres.` + base64(genre); tag: `tags.` + base64(tag)
  - author `authors.`+b64(authorId); series `series.`+b64(seriesId); narrator `narrators.`+b64(name)
- With `collapseseries=1` a result may have `collapsedSeries {id, name, numBooks, libraryItemIds[]}` → render as a series tile.
- Without `sort` + with series filter → server returns series order (drives "up next in series").
- Podcasts: `sort`, `desc`, `page`, `limit`, `include=numEpisodesIncomplete` → read `numEpisodes`, `numEpisodesIncomplete`.

### 1.5 Other entities
| Method | Path | Notes |
|---|---|---|
| GET | `api/items/{id}?expanded=1` | Full item incl. `libraryFiles[]`, `media.tracks[]`, `media.chapters[]`, `media.episodes[]`, `userMediaProgress` |
| GET | `api/podcasts/{podcastId}/episode/{episodeId}` | single episode |
| PATCH | `api/podcasts/{podcastId}/episode/{episodeId}` | `{episodeType}` |
| GET | `api/authors/{id}?include=items,series` | `id, libraryId, name, description, addedAt, numBooks, libraryItems[], series[]` |
| GET | `api/libraries/{lib}/authors` | `sort`, `desc`, `limit`, `page` → `{total?, results[]}` or `{authors[]}` (older servers) |
| GET | `api/libraries/{lib}/narrators` | `narrators[] {id, name, numBooks}`; sort client-side |
| GET | `api/libraries/{lib}/series/{id}` | `id, name, description, addedAt, books[]` (older servers: use items filter) |
| GET | `api/libraries/{lib}/series` | `sort`, `desc`, `filter`, `page`, `limit` → `{total, results[] with books[]}` |
| GET | `api/libraries/{lib}/search?q=&limit=` | `book[].libraryItem`, `podcast[].libraryItem`, `episodes[].libraryItem.recentEpisode`?, `authors[]`, `narrators[]`, `series[] {series, books[]}`, `tags[]`, `genres[]` |

**Collections / playlists**
| Method | Path | Body |
|---|---|---|
| GET | `api/libraries/{lib}/collections` / `…/playlists` | `page`, `limit` → `{total, results[]}` |
| GET | `api/collections/{id}` / `api/playlists/{id}` | collections: `books[]`; playlists: `items[] {libraryItemId, episodeId?, libraryItem, episode?}` |
| POST | `api/collections` | `{name, libraryId, books:[libraryItemId]}` |
| POST | `api/playlists` | `{name, libraryId, items:[{libraryItemId, episodeId?}]}` |
| PATCH | `api/collections/{id}` | `{name?, description?, books?:[…]}` (reorder = replace) |
| PATCH | `api/playlists/{id}` | `{name?, description?, items?:[…]}` |
| POST | `api/collections/{id}/batch/add` / `batch/remove` | `{books:[…]}` |
| POST | `api/playlists/{id}/batch/add` / `batch/remove` | `{items:[…]}` |
| DELETE | `api/collections/{id}` / `api/playlists/{id}` | – |
| POST | `api/playlists/collection/{collectionId}` | create playlist from collection |

### 1.6 Media files
- Cover: `GET api/items/{libraryItemId}/cover?width=N` (episodes use podcast item id). Author image: `GET api/authors/{id}/image?width=N`. Sizes: tiny 220, small 320, regular 600, large 1000 (×2 on iPad / "high quality" setting). Send bearer header.
- Audio file download: `GET api/items/{libraryItemId}/file/{ino}/download` (fallback `…/file/{ino}`).
- Ebook/PDF: `GET api/items/{libraryItemId}/ebook/{ino}`. Supplementary PDFs = `libraryFiles[]` with `metadata.ext == ".pdf"` (and `isSupplementary != false`). Display name = filename w/o extension.
- Streaming: `audioTracks[].contentUrl` from play session, resolved against host; append bearer as header via `AVURLAsset` `AVURLAssetHTTPHeaderFieldsKey` (+ custom headers). Fallback: `?token=` query.
- Web URLs for sharing: `{host}/item/{id}`, `{host}/author/{id}`, `{host}/library/{lib}/series/{id}`.

### 1.7 Playback sessions
- Start: `POST api/items/{itemId}/play` or `POST api/items/{podcastId}/play/{episodeId}` with
  `{deviceInfo:{deviceId, clientName:"Hearth", clientVersion, manufacturer:"Apple", model}, supportedMimeTypes:["audio/flac","audio/mpeg","audio/mp4","audio/aac","audio/x-aiff","audio/x-m4a","audio/x-m4b"], mediaPlayer:"AVPlayer", forceDirectPlay:true}`.
  Read: `id`, `startTime`/`currentTime`, `audioTracks[] {index, startOffset, duration, contentUrl, mimeType, metadata.ext}`, `chapters[] {id,start,end,title}`, `displayTitle`, `displayAuthor`, `duration`.
  deviceId = persistent random string in shared defaults.
- Sync: `POST api/session/{id}/sync` `{duration, currentTime, timeListened}` — on start, play/pause, every ≤ 30 s while playing (`timeListened` = wall-clock since last report).
- Close: `POST api/session/{id}/close` `{duration, currentTime, timeListened}`.
- Track open session ids; on next launch close stale ones (bugfix vs. reference).
- Offline: `POST api/session/local` with full session object (`id` UUID, `userId`, `libraryId`, `libraryItemId`, `episodeId`, `mediaType`, `mediaMetadata`, `chapters`, `displayTitle`, `displayAuthor`, `coverPath`, `duration`, `playMethod: 3`, `mediaPlayer`, `deviceInfo{…, osName:"iOS"/"watchOS"}`, `date` yyyy-MM-dd, `dayOfWeek`, `timeListening`, `startTime`, `currentTime`, `startedAt`, `updatedAt` ms). Also `POST api/session/local-all` exists for batches.
- When no server session possible: resume from local progress; smart rewind (if last update ≥ 10 min ago: −30 s); finished → start at 0; report into local session record.
- History: `GET api/me/listening-sessions?page=&itemsPerPage=`, `GET api/me/item/listening-sessions/{itemId}[/{episodeId}]`; `GET api/me/listening-stats` (totals per day/item, for statistics screen).

### 1.8 Progress
| Method | Path | Body |
|---|---|---|
| PATCH | `api/me/progress/{itemId}[/{episodeId}]` | `{isFinished?, currentTime?, progress?, duration?, hideFromContinueListening?}` |
| PATCH | `api/me/progress/batch/update` | `[{libraryItemId, episodeId?, duration, progress, currentTime, isFinished, hideFromContinueListening, lastUpdate, startedAt, finishedAt}]` (ms; null → omit) |
| DELETE | `api/me/progress/{progressId}` | reset |
| GET | `api/me/progress/{progressId}/remove-from-continue-listening` | hide from continue listening (**implement**) |

### 1.9 Bookmarks (audiobooks)
`POST api/me/item/{itemId}/bookmark {title, time}` → `{libraryItemId, title, time, createdAt}`; `PATCH` same path `{title, time}`; `DELETE api/me/item/{itemId}/bookmark/{time}`. Identity = (item, whole-second time).

---

## 2. Domain model

### 2.1 Item identifier
Stable string id `TYPE::CONNECTION::LIBRARY::PRIMARY[::GROUPING]`. Primary = server id (episode id for episodes); grouping = podcast item id for episodes. Types: audiobook, author, narrator, series, podcast, episode, collection, playlist. Playable: audiobook, episode. API item id = grouping ?? primary. Equality ignores type. Must be `Codable`, `Hashable`, `Sendable`, transferable as string (App Intents, widgets, URLs, Handoff).

Connection id = stable hash of host + username (SHA256, url-safe base64).

### 2.2 Items
- Base: id, name, authors[], description (HTML → plain/attributed), genres[], tags[], addedAt, released.
- Playable: size, duration, audio files (ino, ext, offset, duration), supplementary PDFs.
- Audiobook: subtitle, narrators[], series[] `{id?, name, sequence?}`, explicit, abridged, publisher, language, isbn/asin.
- Episode: podcastName, type (full/trailer/bonus), season/episode index, publishedAt, chapters parsed from description timestamps (`(HH:)MM:SS Title` at line start) when server has none.
- Podcast: explicit, episodeCount, incompleteEpisodeCount, publishingType (episodic/serial), feedURL.
- Person (author/narrator): bookCount, description, image (author only).
- Series: audiobooks[]. Collection/Playlist: items[].
- Chapter `{id, start, end, title}`. Bookmark `{itemID, time(s), note, created}`. HomeRow `{id, label, entities}`.

### 2.3 Parsing notes
- Skip book items with zero audio files (ebook-only), or show as non-playable.
- `media.metadata.series` may be an array or a single object; also parse `seriesName` "Name #1, Other #2".
- Authors from `metadata.authors[]` objects when present (ids!), else split `authorName` by ", ".
- Episode `publishedAt` is epoch ms.

---

## 3. Connections & credentials
- Connection record `{id, host, username, userID, headers[{key,value}], addedAt, serverVersion}` in Keychain (shared access group). Tokens in separate Keychain items (not iCloud-synced), accessibility after-first-unlock.
- Known/previously used servers offered as quick-fill.
- Add flow: URL → optional custom headers → `status` → show methods → login/OIDC → store → reload.
- Custom headers apply to API, downloads, AVPlayer assets, OIDC web session, socket handshake.
- **Self-signed certs:** per-connection "trust this certificate" (pin SHA-256 of leaf cert after user confirmation). **Client certs (mTLS):** import .p12, present on challenge.
- Multiple connections: each with own client; libraries merged & grouped by connection.

---

## 4. Persistence (SwiftData, app group container)
Entities: cached/downloaded items (audiobook, podcast, episode), download assets (item, kind audio/pdf/cover, downloaded flag, task id, weight), chapters, bookmarks (status synced/pendingCreate/pendingUpdate/deleted), progress (connection, primary, grouping, progress, duration, currentTime, startedAt, lastUpdate, finishedAt, hideFromContinueListening, status synced/dirty/tombstone), local listening sessions, key-value settings (per-item playback rate / sleep timer / up-next strategy / episode filter & sort / auto-download rules / dominant cover color), known servers.

### 4.3 Progress sync
On launch / foreground / connectivity regained: `POST api/authorize` → reconcile:
| Case | Action |
|---|---|
| local only & dirty | push |
| local only & synced | delete locally |
| remote only | insert locally |
| both, local tombstone | DELETE remote |
| both, remote lastUpdate missing or older than local | push local |
| both, equal currentTime | nothing |
| otherwise | remote wins |
Server duplicates: keep newest, DELETE others. Push = one batch update, then deletes. **Mark records dirty on every local update; keep tombstones when delete fails** (bugfixes).
Live: also apply Socket.IO `user_item_progress_updated` events.

### 4.4 Bookmark sync – analogous with statuses (deleted→DELETE, pendingUpdate→PATCH, pendingCreate→POST; server-only → insert).

### 4.5 Listening time & daily goal
Local sessions recorded when no server session/sync fails; uploaded via `session/local` on launch. Today total = server sessions since midnight (`listening-sessions` paging) + unsynced local + current unreported. Daily goal setting default 30 min; resets at midnight.

### 4.6 Downloads
Fetch `items/{id}?expanded=1`; assets: covers (4 sizes), PDFs, audio tracks; weight 10/10/80. Background `URLSession` (`<bundle>.downloads`), 4 concurrent, cellular only if allowed. Files under `Downloads/<connection>/<library>/<primary>/…`, excluded from backup. 401 → refresh + restart (not counted); 400/403/404/410 → give up; other errors → exponential backoff, max 3 counted failures, then remove. Item playing → locked. Podcast without episodes left → removed.
Auto-download rules per series/podcast/collection: `all`, `next n unfinished`, `released within h hours`; "keep Listen Now downloaded"; delete-when-finished option; BGAppRefresh every ≥3 h.

### 4.7 Listen Now / Up Next
Listen Now = in-progress items across all connections, newest first (offline: downloaded only). Up Next strategy per item: series → next unfinished in series order; podcast → next per saved episode filter/sort; collection/playlist → next unfinished; or disabled.

### 4.8 Offline mode – global toggle + automatic when network unreachable; per-connection unavailable flags.

## 5. WebSocket (Socket.IO v4 over WebSocket, implement minimal client ourselves with URLSessionWebSocketTask)
Path `/socket.io/?EIO=4&transport=websocket`, emit `auth` with access token after connect. Handle `user_item_progress_updated` (`{id, data: mediaProgress}`), `item_updated`, `item_added`, `item_removed`, `user_updated`. Only in foreground and online.

## 6. Sorting & filtering
**Books:** sort title `media.metadata.title`, author `media.metadata.authorName` / `authorNameLF`, published `media.metadata.publishedYear`, added `addedAt`, duration `media.duration`, size `size`, last-read `progress` (default added desc). Filters: progress, genre, tag, downloaded (local). Collapse series default on. Grid/list (default grid).
**Series:** `name`, `numBooks`, `addedAt`, `totalDuration` (default name asc). **Authors:** `name`, `lastFirst`, `numBooks`, `addedAt`. **Narrators:** client sort name/count.
**Podcasts:** `media.metadata.title`, `media.metadata.author`, `media.numTracks`, `addedAt`.
**Episodes:** client-side sort (name, index, release date, duration; default release desc for episodic, index asc for serial), filters (all/in progress/finished/not finished(default)), season, downloaded only, text search; persisted per podcast.
**Tabs:** books default Home + Library (+ optional Series, Authors, Narrators, Bookmarks, Collections, Playlists, Downloaded); podcasts Home, Latest, Library (+ Playlists, Downloaded). User-customisable.
**Global search:** local downloads index + server `search` over all libraries/connections, ranked by similarity.

#!/usr/bin/env python3
"""Seeds a local audiobookshelf server with the demo library used for the App Store screenshots.

  python3 generate_audio.py <books dir> <podcasts dir>   # once: silent audio with chapters
  python3 covers.py                                     # once: renders ../covers/*.jpg
  python3 seed.py [--server http://localhost:13380] [--user root] [--password hearth] [--state-only]

Without --state-only the script removes every item of the two libraries that is not part of the demo catalog,
waits for the scan, then writes metadata, covers, the "Favourites" collection and a playlist. It always (re)writes the
listening state of the user: progress, bookmarks and 14 days of listening sessions.
"""
import argparse
import datetime as dt
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from catalog import BOOKS, PODCASTS  # noqa: E402
from generate_audio import typographic  # noqa: E402

COVERS = os.path.join(HERE, "..", "covers")


class API:
    def __init__(self, server, user, password):
        self.server = server.rstrip("/")
        body = self.request("POST", "/login", {"username": user, "password": password}, auth=False)
        self.token = body["user"].get("accessToken") or body["user"]["token"]
        self.user = body["user"]

    def request(self, method, path, body=None, auth=True):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.server + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if auth:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path}: {error.code} {error.read()[:300]!r}") from None
        try:
            return json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return raw.decode()

    def upload_cover(self, item_id, path):
        subprocess.run(["curl", "-sf", "-X", "POST", "-H", f"Authorization: Bearer {self.token}", "-F", f"cover=@{path}",
                        f"{self.server}/api/items/{item_id}/cover"], check=True, capture_output=True)


def libraries(api):
    libs = api.request("GET", "/api/libraries")["libraries"]
    return next(l for l in libs if l["mediaType"] == "book"), next(l for l in libs if l["mediaType"] == "podcast")


def items(api, library):
    return api.request("GET", f"/api/libraries/{library['id']}/items?limit=500")["results"]


def wait_for(api, library, rel_paths, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = {i["relPath"]: i for i in items(api, library)}
        if all(p in found for p in rel_paths):
            return found
        time.sleep(2)
    raise RuntimeError(f"Scan of {library['name']} did not pick up {set(rel_paths) - set(found)}")


def replace_content(api, book_lib, podcast_lib, staging):
    book_paths = {f"{b['author']}/{b['title']}" for b in BOOKS}
    podcast_paths = {p["title"] for p in PODCASTS}
    for library, keep in ((book_lib, book_paths), (podcast_lib, podcast_paths)):
        for item in items(api, library):
            if item["relPath"] not in keep:
                print("deleting", item["relPath"])
                api.request("DELETE", f"/api/items/{item['id']}?hard=1")
        if staging:
            source = os.path.join(staging, "audiobooks" if library is book_lib else "podcasts")
            target = library["folders"][0]["fullPath"]
            subprocess.run(["rsync", "-a", "--ignore-existing", source + "/", target + "/"], check=True)
        api.request("POST", f"/api/libraries/{library['id']}/scan")
    return wait_for(api, book_lib, book_paths), wait_for(api, podcast_lib, podcast_paths)


def write_books(api, found):
    ids = {}
    for book in BOOKS:
        item = found[f"{book['author']}/{book['title']}"]
        ids[book["slug"]] = item["id"]
        metadata = {
            "title": book["title"], "subtitle": book.get("subtitle"), "authors": [{"name": book["author"]}],
            "narrators": [book["narrator"]], "genres": book["genres"], "publishedYear": book["year"],
            "publisher": book["publisher"], "description": typographic(book["description"]), "language": "English",
            "series": [{"name": book["series"], "sequence": book["sequence"]}] if book.get("series") else [],
            "explicit": False, "abridged": False,
        }
        api.request("PATCH", f"/api/items/{item['id']}/media", {"metadata": metadata, "tags": ["Classics"]})
        api.upload_cover(item["id"], os.path.join(COVERS, f"{book['slug']}.jpg"))
        print("book", book["title"])
    return ids


def write_podcasts(api, found):
    episode_ids = {}
    base = dt.datetime(2026, 10, 7, 6, 0)
    for podcast in PODCASTS:
        item = found[podcast["title"]]
        api.request("PATCH", f"/api/items/{item['id']}/media", {"metadata": {
            "title": podcast["title"], "author": podcast["author"], "description": podcast["description"],
            "genres": podcast["genres"], "language": podcast["language"], "explicit": False, "type": "episodic"}})
        api.upload_cover(item["id"], os.path.join(COVERS, f"{podcast['slug']}.jpg"))
        full = api.request("GET", f"/api/items/{item['id']}?expanded=1")
        by_index = {int(e["audioFile"]["metadata"]["filename"][:2]): e for e in full["media"]["episodes"]}
        count = len(podcast["episodes"])
        for index, (season, number, title, _, topics) in enumerate(podcast["episodes"], start=1):
            episode = by_index[index]
            published = base - dt.timedelta(days=7 * (count - index)) + dt.timedelta(days=len(podcast["slug"]) % 3)
            lede = podcast_lede(podcast, title)
            description = f"<p>{lede}</p><p>" + "<br>".join(topics) + "</p>"
            api.request("PATCH", f"/api/podcasts/{item['id']}/episode/{episode['id']}", {
                "title": title, "season": str(season), "episode": str(number), "episodeType": "full",
                "subtitle": lede, "description": description,
                "pubDate": published.strftime("%a, %d %b %Y %H:%M:%S +0000"),
                "publishedAt": int(published.replace(tzinfo=dt.timezone.utc).timestamp() * 1000)})
            episode_ids[(podcast["slug"], index)] = episode["id"]
        print("podcast", podcast["title"])
    return episode_ids


LEDES = {
    "Why We Still Read Jane Austen": "Two hundred years on, Austen still sells out. Clara makes the case for Elizabeth Bennet as the original rom-com heroine; Tom confesses he only read it for an exam - and loved it anyway.",
    "Frankenstein at 200: The First Science Fiction": "A ghost-story contest, a rainy summer and an eighteen-year-old writer. We follow Mary Shelley's creature from the Villa Diodati to every lab-coat thriller since.",
    "Moby-Dick Is Funnier Than You Think": "Yes, there is a whole chapter about the colour white. But there are also jokes, a tattooed best friend and some of the most gorgeous sentences in English. This week: why Melville is worth the voyage.",
    "The Brontë Sisters: Moors, Madness and Genius": "Three sisters in a parsonage on the edge of the moors wrote some of the wildest novels of the century. We compare Jane Eyre and Wuthering Heights - and pick sides.",
    "Sherlock Holmes and the Art of Deduction": "Season two opens at 221B Baker Street. We look at how Conan Doyle built the world's most famous detective, and why Dr. Watson deserves far more credit.",
    "Dracula: An Epistolary Nightmare": "Diaries, letters, telegrams and phonograph cylinders: Bram Stoker tells his vampire story through documents. Perfect listening for October nights.",
    "Great Expectations and the Dickens Machine": "Dickens published in weekly instalments and wrote two endings. We talk cliffhangers, Miss Havisham's stopped clocks and the ending we prefer.",
    "Little Women, Big Ideas": "Four sisters, one attic and a writer named Jo. We revisit Alcott's classic and the question every reader argues about: Laurie or Professor Bhaer?",
    "The Great Stink of 1858": "One hot summer, the Thames smelled so bad that Parliament fled its chambers. The engineering marvel that followed still keeps London running.",
    "Whaling Ships of Nantucket": "A tiny island off Massachusetts once lit the lamps of the world. Life aboard a whaler, the wreck of the Essex, and the book it inspired.",
    "The Year Without a Summer": "In 1815 a volcano erupted in Indonesia. A year later it snowed in June in New England - and on the shores of Lake Geneva, Mary Shelley began Frankenstein.",
    "Lighthouses and Their Keepers": "A lens that bends light like magic, keepers who lived on rocks, and a young woman who rowed into a storm. A quiet episode about guiding lights.",
    "Victorian Railway Mania": "Within a few decades, Britain was criss-crossed by iron. Speculation, collapse, and how trains gave the whole country the same time.",
    "The Telegraph: The Victorian Internet": "Messages that once took weeks suddenly took minutes. How cables under the Atlantic changed news, business and love letters.",
    "Arctic Expeditions and the Lost Franklin Voyage": "In 1845 two ships sailed north to find the Northwest Passage and never came back. A slow, chilling story of ice, searchers and a discovery 170 years later.",
}


def podcast_lede(podcast, title):
    return typographic(LEDES[title])


def write_collections(api, book_lib, ids):
    picks = [ids[s] for s in ("pride-and-prejudice", "the-hound-of-the-baskervilles", "jane-eyre", "moby-dick",
                              "frankenstein", "the-time-machine", "little-women")]
    collections = api.request("GET", "/api/collections")["collections"]
    favourites = next((c for c in collections if c["name"] == "Favourites"), None)
    if favourites is None:
        favourites = api.request("POST", "/api/collections", {"libraryId": book_lib["id"], "name": "Favourites", "books": []})
    api.request("PATCH", f"/api/collections/{favourites['id']}", {"description": "The books I keep coming back to."})
    current = [b["id"] for b in api.request("GET", f"/api/collections/{favourites['id']}")["books"]]
    if current:
        api.request("POST", f"/api/collections/{favourites['id']}/batch/remove", {"books": current})
    api.request("POST", f"/api/collections/{favourites['id']}/batch/add", {"books": picks})
    for playlist in api.request("GET", "/api/playlists")["playlists"]:
        api.request("DELETE", f"/api/playlists/{playlist['id']}")
    gothic = [ids[s] for s in ("dracula", "frankenstein", "wuthering-heights", "jane-eyre", "the-hound-of-the-baskervilles")]
    api.request("POST", "/api/playlists", {"libraryId": book_lib["id"], "name": "Gothic October",
                                            "description": "Candles, storms and something in the attic.",
                                            "items": [{"libraryItemId": i} for i in gothic]})


def chapter_time(api, item_id, fraction):
    item = api.request("GET", f"/api/items/{item_id}?expanded=1")
    return item["media"]["duration"] * fraction, item["media"]["duration"]


def write_state(api, ids, episode_ids, book_lib, podcast_lib):
    me = api.request("GET", "/api/me")
    for progress in me.get("mediaProgress", []):
        api.request("DELETE", f"/api/me/progress/{progress['id']}")
    for bookmark in me.get("bookmarks", []):
        api.request("DELETE", f"/api/me/item/{bookmark['libraryItemId']}/bookmark/{int(bookmark['time'])}")
    sessions = api.request("GET", "/api/me/listening-sessions?itemsPerPage=1000")["sessions"]
    for session in sessions:
        api.request("DELETE", f"/api/sessions/{session['id']}")

    podcasts = {i["media"]["metadata"]["title"]: i for i in items(api, podcast_lib)}
    reading_room = podcasts["The Reading Room"]["id"]
    moby_episode = episode_ids[("the-reading-room", 3)]

    # Sessions over the last 14 days (minutes per day, today last); one gap 10 days ago so the streak reads 10 days.
    minutes = [45, 62, 38, 0, 71, 55, 24, 83, 47, 66, 52, 35, 58, 21]  # the screenshot run adds a few minutes today
    plan = {  # (slug or episode, final fraction) consumed in order over the days
        "a-study-in-scarlet": 1.0, "the-hound-of-the-baskervilles": 0.62, "jane-eyre": 0.12, "moby-dick": 0.35}
    positions = {"a-study-in-scarlet": 0.02, "the-hound-of-the-baskervilles": 0.05, "jane-eyre": 0.0, "moby-dick": 0.08}
    schedule = ["a-study-in-scarlet"] * 4 + ["the-hound-of-the-baskervilles"] * 4 + ["jane-eyre", "moby-dick", "the-hound-of-the-baskervilles", "moby-dick", "moby-dick", "moby-dick"]
    durations = {slug: chapter_time(api, ids[slug], 0)[1] for slug in plan}
    rng = random.Random(7)
    today = dt.datetime.now().replace(second=0, microsecond=0)
    for offset, (total, slug) in enumerate(zip(minutes, schedule)):
        if total == 0:
            continue
        day = today - dt.timedelta(days=len(minutes) - 1 - offset)
        parts = [total] if total < 50 else [round(total * 0.6), total - round(total * 0.6)]
        hours = (7, 18) if offset % 3 else (13, 21)
        for part_index, part in enumerate(parts):
            if offset == len(minutes) - 1:
                started = today - dt.timedelta(minutes=part + 70)  # today: finished about an hour ago
            else:
                started = day.replace(hour=hours[part_index], minute=rng.randint(0, 50))
            is_episode = offset in (8, 12) and part_index == 1
            if is_episode:
                item_id, episode_id, duration, media = reading_room, moby_episode, 62 * 60, "podcast"
                start = 0 if offset == 8 else 13 * 60
                title, author = "Moby-Dick Is Funnier Than You Think", "Clara Whitfield & Tom Adeyemi"
            else:
                item_id, episode_id, duration, media = ids[slug], None, durations[slug], "book"
                start = positions[slug] * duration
                book = next(b for b in BOOKS if b["slug"] == slug)
                title, author = book["title"], book["author"]
            seconds = part * 60
            current = min(start + seconds * 1.15, duration - 5)
            if not is_episode:
                positions[slug] = current / duration
            session = {
                "id": str(uuid.uuid4()), "libraryItemId": item_id, "episodeId": episode_id, "mediaType": media,
                "displayTitle": title, "displayAuthor": author, "duration": duration, "playMethod": 3,
                "mediaPlayer": "AVPlayer", "date": started.strftime("%Y-%m-%d"), "dayOfWeek": started.strftime("%A"),
                "timeListening": seconds, "startTime": start, "currentTime": current,
                "startedAt": int(started.timestamp() * 1000),
                "updatedAt": int((started + dt.timedelta(seconds=seconds * 1.15)).timestamp() * 1000),
                "deviceInfo": {"clientName": "Hearth", "clientVersion": "1.0", "deviceName": "iPhone", "manufacturer": "Apple", "model": "iPhone"},
            }
            api.request("POST", "/api/session/local", session)
    print("sessions written")

    # Final progress, oldest update first (Continue Listening is ordered by last update).
    def set_progress(item_id, fraction, duration, episode_id=None, finished=False):
        path = f"/api/me/progress/{item_id}" + (f"/{episode_id}" if episode_id else "")
        body = {"currentTime": round(duration * fraction, 1), "duration": duration, "progress": fraction}
        if finished:  # ABS ignores `progress` whenever `isFinished` is present
            body["isFinished"] = True
        api.request("PATCH", path, body)
        time.sleep(1.1)

    set_progress(ids["a-study-in-scarlet"], 1.0, durations["a-study-in-scarlet"], finished=True)
    set_progress(ids["jane-eyre"], 0.12, durations["jane-eyre"])
    set_progress(reading_room, 0.5, 62 * 60 + 20, moby_episode)
    set_progress(ids["the-hound-of-the-baskervilles"], 0.62, durations["the-hound-of-the-baskervilles"])
    set_progress(ids["moby-dick"], 0.35, durations["moby-dick"])

    bookmarks = [
        ("moby-dick", 31, "\"Call me Ishmael.\" The opening line"),
        ("moby-dick", 3 * 3600 + 1210, "Father Mapple's sermon — the Jonah story"),
        ("moby-dick", 4 * 3600 + 2260, "Ishmael and Queequeg become friends"),
        ("the-hound-of-the-baskervilles", 512, "Holmes reads Dr. Mortimer's walking stick"),
        ("the-hound-of-the-baskervilles", 2 * 3600 + 1475, "The footprints of a gigantic hound!"),
        ("jane-eyre", 1180, "\"I am no bird; and no net ensnares me\" — find this later"),
    ]
    for slug, seconds, title in bookmarks:
        api.request("POST", f"/api/me/item/{ids[slug]}/bookmark", {"time": seconds, "title": title})
    print("progress and bookmarks written")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://localhost:13380")
    parser.add_argument("--user", default="root")
    parser.add_argument("--password", default="hearth")
    parser.add_argument("--state-only", action="store_true")
    parser.add_argument("--staging", help="folder with audiobooks/ and podcasts/ from generate_audio.py to copy in")
    args = parser.parse_args()
    api = API(args.server, args.user, args.password)
    book_lib, podcast_lib = libraries(api)
    if args.state_only:
        found_books = {i["relPath"]: i for i in items(api, book_lib)}
        found_podcasts = {i["relPath"]: i for i in items(api, podcast_lib)}
        ids = {b["slug"]: found_books[f"{b['author']}/{b['title']}"]["id"] for b in BOOKS}
        episode_ids = {}
        for podcast in PODCASTS:
            full = api.request("GET", f"/api/items/{found_podcasts[podcast['title']]['id']}?expanded=1")
            for e in full["media"]["episodes"]:
                episode_ids[(podcast["slug"], int(e["audioFile"]["metadata"]["filename"][:2]))] = e["id"]
    else:
        found_books, found_podcasts = replace_content(api, book_lib, podcast_lib, args.staging)
        ids = write_books(api, found_books)
        episode_ids = write_podcasts(api, found_podcasts)
        write_collections(api, book_lib, ids)
    write_state(api, ids, episode_ids, book_lib, podcast_lib)
    json.dump({"books": ids, "episodes": {f"{k[0]}#{k[1]}": v for k, v in episode_ids.items()}},
              open("/tmp/hearth-demo-ids.json", "w"), indent=1)


if __name__ == "__main__":
    main()

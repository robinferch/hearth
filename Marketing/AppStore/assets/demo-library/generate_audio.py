#!/usr/bin/env python3
"""Generates silent, tiny audio files with realistic durations and embedded chapters for the demo library.

Usage: generate_audio.py <audiobooks dir> <podcasts dir>
Books become `<Author>/<Title>/<Title>.m4b` (AAC mono, silence ~0.25 MB/h) with chapter markers;
podcast episodes become `<Podcast>/<NN - Title>.mp3` (8 kbps mono) with ID3 tags.
"""
import os
import random
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from catalog import BOOKS, PODCASTS  # noqa: E402


def typographic(text):
    return text.replace(" - ", " — ")


def chapter_lengths(book):
    rng = random.Random(book["slug"])
    titles = book["chapters"]
    fixed = {i: (40 if t == "Opening Credits" else 55) for i, t in enumerate(titles) if t.endswith("Credits")}
    rest = book["duration"] - sum(fixed.values())
    weights = {i: rng.uniform(0.65, 1.35) for i in range(len(titles)) if i not in fixed}
    total = sum(weights.values())
    lengths = [fixed.get(i) or int(rest * weights[i] / total) for i in range(len(titles))]
    lengths[-1 if (len(titles) - 1) not in fixed else -2] += book["duration"] - sum(lengths)
    return lengths


def escape(value):
    return "".join("\\" + c if c in "=;#\\\n" else c for c in value)


def run(args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def make_book(root, book):
    folder = os.path.join(root, book["author"], book["title"])
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{book['title']}.m4b")
    if os.path.exists(path):
        return
    lines = [";FFMETADATA1", f"title={escape(book['title'])}", f"artist={escape(book['author'])}",
             f"album={escape(book['title'])}", f"composer={escape(book['narrator'])}", f"date={book['year']}",
             "genre=Audiobook"]
    start = 0
    for title, length in zip(book["chapters"], chapter_lengths(book)):
        lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={start * 1000}", f"END={(start + length) * 1000}",
                  f"title={escape(typographic(title))}"]
        start += length
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as meta:
        meta.write("\n".join(lines) + "\n")
    run(["-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-i", meta.name, "-map", "0:a", "-map_metadata", "1",
         "-map_chapters", "1", "-t", str(book["duration"]), "-c:a", "aac", "-b:a", "8k", "-f", "mp4", path])
    os.unlink(meta.name)
    print("book", path)


def make_podcast(root, podcast):
    folder = os.path.join(root, podcast["title"])
    os.makedirs(folder, exist_ok=True)
    for index, (season, episode, title, minutes, _) in enumerate(podcast["episodes"], start=1):
        path = os.path.join(folder, f"{index:02d} - {title.replace(': ', ', ')}.mp3")
        if os.path.exists(path):
            continue
        seconds = minutes * 60 + random.Random(title).randint(0, 59)
        run(["-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", str(seconds), "-c:a", "libmp3lame", "-b:a", "8k",
             "-id3v2_version", "3", "-metadata", f"title={title}", "-metadata", f"artist={podcast['author']}",
             "-metadata", f"album={podcast['title']}", "-metadata", f"track={episode}", "-metadata", "genre=Podcast",
             path])
        print("episode", path)


if __name__ == "__main__":
    books_root, podcasts_root = sys.argv[1], sys.argv[2]
    for book in BOOKS:
        make_book(books_root, book)
    for podcast in PODCASTS:
        make_podcast(podcasts_root, podcast)

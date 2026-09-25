#!/usr/bin/env python3
"""Run a Tapless swipe test session on a Kindle over SSH.

Installs a recorder as a KOReader user patch, prompts words to swipe on
the device, follows the recording live, then removes everything and
replays the recording through the plugin's code.
"""
import argparse
import datetime
import json
import os
import random
import re
import select
import shlex
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
PLUGIN = os.path.join(ROOT, "tapless.koplugin")
WORD = re.compile(r"^[a-z]{2,10}$")
# Long words, for testing how the keyboard finds them.
LONG_WORD = re.compile(r"^[a-z]{8,14}$")


def word_prompts(dictionary, count, rng, pattern=WORD):
    path = os.path.join(PLUGIN, "dictionaries", dictionary,
                        "words.buckets.tsv")
    freq = {}
    with open(path, encoding="utf-8") as tsv:
        for line in tsv:
            fields = line.rstrip("\n").split("\t")
            # The word as typed, not the letters it is filed under: "don't"
            # is filed under "dont", which is no word to prompt.
            if len(fields) >= 3 and pattern.match(fields[1]):
                freq[fields[1]] = max(freq.get(fields[1], 0), int(fields[2]))
    ranked = sorted(freq, key=lambda word: -freq[word])
    bands = [ranked[:1000], ranked[1000:5000], ranked[5000:20000]]
    bands = [band for band in bands if band]
    words = []
    for index, band in enumerate(bands):
        share = count // len(bands) + (1 if index < count % len(bands) else 0)
        words += rng.sample(band, min(share, len(band)))
    rng.shuffle(words)
    return words


def sentence_prompts(count, rng):
    path = os.path.join(TOOLS, "prompts", "sentences.txt")
    with open(path, encoding="utf-8") as text:
        sentences = [line.strip() for line in text if line.strip()]
    return rng.sample(sentences, min(count, len(sentences)))


class Kindle:
    def __init__(self, host, port, koreader):
        self.host = host
        self.port = str(port)
        self.koreader = koreader
        self.dev = koreader + "/tapless-dev"
        self.patch = koreader + "/patches/2-tapless-recorder.lua"

    def ssh(self, command, check=True):
        return subprocess.run(["ssh", "-p", self.port, self.host, command],
                              check=check, capture_output=True, text=True)

    def put(self, local, remote):
        subprocess.run(["scp", "-q", "-P", self.port, local,
                        f"{self.host}:{remote}"], check=True)

    def get(self, remote, local):
        return subprocess.run(["scp", "-q", "-P", self.port,
                               f"{self.host}:{remote}", local]).returncode == 0

    def write(self, remote, text):
        subprocess.run(["ssh", "-p", self.port, self.host,
                        f"cat > {shlex.quote(remote)}"],
                       input=text, text=True, check=True)

    def follow(self):
        return subprocess.Popen(
            ["ssh", "-p", self.port, self.host,
             f"tail -n +1 -f {shlex.quote(self.dev + '/session.jsonl')}"],
            stdout=subprocess.PIPE, bufsize=0)


def install(kindle, prompts, mode):
    dev = shlex.quote(kindle.dev)
    kindle.ssh(f"rm -rf {dev} && mkdir -p {dev} "
               f"{shlex.quote(kindle.koreader + '/patches')}")
    kindle.put(os.path.join(TOOLS, "recorder", "recorder.lua"),
               kindle.dev + "/recorder.lua")
    kindle.write(kindle.dev + "/prompts.txt", "\n".join(prompts) + "\n")
    kindle.write(kindle.dev + "/mode", mode + "\n")
    kindle.ssh(f": > {dev}/session.jsonl && : > {dev}/recording")
    kindle.put(os.path.join(TOOLS, "recorder_patch.lua"), kindle.patch)


def uninstall(kindle):
    kindle.ssh(f"rm -f {shlex.quote(kindle.dev + '/recording')} "
               f"{shlex.quote(kindle.patch)}", check=False)
    # follow() started a remote `tail -f` over ssh with no tty; that
    # process can outlive this ssh session, so stop it explicitly rather
    # than rely on it noticing the log file is gone.
    kindle.ssh("pkill -f " + shlex.quote(
        "tail -n +1 -f " + kindle.dev + "/session.jsonl"), check=False)


def collect(kindle):
    os.makedirs(os.path.join(ROOT, "sessions"), exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    local = os.path.join(ROOT, "sessions", stamp + ".jsonl")
    if not kindle.get(kindle.dev + "/session.jsonl", local):
        print("Could not copy the session log from the Kindle.")
        return None
    kindle.ssh(f"rm -rf {shlex.quote(kindle.dev)}", check=False)
    dkjson = os.path.join(TOOLS, "dkjson.lua")
    if not os.path.exists(dkjson):
        kindle.get(kindle.koreader + "/common/dkjson.lua", dkjson)
    return local


def fetch_settings(kindle):
    """Copy the Kindle's saved settings to a temporary file, for the word
    counts the keyboard learned; None if they cannot be read. KOReader saves
    them when it exits, and the keyboard learns nothing while a session is
    recorded, so these are the counts the session ran with. The file holds
    all of KOReader's settings: the caller removes it."""
    handle, path = tempfile.mkstemp(prefix="tapless-settings-", suffix=".lua")
    os.close(handle)
    if kindle.get(kindle.koreader + "/settings.reader.lua", path):
        os.chmod(path, 0o600)
        return path
    os.remove(path)
    return None


def show(record, stats):
    kind = record.get("type")
    if kind == "start":
        print(f"Recording started ({record.get('prompts')} prompts). "
              "Open any text box on the Kindle and swipe what it shows.")
        print("Press Enter here to stop early.\n")
    elif kind == "attempt":
        target = record.get("target")
        if record.get("short"):
            print(f"  {target:<14} too short, typed as a tap; try again")
            return
        inserted = record.get("inserted")
        shown = [c.get("word") for c in record.get("candidates", [])]
        if inserted is None:
            print(f"  {target:<14} no word found for "
                  f"{record.get('letters')}; try again")
            return
        stats["n"] += 1
        good = (inserted or "").lower() == (target or "").lower()
        stats["top1"] += good
        mark = "✓" if good else "✗"
        others = ", ".join(w for w in shown[1:] if w)
        print(f"{mark} {target:<14} -> {inserted:<14} "
              f"[{record.get('letters')}] {others}   "
              f"{100 * stats['top1'] / stats['n']:.0f}% of {stats['n']}")
    elif kind == "outcome":
        if record.get("outcome") == "deleted":
            print("  deleted; asking for the word again")
        else:
            print(f"  picked suggestion {record.get('index')}: "
                  f"{record.get('word')}")
    elif kind == "end":
        print("\nSession finished.")


def run(kindle):
    stats = {"n": 0, "top1": 0}
    process = kindle.follow()
    started = False
    remainder = b""
    print("Restart KOReader on the Kindle now (Exit > Restart). "
          "Waiting for the recorder...")
    try:
        while True:
            ready, _, _ = select.select(
                [process.stdout] + ([sys.stdin] if started else []), [], [])
            if sys.stdin in ready:
                sys.stdin.readline()
                print("\nStopping.")
                return
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                print("Lost the connection to the Kindle.")
                return
            remainder += chunk
            lines = remainder.split(b"\n")
            remainder = lines.pop()
            for raw_line in lines:
                try:
                    record = json.loads(raw_line.decode("utf-8"))
                except ValueError:
                    continue
                started = started or record.get("type") == "start"
                show(record, stats)
                if record.get("type") == "end":
                    return
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        process.terminate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sentences", action="store_true",
                        help="prompt short sentences instead of words")
    parser.add_argument("--long", action="store_true",
                        help="prompt words of 8 to 14 letters")
    parser.add_argument("--no-replay", action="store_true",
                        help="save the session without replaying it")
    parser.add_argument("--count", type=int,
                        help="words (default 50) or sentences (default 20)")
    parser.add_argument("--seed", type=int, help="repeatable prompts")
    parser.add_argument("--dictionary", default="en")
    parser.add_argument("--host", default="root@10.0.10.166")
    parser.add_argument("--port", type=int, default=2222)
    parser.add_argument("--koreader", default="/mnt/us/koreader")
    parser.add_argument("--print-prompts", action="store_true",
                        help="print the prompts and exit")
    args = parser.parse_args()

    if args.long and args.sentences:
        parser.error("--long prompts words, not sentences")
    rng = random.Random(args.seed)
    mode = "sentences" if args.sentences else "words"
    count = args.count or (20 if args.sentences else 50)
    prompts = (sentence_prompts(count, rng) if args.sentences
               else word_prompts(args.dictionary, count, rng,
                                 LONG_WORD if args.long else WORD))
    if args.print_prompts:
        print("\n".join(prompts))
        return

    kindle = Kindle(args.host, args.port, args.koreader)
    install(kindle, prompts, mode)
    try:
        run(kindle)
    finally:
        uninstall(kindle)
        print("Recorder removed; it is gone after the next KOReader restart.")
    log = collect(kindle)
    if log:
        print(f"Saved {os.path.relpath(log, ROOT)}\n")
        if args.no_replay:
            return
        command = ["luajit", os.path.join(TOOLS, "replay.lua"), "--misses"]
        settings = fetch_settings(kindle)
        if settings:
            # Replay with the words the keyboard had learned, as they stood.
            command += ["--usage", "--usage-settings", settings,
                        "--no-learning"]
        try:
            subprocess.run(command + [log])
        finally:
            if settings:
                os.remove(settings)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build a dictionary's word-pair table from a corpus of sentences.

Counts which word follows which, the way the keyboard sees text: a pair is
two words separated only by spaces, the first all letters, the second all
letters but for punctuation after it. Each pair of dictionary words earns
a bonus in the ranking's frequency units (Zipf x 1000), how much likelier
the word is after the previous word than anywhere:

    bonus = SCALE * log10(P(word | previous) / P(word)), capped at CAP

Pairs seen fewer than MIN_COUNT times, or earning less than MIN_BONUS, are
left out, and each previous word keeps its PER_WORD most frequent
followers.

Writes words.pairs.tsv, one line per previous word:

    previous<TAB>word:bonus word:bonus ...

grouped into buckets by the previous word's first two letters (a one-letter
word twice: "a" is in "aa"), and words.pairs.idx indexing the buckets like
words.buckets.idx. The dictionary's manifest.tsv gets the files' names and
checksums. --flat writes plain "previous<TAB>word<TAB>bonus" lines to
words.pairs.flat.tsv instead, for experiments.

    python3 tools/build_word_pairs.py --dictionary DIR \\
        --exclude tools/prompts/sentences.txt --exclude-words 4 CORPUS...

--exclude leaves out the corpus sentences found in a file, and with
--exclude-words N any sentence sharing N words in a row with one of them:
built without the test prompts, the table cannot flatter replays of
sentence sessions. A corpus file is plain text, one sentence per line, or
TSV with the sentence in the last column (Tatoeba's exports); .bz2 and .gz
are read directly.
"""
import argparse
import bz2
import collections
import gzip
import hashlib
import math
import os
import re
import sys

LETTERS = re.compile(r"^[a-z]+$")
TRAILING = re.compile(r"[^\w\s]+$")
MANIFEST_KEYS = ("pairs_data", "pairs_index", "sha256_pairs_data",
                 "sha256_pairs_index", "pairs_source")


def open_text(path):
    if path.endswith(".bz2"):
        return bz2.open(path, "rt", encoding="utf-8", errors="replace")
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def sentences(paths):
    for path in paths:
        with open_text(path) as text:
            for line in text:
                yield line.rstrip("\n").split("\t")[-1]


def words_of(sentence):
    return re.findall(r"[a-z']+", sentence.lower())


def runs(words, length):
    return {tuple(words[i:i + length])
            for i in range(len(words) - length + 1)}


class Exclusion:
    """The sentences to leave out: those in a file, or with length set,
    those sharing that many words in a row with one of them."""

    def __init__(self, path, length):
        self.length = length
        self.known = set()
        with open(path, encoding="utf-8") as text:
            for line in text:
                words = words_of(line)
                if not words:
                    continue
                if length:
                    self.known |= runs(words, length)
                else:
                    self.known.add(tuple(words))

    def __contains__(self, sentence):
        words = words_of(sentence)
        if self.length:
            return not self.known.isdisjoint(runs(words, self.length))
        return tuple(words) in self.known


def count(paths, exclusion):
    """Counts of words as typed, of words as previous words, and of pairs;
    and how many sentences were left out."""
    words = collections.Counter()
    previous = collections.Counter()
    pairs = collections.Counter()
    left_out = 0
    for sentence in sentences(paths):
        if exclusion and sentence in exclusion:
            left_out += 1
            continue
        before = None
        for token in sentence.lower().split():
            word = TRAILING.sub("", token)
            typed = word if LETTERS.match(word) else None
            if typed:
                words[typed] += 1
                if before:
                    previous[before] += 1
                    pairs[before, typed] += 1
            # The keyboard sees a previous word only when nothing but
            # spaces follows it.
            before = token if LETTERS.match(token) else None
    return words, previous, pairs, left_out


def read_dictionary(directory):
    words = set()
    with open(os.path.join(directory, "words.buckets.tsv"),
              encoding="utf-8") as tsv:
        for line in tsv:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2 and fields[1]:
                words.add(fields[1])
    return words


def table(words, previous, pairs, dictionary, args):
    total = sum(words.values())
    rows = collections.defaultdict(list)
    for (before, word), n in pairs.items():
        if n < args.min_count or before not in dictionary \
                or word not in dictionary:
            continue
        ratio = (n / previous[before]) / (words[word] / total)
        bonus = min(args.cap, round(args.scale * math.log10(ratio)))
        if bonus >= args.min_bonus:
            rows[before].append((n, word, bonus))
    kept = {}
    for before, followers in rows.items():
        followers.sort(key=lambda follower: (-follower[0], follower[1]))
        kept[before] = sorted((word, bonus) for _, word, bonus
                              in followers[:args.per_word])
    return kept


def bucket_key(word):
    return word * 2 if len(word) == 1 else word[:2]


def sha256(path):
    with open(path, "rb") as data:
        return hashlib.sha256(data.read()).hexdigest()


def write_flat(kept, out_dir):
    with open(os.path.join(out_dir, "words.pairs.flat.tsv"), "w",
              encoding="utf-8") as out:
        for before in sorted(kept):
            for word, bonus in kept[before]:
                out.write(f"{before}\t{word}\t{bonus}\n")


def write_buckets(kept, out_dir):
    buckets = collections.defaultdict(list)
    for before in sorted(kept):
        buckets[bucket_key(before)].append(before + "\t" + " ".join(
            f"{word}:{bonus}" for word, bonus in kept[before]) + "\n")
    offset = 0
    with open(os.path.join(out_dir, "words.pairs.tsv"), "wb") as data, \
            open(os.path.join(out_dir, "words.pairs.idx"), "w",
                 encoding="utf-8") as index:
        index.write("# key\toffset\tbytes\trows\n")
        for key in sorted(buckets):
            chunk = "".join(buckets[key]).encode("utf-8")
            data.write(chunk)
            index.write(f"{key}\t{offset}\t{len(chunk)}\t"
                        f"{len(buckets[key])}\n")
            offset += len(chunk)


def update_manifest(out_dir, source):
    path = os.path.join(out_dir, "manifest.tsv")
    if not os.path.exists(path):
        return
    values = {
        "pairs_data": "words.pairs.tsv",
        "pairs_index": "words.pairs.idx",
        "sha256_pairs_data": sha256(os.path.join(out_dir, "words.pairs.tsv")),
        "sha256_pairs_index": sha256(os.path.join(out_dir,
                                                  "words.pairs.idx")),
    }
    if source:
        values["pairs_source"] = source
    with open(path, encoding="utf-8") as manifest:
        lines = [line for line in manifest
                 if line.split("\t", 1)[0] not in MANIFEST_KEYS]
    lines += [f"{key}\t{values[key]}\n" for key in MANIFEST_KEYS
              if key in values]
    with open(path, "w", encoding="utf-8") as manifest:
        manifest.writelines(lines)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("corpus", nargs="+")
    parser.add_argument("--dictionary", required=True,
                        help="dictionary folder holding words.buckets.tsv")
    parser.add_argument("--out", help="output folder (default: --dictionary)")
    parser.add_argument("--exclude",
                        help="leave out the sentences in this file")
    parser.add_argument("--exclude-words", type=int, default=0,
                        help="and any sharing this many words in a row")
    parser.add_argument("--source", help="where the corpus came from, "
                        "for the manifest's pairs_source")
    parser.add_argument("--scale", type=float, default=1000)
    parser.add_argument("--cap", type=int, default=3000)
    parser.add_argument("--min-count", type=int, default=3)
    parser.add_argument("--min-bonus", type=int, default=300)
    parser.add_argument("--per-word", type=int, default=64)
    parser.add_argument("--flat", action="store_true")
    args = parser.parse_args()

    exclusion = args.exclude and Exclusion(args.exclude, args.exclude_words)
    words, previous, pairs, left_out = count(args.corpus, exclusion)
    kept = table(words, previous, pairs, read_dictionary(args.dictionary),
                 args)
    out_dir = args.out or args.dictionary
    os.makedirs(out_dir, exist_ok=True)
    if args.flat:
        write_flat(kept, out_dir)
    else:
        write_buckets(kept, out_dir)
        update_manifest(out_dir, args.source)
    print(f"{sum(words.values())} words counted, {left_out} sentences left "
          f"out; kept {sum(len(row) for row in kept.values())} pairs after "
          f"{len(kept)} previous words", file=sys.stderr)


if __name__ == "__main__":
    main()

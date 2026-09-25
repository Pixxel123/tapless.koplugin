#!/usr/bin/env python3
"""Put contractions into a dictionary with their apostrophes.

The bundled English word list came without any word holding an
apostrophe, so it had "dont" and "theyre", at the frequency of people
typing them without one, and no "don't" at all. This adds each word in
the list (tools/contractions_en.tsv) under its letters, so a swipe or
tapped letters spelling "dont" finds "don't", at its own frequency. The
spelling without the apostrophe is dropped, unless it is a word of its
own ("were" for "we're", "well" for "we'll").

Rewrites words.buckets.tsv and .idx, rebuilds words.popular.tsv and .idx
(the most frequent words for each first letter), and updates the
manifest's row count and checksums. Running it again changes nothing.

    python3 tools/add_contractions.py --dictionary DIR [--list FILE]
"""
import argparse
import collections
import hashlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def read_list(path):
    contractions = []
    with open(path, encoding="utf-8") as text:
        for line in text:
            if line.startswith("#") or not line.strip():
                continue
            word, zipf, plain = line.rstrip("\n").split("\t")
            contractions.append((word, round(float(zipf) * 1000),
                                 plain == "keep"))
    return contractions


def signature(word):
    return word.lower().replace("'", "")


def read_rows(path):
    with open(path, encoding="utf-8") as text:
        return [line.rstrip("\n").split("\t") for line in text if line.strip()]


def bucket_key(sig):
    return sig[0] + sig[-1]


def write_indexed(rows, data_path, index_path, key):
    groups = collections.OrderedDict()
    for row in rows:
        groups.setdefault(key(row), []).append(row)
    offset = 0
    with open(data_path, "wb") as data, \
            open(index_path, "w", encoding="utf-8") as index:
        index.write("# key\toffset\tbytes\trows\n")
        for group_key in sorted(groups):
            chunk = "".join("\t".join(row) + "\n"
                            for row in groups[group_key]).encode("utf-8")
            data.write(chunk)
            index.write(f"{group_key}\t{offset}\t{len(chunk)}\t"
                        f"{len(groups[group_key])}\n")
            offset += len(chunk)


def sha256(path):
    with open(path, "rb") as data:
        return hashlib.sha256(data.read()).hexdigest()


def update_manifest(directory, values):
    path = os.path.join(directory, "manifest.tsv")
    with open(path, encoding="utf-8") as text:
        lines = text.readlines()
    seen = set()
    for index, line in enumerate(lines):
        key = line.split("\t", 1)[0]
        if key in values:
            lines[index] = f"{key}\t{values[key]}\n"
            seen.add(key)
    lines += [f"{key}\t{value}\n" for key, value in values.items()
              if key not in seen]
    with open(path, "w", encoding="utf-8") as text:
        text.writelines(lines)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--dictionary", required=True)
    parser.add_argument("--list", default=os.path.join(
        HERE, "contractions_en.tsv"))
    parser.add_argument("--popular", type=int, default=256,
                        help="most frequent words kept per first letter")
    args = parser.parse_args()

    contractions = read_list(args.list)
    folder = args.dictionary
    rows = read_rows(os.path.join(folder, "words.buckets.tsv"))
    lang = rows[0][3]
    listed = {word for word, _, _ in contractions}
    dropped = {signature(word) for word, _, keep in contractions if not keep}
    removed = sum(1 for row in rows if row[1] in dropped)
    rows = [row for row in rows
            if row[1] not in listed and row[1] not in dropped]
    rows += [[signature(word), word, str(freq), lang]
             for word, freq, _ in contractions]
    rows.sort(key=lambda row: (bucket_key(row[0]), -int(row[2]), row[1]))
    write_indexed(rows, os.path.join(folder, "words.buckets.tsv"),
                  os.path.join(folder, "words.buckets.idx"),
                  lambda row: bucket_key(row[0]))

    by_first = collections.defaultdict(list)
    for row in rows:
        by_first[row[0][0]].append(row)
    popular = []
    for first in sorted(by_first):
        ranked = sorted(by_first[first], key=lambda row: (-int(row[2]),
                                                          row[1]))
        popular += ranked[:args.popular]
    write_indexed(popular, os.path.join(folder, "words.popular.tsv"),
                  os.path.join(folder, "words.popular.idx"),
                  lambda row: row[0][0])

    update_manifest(folder, {
        "rows": str(len(rows)),
        "sha256_data": sha256(os.path.join(folder, "words.buckets.tsv")),
        "sha256_index": sha256(os.path.join(folder, "words.buckets.idx")),
        "sha256_popular_data": sha256(os.path.join(folder,
                                                   "words.popular.tsv")),
        "sha256_popular_index": sha256(os.path.join(folder,
                                                    "words.popular.idx")),
    })
    print(f"{len(rows)} words: {len(contractions)} contractions, "
          f"{removed} spellings without the apostrophe removed")


if __name__ == "__main__":
    main()

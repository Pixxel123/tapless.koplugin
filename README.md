# Tapless for KOReader

Swipe typing for KOReader.

This is my fork of [azac/tapless.koplugin](https://github.com/azac/tapless.koplugin).
It fixes a lot of missed and wrong words, and adds a few typing options.
Most of the recognition work was tuned on real swipes recorded on a Kindle
Paperwhite. Some of it is up for review upstream in
[#2](https://github.com/azac/tapless.koplugin/pull/2) and
[#4](https://github.com/azac/tapless.koplugin/pull/4). The rest is here
while I test it.

![](https://github.com/user-attachments/assets/8b1577d7-e5a5-4cd0-876c-627eaad4cc14)

## Installation

Copy the `tapless.koplugin` folder into KOReader's `plugins` folder and
restart KOReader. If Tapless is already installed, replace the old folder.

## Compared with upstream

The same swipes, replayed through upstream 0.4.0 and through this fork.
"First choice" is the word that gets typed. "In the row" means the word is
anywhere in the suggestion row.

| | Upstream 0.4.0 | This fork |
|---|---|---|
| Sentences, first choice (670 swipes) | 54% | 71% |
| Sentences, in the row | 64% | 77% |
| Random words, first choice (212 swipes) | 40% | 62% |
| Random words, in the row | 48% | 71% |
| Random words of 8 or more letters, first choice | 14% | 41% |
| Swipes that didn't start on the word's first key, first choice | 0% | 30% |
| Clean generated swipes, common words | 96% | 98% |
| Clean generated swipes, mid-frequency words | 93% | 96% |
| Clean generated swipes, rare words | 88% | 86% |

On the sentences, the fork gets 120 swipes right that upstream got wrong,
and 3 wrong that upstream got right. On the random words it's 51 and 3.

Rare words are slightly worse. That's a deliberate trade: common words
count for more, so the odd rare word now loses to a common one with a
similar shape.

Recognising a swipe takes about 25 ms on a Kindle Paperwhite, around twice
upstream's time. It isn't noticeable next to the screen refresh.

<details>
<summary>How these were measured</summary>

- 882 swipes over 11 sessions, recorded on a Kindle Paperwhite (12th gen)
  with KOReader v2026.07.2 using `tools/swipe_session.py`. The word
  sessions prompt random words from three frequency bands. The sentence
  sessions prompt short everyday sentences, 20 at a time.
- `tools/replay.lua` feeds the recorded touch points back through each
  version's recognition code, so both versions see exactly the same
  swipes. Learned word pairs are built up as the sentences are typed and
  reset between sessions, as they would be on a fresh install.
- The clean swipes are generated: a straight line between key centres with
  a short pause on each key, 1500 words from each frequency band. They
  catch changes that break words which used to work.
- The fork's ranking weights were fitted on the word sessions, so treat
  that row as a bit optimistic. The sentence sessions weren't used for
  fitting.
- Swipes that upstream cut short when a second finger touched the screen
  don't show up here at all, because the recordings were made with that
  fix in. Before the fix, it cut short 7 of 32 swipes in one session.
- "Fixed" and "broken" counts come with an exact McNemar test. Both
  headline differences are far beyond chance (p below 1e-11).

</details>

## What's changed

### Recognition

- Swipes that start just inside the next key over still find the word.
- A corner you cut short can lend a letter from the key next to it.
- Scribbling back and forth on a key types a double letter.
- Rare short fragments like "bq" and "gtg" stop beating real words.
- Common words count for more against the shape of the swipe.
- Spellings that only repeat letters ("wee", "weee") no longer fill the
  row.
- Swipes that start on the number row type a word, not a digit.

<details>
<summary>How recognition works now</summary>

Every swipe gives a string of letters the finger passed over, such as
`wertyuilkl` for "well". Candidate words are looked up in the dictionary
by first and last letter, scored on how well their letters line up with
that string and with the actual touch points, then ranked with word
frequency.

**Starting on the next key.** On e-ink it's easy to land just inside a
neighbouring key. If the swipe starts within a quarter of a key of another
key, words starting with that key are looked up too. They pay a small
penalty, much smaller than a word whose first letter the swipe missed
completely.

**Borrowed letters.** A fast swipe often cuts a corner, so the key at the
corner is never touched. A word can take up to two of its inner letters
from a key next to one the path passed over. This only counts where the
path actually turned, so keys you slide straight past don't lend letters.
Each borrowed letter costs a little.

**Double letters.** A swipe can't show a doubled letter, so "too" and "to"
look the same. A short back-and-forth on one key now counts as a repeated
letter and favours the doubled spelling. Small wobbles and sharp corners
don't count.

**Rare short words.** Dictionaries are full of short rare strings (bq,
chg, gtg) that fit almost any short swipe. Words of four letters or fewer
that are rare pay a penalty, based only on length and frequency, so it
works the same in every language. A word you use often is exempt (see
below).

**Ranking.** The balance between swipe shape and word frequency was fitted
to the recorded swipes by maximum likelihood, then pulled back towards the
old values so rare words didn't lose too much. That's where the 2 point
drop on rare clean swipes comes from.

**Repeated letters in the row.** Words that differ only in doubled letters
("we", "wee") look the same to a swipe. At most two of them take a place
in the suggestion row, and spellings with a letter three times in a row
are left out.

**The number row.** The keyboard has a row of digits above the letters.
A swipe that starts on a digit and goes on across letters is taken as
starting on the letter key below. A tap, or a short slide that doesn't
reach another letter, is left to KOReader, so digits and the characters
you get by sliding off a digit key still work. In the sessions recorded
before this change, 27 swipes started on the number row and typed a digit
or a symbol instead of a word.

</details>

### Learning

- Words you keep typing rise up the list.
- The word that usually follows the one before it wins ("the sun", not
  "the sin").

<details>
<summary>How learning works</summary>

**Your words.** Every word you keep in the text is counted. A word you
pick from the suggestion row counts double, and a word you delete straight
away isn't counted. From two uses a word gets a boost, which grows with
use up to a limit, and never lifts a word above the most common words. A
word used four times or more is also exempt from the rare short word
penalty. Up to 2000 words are kept, dropping the least used. The counts
are saved in KOReader's settings.

**Word pairs.** Tapless already learned which word you type after which.
The fork adds a table of common word pairs for English, so this works from
the first sentence instead of only after you've typed a pair yourself. A
pair's bonus depends on how much likelier the word is after the previous
word than anywhere else. The learned bonus and the table bonus are added
together, up to the same limit the learned bonus had on its own. It
only applies when the previous word is followed by just a space, so after
a full stop or a comma nothing is assumed.

On the sentence sessions the table alone took first choice from 68% to
71%, with 17 swipes fixed and none broken. The fixes are the look-alike
mistakes: "tu" for "to", "will" for "well", "while" for "whole", "sin" for
"sun".

The table is 1.6 MB and sits next to the English dictionary. Only the
part for the previous word is read, when it's needed. It was counted from
the English sentences of [Tatoeba](https://tatoeba.org) (CC BY 2.0 FR) by
`tools/build_word_pairs.py`, leaving out any sentence that shares four
words in a row with the test prompts, so replays of the test sessions stay
fair. See `tapless.koplugin/dictionaries/en/ATTRIBUTION.txt`.

Learned pairs are capped at 24 following words for each word and 2000
words in total, because they're saved in KOReader's settings file, which
is rewritten in full on every save.

Installing English from the dictionary manager's download list replaces
the bundled dictionary with one that has no pair table. Everything still works, just
without the table.

</details>

### Typing

- A second finger touching the screen no longer cuts a swipe short.
- A swipe that only touches one letter types that letter.
- Fast tapping doesn't turn into swiped words.
- Spaces go in front of the next word, so punctuation sits right.

<details>
<summary>Typing details</summary>

**Second finger.** A thumb resting on the edge of the screen mid-swipe was
paired with the swiping finger into a two-finger gesture, and the swipe
ended part-way through. It's now ignored until it lifts. This was the
biggest single cause of misses. Pinch zoom and two-finger typing are
unchanged.

**Two quick taps.** On KOReader v2026.07.2 and older, two fingers landing
close together were merged into one two-finger tap and both keys were
lost. The fork backports KOReader's fix (koreader#15840). Nothing is
changed on newer KOReader.

**One-letter swipes.** On e-ink a tap often drifts far enough to count as
a swipe, and the keypress was lost. A swipe that only crosses one letter
now types it.

**Fast tapping.** A short slide within half a second of tapping a letter
types the key it started on.

**Spaces.** The space after a swiped word is added when the next word
starts, so "hello, world" comes out right and text doesn't end in a stray
space. A swiped word after a tapped word, or after punctuation, gets its
space too.

**Other keyboard patches.** Letter swipes keep working when another plugin
or patch replaces the key handlers, like the ZenOS keyboard patch.

</details>

### Suggestion row

- Hold a suggestion to block that word.
- The row clears its e-ink ghosting every few changes.
- All four slots are used for words.

<details>
<summary>Suggestion row details</summary>

Blocked words are listed in the dictionary manager and can be unblocked
there. Adding a word to your personal words unblocks it.

The row gets a flash refresh every six changes to clear ghosting. Swipes
themselves stay flash-free.

The language used to take up a suggestion slot. It's now shown on the
space bar (see below), so all four slots show words.

</details>

### Languages and keyboard size

- Pick your languages the first time the keyboard opens.
- The language is shown on the space bar. Hold space to switch.
- Keyboard size and key text size options.
- Bundled dictionaries can be removed.

<details>
<summary>Languages and size details</summary>

- Languages can be enabled and disabled in the dictionary manager, under
  `Tools → Tapless → Manage dictionaries`. At least one has to stay
  enabled, and the last one can't be removed.
- With only one language enabled, holding space types a space.
- Personal words opened from `Tools → Tapless` show the list for the
  current language.
- `Keyboard size` can be Same as KOReader (the default), Extra compact,
  Compact, Normal or Large. It changes the height and keeps the keyboard
  full-width. Same as KOReader follows KOReader's own compact keyboard
  setting.
- `Keyboard text size` can be Auto, Small, Normal or Large. Auto matches
  the keyboard size, or keeps KOReader's key font size when the size is
  Same as KOReader.

</details>

## Options

These are under `Tools → Tapless` and are off by default:

- **Slide on space to move cursor**: slide left or right along the space
  bar to move the text cursor. Holding space still switches language.
- **Double space types a period**: a second space right after a word, or a
  space right after a swiped word, becomes ". ". Not used on input method
  layouts (Chinese, Japanese, Korean, Vietnamese).

## Testing tools

None of this is in the plugin folder or changes the plugin.

- `luajit spec/run.lua` runs the tests.
- `tools/swipe_session.py` runs a prompted swipe session on a device over
  SSH, then replays it.
- `tools/replay.lua` replays recorded sessions through the plugin code.
  `--compare DIR` shows which swipes a change fixed or broke.
- `tools/clean_swipes.lua` generates clean swipes for regression checks.
- `tools/fit_weights.lua` fits the ranking weights to recorded swipes.
- `tools/build_word_pairs.py` builds a dictionary's word-pair table.

<details>
<summary>More on the testing tools</summary>

`swipe_session.py` installs a temporary KOReader patch that shows words
or sentences to swipe and records every attempt: the touch points, the
keys, what was typed, and whether you kept it, picked another suggestion
or deleted it. It prints each result as you go. At the end it removes the
patch, copies the recording to `sessions/` and replays it. Learning is
paused while a session is recorded, so the test doesn't change your word
counts.

`replay.lua` prints first choice, in-the-row and mean reciprocal rank,
split by word length and by where the swipe started, next to what the
device showed at the time, plus the time each swipe took. `--compare`
lists every swipe that changed between two plugin folders, with a McNemar
p value. `--context` and `--usage` build up learned pairs and word counts
as the swipes are replayed, `--per-session` starts them over for each
session, and `--losses` shows at which step each missed word was lost.

Recordings go in `sessions/`, which is git-ignored because it contains
typed text.

</details>

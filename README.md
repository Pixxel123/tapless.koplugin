# Tapless for KOReader

Swipe typing for the KOReader.

![](https://github.com/user-attachments/assets/8b1577d7-e5a5-4cd0-876c-627eaad4cc14)

## Installation

Extract into the `plugins` directory. Restart KOReader.

## Options

Tapless settings are under **Tools → Tapless**. These are off by default:

- **Slide on space to move cursor**: slide left or right along the space
  bar to move the text cursor. Holding space still switches language.
- **Double space types a period**: a second space right after a word, or a
  space right after a swiped word, becomes ". ". Not used on input method
  layouts (Chinese, Japanese, Korean, Vietnamese).

## Word pairs

In English, a swipe that could be several words prefers the one that
usually follows the word before it ("the sun", not "the sin"). The table of
which words follow which is counted from the English sentences of
[Tatoeba](https://tatoeba.org) (CC BY 2.0 FR) by `tools/build_word_pairs.py`;
see `tapless.koplugin/dictionaries/en/ATTRIBUTION.txt`.

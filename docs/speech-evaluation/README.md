# Speech evaluation with 18 readers

[Listen to the clips and compare the transcripts](https://essencesentry.github.io/aside-macos/speech-evaluation/).

This pairs two outputs from the shipped native bench: `long-context-original` and `pauses-filler-masked-experimental`. Both use Parakeet TDT 0.6B v3. The second transforms the audio before recognition. Punctuation differences alone contribute zero word edits.

## Reproduce

On Apple Silicon with Swift 6.2+, run from this directory. Use a new directory for the local models and results.

```sh
swift build --package-path ../../native --product AsideAudioBench
bench="$(swift build --package-path ../../native --show-bin-path)/AsideAudioBench"
for clip in audio/*.flac; do
  id="$(basename "$clip" .flac)"
  "$bench" --input "$clip" --model-root "$TMPDIR/aside-eval-models" --output "$TMPDIR/aside-eval-$id" --download-model --download-vad
done
python3 report.py
```

The bench writes the individual variants to each output directory's `results.json`. The report reads the two saved transcripts per clip from [clips.json](clips.json). Its corpus word error rate divides the total edit count by the total number of reference words. The word tokenizer lowercases, normalizes apostrophes, drops punctuation and preserves numbers as written.

## Sampling and attribution

Both sets were selected from LibriSpeech **dev-clean** before comparing outputs within that set. For the short set, sort utterance IDs lexicographically, keep 8–25 words, and take the first eligible utterance from a new speaker for each of three criteria, twice in order. The name terms were MR, MRS, MISS, PETER, ALICE, MARY, JAMES, JOHN and PAUL. Number terms were TWENTY, THIRTY, FORTY, HUNDRED, THOUSAND and FIFTY. Negation terms were NEVER, NOT and CANNOT. For the stress set, take the first 12 additional speakers in the same ID order whose utterances have 30–49 words. The listening report spotlights a regression found after scoring.

These 18 synthetic-free excerpts are English audiobook readings. The experiment does not estimate error rates for meetings, interruptions, or Spanish speech. The original clips and reference text are from LibriSpeech, Vassil Panayotov, Guoguo Chen, Daniel Povey and Sanjeev Khudanpur, ICASSP 2015, derived from LibriVox. The filenames preserve the speaker, chapter and utterance IDs. [Corpus and original metadata](https://www.openslr.org/12/) · [CC BY 4.0 license](https://creativecommons.org/licenses/by/4.0/)

"""Build the listening report from measured transcripts. Uses only the standard library."""

import json
import re
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*", text.lower().replace("’", "'"))


def errors(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, word in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1]


def report():
    rows = json.loads((ROOT / "clips.json").read_text())
    cards, summaries = [], []
    for subset in ("Short passages", "Longer passages"):
        reference_count = raw_edits = prepared_edits = 0
        for row in (r for r in rows if r["subset"] == subset):
            reference = words(row["reference"])
            raw = errors(reference, words(row["raw"]))
            prepared = errors(reference, words(row["prepared"]))
            reference_count += len(reference)
            raw_edits += raw
            prepared_edits += prepared
            key = row["id"]
            end_ms = round(row["seconds"] * 1000)
            seconds, millis = divmod(end_ms, 1000)
            (ROOT / "audio" / f"{key}.vtt").write_text(
                f"WEBVTT\n\n00:00:00.000 --> 00:00:{seconds:02d}.{millis:03d}\n{row['reference'].lower()}\n"
            )
            cards.append(f"""<article id="clip-{key}"><h3>{escape(row['category'].capitalize())} · {key}</h3>
<audio controls preload="none" aria-label="Read speech, {key}" src="audio/{key}.flac"><track kind="captions" srclang="en" label="English" src="audio/{key}.vtt"></audio>
<dl><dt>Reference</dt><dd>{escape(row['reference'].lower())}</dd>
<dt>Original audio · {raw} word edits</dt><dd>{escape(row['raw'])}</dd>
<dt>Prepared audio · {prepared} word edits</dt><dd>{escape(row['prepared'])}</dd></dl></article>""")
        summaries.append(f"<tr><th>{subset}</th><td>{reference_count}</td><td>{raw_edits} ({raw_edits/reference_count:.1%})</td><td>{prepared_edits} ({prepared_edits/reference_count:.1%})</td></tr>")
    output = """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Aside · Speech evaluation</title>
<style>html{color-scheme:light dark}body{font:17px/1.55 system-ui,sans-serif;max-width:48rem;margin:auto;padding:2rem 1rem}h1{line-height:1.1}h2{margin-top:2rem}a{color:LinkText}td,th{padding:.4rem;text-align:left;border-bottom:1px solid GrayText}article{padding-block:1rem;border-top:1px solid GrayText}audio{max-width:100%}dt{font-weight:650}dd{margin:0 0 .7rem}table{border-collapse:collapse}</style>
<main><h1>Can audio preparation change what was said?</h1><p>Listen to 18 LibriSpeech readers. The same local Parakeet recognizer transcribed each recording twice, once from the original audio and once after Aside shortened pauses and masked predicted fillers.</p>
<p><a href="#clip-2428-83699-0000">Hear a regression</a> · The original preserves “in my chambers.” The prepared version says “at my chambers.”</p>
<table><caption>Word edits and word error rate</caption><thead><tr><th>Set</th><th>Reference words</th><th>Original</th><th>Prepared</th></tr></thead><tbody>""" + "".join(summaries) + """</tbody></table>
<p>The first six clips cover names, numbers and negation. Twelve longer passages form a separate stress set. Word error rate counts substitutions, insertions and deletions after case and punctuation normalization. Digits and spelled-out numbers are distinct. These are read-English recordings. This comparison measures acoustic preparation with Parakeet v3; the optional language-model writer is outside the experiment.</p>
<p><a href="https://github.com/EssenceSentry/aside-macos/tree/main/docs/speech-evaluation">Method, source data and reproduction</a></p><h2>Listen and compare</h2>""" + "".join(cards) + """<footer><p>Audio and reference text: LibriSpeech by V. Panayotov, G. Chen, D. Povey and S. Khudanpur, from LibriVox readings. <a href="https://www.openslr.org/12/">Corpus</a> · <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a>. Original FLAC clips are unmodified.</p></footer></main></html>"""
    (ROOT / "index.html").write_text(output)
    print(" ".join(re.sub("<[^>]+>", " ", row) for row in summaries))


if __name__ == "__main__":
    report()

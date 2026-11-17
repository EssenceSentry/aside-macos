"""Aside's isolated local voice narration worker. JSON-lines protocol on stdout.

Only `prepare` uses the network, to fetch pinned public model artifacts. Synthesis
uses local files with hub/transformers offline mode, never a hosted inference API.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import time
import traceback
import wave

TTS_REPO = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
TTS_REVISION = "e7dd0585652209fa0d7783659aad4e8a324de11c"
ASR_REPO = "mlx-community/whisper-small-mlx"
ASR_REVISION = "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e"
TTS_DIRECTORY = "qwen3-tts-1.7b-base-8bit"
ASR_DIRECTORY = "whisper-small"
CURRENT_STAGE = "starting"


def stage(name: str) -> None:
    global CURRENT_STAGE
    CURRENT_STAGE = name


def failure_details(error: Exception) -> dict:
    """Technical locations only: never source lines, transcript or audio contents."""
    return {
        "stage": CURRENT_STAGE,
        "errno": getattr(error, "errno", None),
        "frames": [
            {
                "file": Path(frame.filename).name,
                "function": frame.name,
                "line": frame.lineno,
            }
            for frame in traceback.extract_tb(error.__traceback__)[-8:]
        ],
    }


def emit(event: str, **values) -> None:
    print(json.dumps({"event": event, **values}, ensure_ascii=False), flush=True)


def private_json(path: Path, data: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, filename = tempfile.mkstemp(
        dir=path.parent, prefix=".narration-", suffix=".json"
    )
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, ensure_ascii=False)
        os.replace(filename, path)
    finally:
        Path(filename).unlink(missing_ok=True)


def split_text(text: str, limit: int = 420) -> list[str]:
    """Bound inference memory without rewriting, filtering or reviewing words."""
    normalized = " ".join(text.split())
    if not normalized:
        raise ValueError("There is no corrected transcript to narrate")
    sentences = re.split(r"(?<=[.!?。！？])\s+", normalized)
    chunks: list[str] = []
    current = ""
    for sentence in sentences:
        for word in sentence.split():
            if current and len(current) + len(word) + 1 > limit:
                chunks.append(current)
                current = ""
            current = f"{current} {word}".strip()
        if len(current) >= limit * 0.55:
            chunks.append(current)
            current = ""
    if current:
        chunks.append(current)
    return chunks


def paths(root: Path) -> tuple[Path, Path]:
    return root / "models" / TTS_DIRECTORY, root / "models" / ASR_DIRECTORY


def status(root: Path) -> dict:
    tts, asr = paths(root)
    ready = (
        (tts / "config.json").is_file()
        and any(tts.glob("*.safetensors"))
        and (tts / "speech_tokenizer" / "config.json").is_file()
        and any((tts / "speech_tokenizer").glob("*.safetensors"))
        and (asr / "config.json").is_file()
        and (any(asr.glob("*.safetensors")) or (asr / "weights.npz").is_file())
    )
    return {
        "ready": ready,
        "modelID": TTS_REPO,
        "message": (
            "Local narration is ready"
            if ready
            else "Download the local narration models first"
        ),
    }


def prepare(root: Path) -> dict:
    from huggingface_hub import snapshot_download

    for repo, revision, destination in [
        (TTS_REPO, TTS_REVISION, paths(root)[0]),
        (ASR_REPO, ASR_REVISION, paths(root)[1]),
    ]:
        emit("progress", message="Downloading " + repo.rsplit("/", 1)[-1])
        snapshot_download(
            repo,
            revision=revision,
            local_dir=destination,
            ignore_patterns=["*.md", ".gitattributes"],
        )
    result = status(root)
    if not result["ready"]:
        raise RuntimeError("The local narration model download is incomplete")
    private_json(root / "ready.json", result)
    return result


def reference_clip(source: Path, directory: Path) -> tuple[Path, object]:
    import numpy as np
    from scipy.io import wavfile
    from scipy.signal import resample_poly
    from math import gcd

    rate, data = wavfile.read(source)
    if data.dtype.kind in "iu":
        data = data.astype(np.float32) / max(
            abs(np.iinfo(data.dtype).min), np.iinfo(data.dtype).max
        )
    else:
        data = data.astype(np.float32)
    if data.ndim == 2:
        data = data.mean(axis=1)
    if data.ndim != 1 or not len(data) or not np.isfinite(data).all():
        raise ValueError("The saved voice sample is not valid mono or stereo audio")
    if len(data) / rate < 3:
        raise ValueError(
            "Use a saved voice sample with at least three seconds of speech"
        )
    hop = max(1, int(rate * 0.02))
    frames = len(data) // hop
    rms = np.sqrt(np.mean(data[: frames * hop].reshape(frames, hop) ** 2, axis=1))
    active = np.flatnonzero(rms > max(0.004, float(np.max(rms)) * 0.06))
    if not len(active):
        raise ValueError("The saved voice sample is silent")
    start = max(0, int(active[0] * hop) - int(0.15 * rate))
    end = min(len(data), start + int(12 * rate))
    if end < len(data):
        # End near a low-energy boundary, using the exact resulting clip for ASR.
        lo, hi = int((start + 8 * rate) / hop), int(end / hop)
        if hi > lo:
            end = int((lo + np.argmin(rms[lo:hi])) * hop)
    data = data[start:end]
    if len(data) / rate < 3:
        raise ValueError(
            "Use a saved voice sample with at least three seconds of speech"
        )
    common = gcd(rate, 16000)
    data16 = resample_poly(data, 16000 // common, rate // common).astype(np.float32)
    clip = directory / "reference.wav"
    wavfile.write(clip, 16000, np.clip(data16 * 32767, -32768, 32767).astype(np.int16))
    clip.chmod(0o600)
    return clip, data16


def synthesize(root: Path, request: dict) -> dict:
    stage("importing local runtime")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    import gc
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    # Bound allocator reuse and fail technically before a long decoder can consume
    # most of a 24 GB Mac and force the operating system into heavy disk swap.
    mx.set_cache_limit(256 * 1024 * 1024)
    mx.set_memory_limit(10 * 1024 * 1024 * 1024)
    started = time.perf_counter()
    chunks = split_text(request["text"])
    language = request.get("language") or "English"
    language = {"en": "English", "es": "Spanish", "automatic": "auto"}.get(
        language.lower(), language
    )
    if language.lower() not in {"english", "spanish", "auto"}:
        raise ValueError("Choose English, Spanish or auto for narration")
    source, output = Path(request["voiceSampleURL"]), Path(request["outputURL"])
    if source.resolve() == output.resolve():
        raise ValueError("Narration cannot overwrite the saved voice sample")
    if not status(root)["ready"]:
        raise ValueError("Prepare the local narration models first")
    stage("creating private output")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(
        dir=output.parent, prefix=".aside-narration-", suffix=".wav"
    )
    os.close(fd)
    try:
        with tempfile.TemporaryDirectory(dir=root, prefix="reference-") as work:
            stage("preparing reference audio")
            clip, reference = reference_clip(source, Path(work))
            speaker_only = bool(request.get("speakerOnly", False))
            ref_text = None
            if not speaker_only:
                cache_key = hashlib.sha256(
                    clip.read_bytes() + ASR_REVISION.encode()
                ).hexdigest()
                cached = root / "reference-text" / (cache_key + ".json")
                emit("progress", message="Reading the saved voice sample locally")
                if cached.is_file():
                    ref_text = json.loads(cached.read_text())["text"]
                else:
                    # Speaker-only cloning has no lexical reference input and
                    # must not import or run a reference transcription model.
                    import mlx_whisper
                    from mlx_whisper.transcribe import ModelHolder

                    stage("transcribing reference locally")
                    with contextlib.redirect_stdout(sys.stderr):
                        recognized = mlx_whisper.transcribe(
                            reference,
                            path_or_hf_repo=str(paths(root)[1]),
                            temperature=0.0,
                            condition_on_previous_text=False,
                            verbose=None,
                        )
                    ref_text = recognized["text"].strip()
                    if not ref_text:
                        raise ValueError(
                            "Could not hear speech in the saved voice sample"
                        )
                    private_json(
                        cached,
                        {"text": ref_text, "model": ASR_REPO, "revision": ASR_REVISION},
                    )
                    ModelHolder.model = None
            gc.collect()
            mx.clear_cache()
            stage("loading local voice model")
            emit("progress", message="Loading the local voice model")
            with contextlib.redirect_stdout(sys.stderr):
                model = load_model(paths(root)[0])
            load_seconds = time.perf_counter() - started
            mx.random.seed(int(request.get("seed", 42)))
            sample_count = 0
            generation_started = time.perf_counter()
            with wave.open(temporary, "wb") as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(model.sample_rate)
                for index, text in enumerate(chunks):
                    stage(f"generating narration part {index + 1} of {len(chunks)}")
                    part_samples = 0
                    part_tokens = 0
                    emit(
                        "progress",
                        message=f"Narrating part {index + 1} of {len(chunks)}",
                        completed=index,
                        total=len(chunks),
                    )
                    with contextlib.redirect_stdout(sys.stderr):
                        results = model.generate(
                            text=text,
                            ref_audio=str(clip),
                            ref_text=ref_text,
                            lang_code=language,
                            max_tokens=1536,
                            temperature=0.7,
                            verbose=False,
                            stream=True,
                            streaming_interval=2.0,
                        )
                        for result in results:
                            audio = np.asarray(result.audio, dtype=np.float32).reshape(
                                -1
                            )
                            if not len(audio) or not np.isfinite(audio).all():
                                raise RuntimeError(
                                    "The local voice model returned invalid audio"
                                )
                            part_tokens += result.token_count
                            if part_tokens >= 1536:
                                raise RuntimeError(
                                    "A narration part exceeded the model's audio limit; retry with shorter text"
                                )
                            stage(
                                f"writing narration part {index + 1} of {len(chunks)}"
                            )
                            stream.writeframes(
                                np.clip(audio * 32767, -32768, 32767)
                                .astype("<i2")
                                .tobytes()
                            )
                            sample_count += len(audio)
                            part_samples += len(audio)
                            stage(
                                f"generating narration part {index + 1} of {len(chunks)}"
                            )
                    if not part_samples:
                        raise RuntimeError(
                            "The local voice model returned an empty narration part"
                        )
                    if index + 1 < len(chunks):
                        pause = int(model.sample_rate * 0.18)
                        stream.writeframes(b"\0\0" * pause)
                        sample_count += pause
                    mx.clear_cache()
            if not sample_count:
                raise RuntimeError("The local voice model did not generate audio")
            generation_seconds = time.perf_counter() - generation_started
            elapsed = time.perf_counter() - started
            result = {
                "outputURL": str(output),
                "duration": sample_count / model.sample_rate,
                "elapsedSeconds": elapsed,
                "generationSeconds": generation_seconds,
                "preparationSeconds": load_seconds,
                "sampleRate": model.sample_rate,
                "parts": len(chunks),
                "modelID": TTS_REPO,
                "language": language,
                "peakMemoryGB": mx.get_peak_memory() / 1e9,
                "runtimeVersion": importlib.metadata.version("mlx-audio"),
                "conditioning": "speaker-only" if speaker_only else "reference-text",
                "seed": int(request.get("seed", 42)),
            }
            stage("publishing completed WAV")
            os.replace(temporary, output)
            return result
    finally:
        Path(temporary).unlink(missing_ok=True)


def stop_requested(_signal, _frame) -> None:
    raise KeyboardInterrupt


def main() -> None:
    os.umask(0o077)
    signal.signal(signal.SIGTERM, stop_requested)
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "status", "synthesize"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--request", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "synthesize":
            if not args.request:
                raise ValueError("Synthesis requires a private JSON request file")
            result = synthesize(args.root, json.loads(args.request.read_text()))
        elif args.command == "prepare":
            result = prepare(args.root)
        else:
            result = status(args.root)
        emit("result", **result)
    except Exception as error:
        emit("error", message=f"{CURRENT_STAGE}: {error}", **failure_details(error))
        raise SystemExit(1)


if __name__ == "__main__":
    main()

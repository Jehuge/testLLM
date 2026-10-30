"""Offline, one-shot speaker comparison. JSON in, JSON out; no network or server."""
import json
import sys
import time
from pathlib import Path


def prepare_audio(path):
    import numpy as np
    import soundfile as sf

    with sf.SoundFile(path) as source:
        if source.frames / source.samplerate > 61:
            raise ValueError("音频超过 60 秒，请截取一段只有一个人讲话的片段。")
        samples = source.read(dtype="float32", always_2d=True).mean(axis=1)
        rate = source.samplerate
    if not len(samples) or not np.isfinite(samples).all():
        raise ValueError("音频为空或包含无效采样，请重新录音。")
    if len(samples) / rate < 1:
        raise ValueError("录音不足 1 秒，建议录制 5–15 秒清晰讲话。")
    # Remove leading/trailing silence without joining or altering speech segments.
    size = max(1, int(rate * 0.02))
    count = len(samples) // size
    frames = samples[:count * size].reshape(count, size)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    cutoff = max(0.002, float(np.max(rms)) * 0.035)
    voiced = np.flatnonzero(rms > cutoff)
    if len(voiced) * 0.02 < 0.6:
        raise ValueError("没有检测到足够的有效声音。请检查录音来源、系统音量和权限。")
    start = max(0, (int(voiced[0]) - 5) * size)
    end = min(len(samples), (int(voiced[-1]) + 6) * size)
    samples = np.ascontiguousarray(samples[start:end])
    if len(samples) / rate < 1:
        raise ValueError("有效音频过短，建议录制 5–15 秒清晰讲话。")
    return samples, rate


def compare(request):
    import numpy as np
    import sherpa_onnx

    started = time.perf_counter()
    model = Path(request["model"])
    if not model.is_file():
        raise ValueError("未找到声纹模型，请重新运行安装脚本。")
    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(model), num_threads=2, provider="cpu"
    )
    if not config.validate():
        raise ValueError("声纹模型配置无效，请重新安装模型。")
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
    embeddings, durations = [], []
    for name in ("audio_a", "audio_b"):
        samples, rate = prepare_audio(request[name])
        stream = extractor.create_stream()
        stream.accept_waveform(sample_rate=rate, waveform=samples)
        stream.input_finished()
        if not extractor.is_ready(stream):
            raise ValueError("有效音频过短，无法提取声纹。")
        embedding = np.array(extractor.compute(stream), dtype=np.float32)
        norm = float(np.linalg.norm(embedding))
        if not np.isfinite(embedding).all() or norm < 1e-9:
            raise ValueError("无法提取有效声纹，请重新录音。")
        embeddings.append(embedding / norm)
        durations.append(round(len(samples) / rate, 2))
    score = float(np.clip(np.dot(*embeddings), -1, 1))
    return {
        "ok": True, "score": round(score, 6), "durations": durations,
        "elapsed": round(time.perf_counter() - started, 3),
        "model": "ERes2NetV2 中文 · 本地 CPU",
    }


if __name__ == "__main__":
    try:
        print(json.dumps(compare(json.load(sys.stdin)), ensure_ascii=False))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        sys.exit(1)

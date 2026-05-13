"""
SayIt Pipeline v2
YouTube → Whisper（中文）→ Gemma（校正+翻譯+分段）→ Google TTS → HTML 播放器
"""

import os, sys, json, re, subprocess, urllib.request, urllib.error, base64, time, tempfile
from dotenv import load_dotenv
from groq import Groq

load_dotenv()

GROQ_API_KEY    = os.getenv("GROQ_API_KEY")
GEMINI_API_KEY  = os.getenv("GEMINI_API_KEY")
GOOGLE_TTS_KEY  = os.getenv("GOOGLE_TTS_API_KEY")

# 若有設定 YOUTUBE_COOKIES_B64，解碼寫入暫存檔供 yt-dlp 使用
_COOKIES_FILE = None
_cookies_b64 = os.getenv("YOUTUBE_COOKIES_B64")
if _cookies_b64:
    _tf = tempfile.NamedTemporaryFile(mode="wb", suffix=".txt", delete=False)
    _tf.write(base64.b64decode(_cookies_b64))
    _tf.close()
    _COOKIES_FILE = _tf.name
YOUTUBE_URL     = "https://www.youtube.com/watch?v=W3usaA6UwyI"
OUTPUT_DIR      = "tmp/sayit/default"
GROQ_MAX_BYTES  = 24 * 1024 * 1024
CHUNK_SECONDS   = 20 * 60
TTS_VOICE       = "en-US-Wavenet-D"
MODEL_PRIMARY   = "gemini-3-flash-preview"
MODEL_FALLBACK  = "gemini-3.1-flash-lite"
THINKING_MODELS = {MODEL_PRIMARY}


def _gemma_text(result):
    """從 Gemini 回應中只取非思考的 part（thought != True）"""
    parts = result["candidates"][0]["content"]["parts"]
    return "".join(p["text"] for p in parts if not p.get("thought", False))


def _cache(name):
    return os.path.join(OUTPUT_DIR, f"_cache_{name}.json")


def _load_cache(name):
    path = _cache(name)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return None


def _save_cache(name, data):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(_cache(name), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _merge_short_fragments(segs, min_len=5):
    """把 Whisper 切出的碎片句（≤min_len 字）合併到前一句"""
    result = []
    for seg in segs:
        text = seg["text"].strip()
        if result and len(text) <= min_len:
            result[-1] = dict(result[-1], text=result[-1]["text"] + text)
        else:
            result.append(dict(seg))
    return result


# ── 字幕擷取（優先於下載）────────────────────────────────────────────────────

def _get_video_title(url):
    oembed_url = f"https://www.youtube.com/oembed?url={url}&format=json"
    try:
        with urllib.request.urlopen(oembed_url, timeout=10) as resp:
            return json.loads(resp.read())["title"]
    except Exception:
        return "video"


def _transcribe_via_captions(vid_id):
    """嘗試用 YouTube 自動字幕取得逐字稿，不可用則回傳 None"""
    cached = _load_cache("whisper")
    if cached:
        print(f"  ⚡ 快取命中：{len(cached)} 句")
        return cached

    try:
        from youtube_transcript_api import YouTubeTranscriptApi
        entries = YouTubeTranscriptApi().fetch(
            vid_id, languages=["zh-TW", "zh-Hant", "zh-Hans", "zh"]
        )
        segs = [
            {"start": e.start, "end": e.start + e.duration, "text": e.text.strip()}
            for e in entries if e.text.strip()
        ]
        print(f"  ✅ 字幕擷取成功：{len(segs)} 句")
        _save_cache("whisper", segs)
        return segs
    except Exception as e:
        print(f"  ⚠️  字幕不可用：{e}")
        return None


# ── 步驟 1：下載音訊 ─────────────────────────────────────────────────────────

def download_audio(url):
    print("步驟 1：下載 YouTube 音訊")
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    cached = _load_cache("download")
    if cached:
        paths = cached["paths"]
        if all(os.path.exists(p) for p in paths):
            print(f"  ⚡ 快取命中：{cached['title']}")
            return paths, cached["title"]

    # 先用 yt-dlp 取得標題
    YT_ARGS = ["--extractor-args", "youtube:player_client=android", "--no-playlist"]
    if _COOKIES_FILE:
        YT_ARGS += ["--cookies", _COOKIES_FILE]
    info = json.loads(subprocess.check_output(
        ["yt-dlp", "--dump-json"] + YT_ARGS + [url], text=True
    ))
    title = info.get("title", "video")
    duration = info.get("duration", 0)
    print(f"  標題：{title}")

    path = os.path.join(OUTPUT_DIR, "audio_orig.mp3")
    subprocess.run(
        ["yt-dlp", "-f", "bestaudio", "-x", "--audio-format", "mp3",
         "-o", path] + YT_ARGS + [url],
        check=True
    )

    size = os.path.getsize(path)
    print(f"  ✅ 下載完成（{size/1024/1024:.1f} MB）")

    if size > GROQ_MAX_BYTES:
        print(f"  ⚠️  超過 24MB，切成 {CHUNK_SECONDS//60} 分鐘段落")
        paths = _split_audio(path, duration)
    else:
        paths = [path]

    _save_cache("download", {"paths": paths, "title": title})
    return paths, title


def _split_audio(path, total_sec):
    chunks, start, idx = [], 0, 0
    while start < total_sec:
        end = min(start + CHUNK_SECONDS, total_sec)
        out = os.path.join(OUTPUT_DIR, f"chunk_{idx:02d}.mp3")
        subprocess.run(["ffmpeg", "-y", "-i", path,
                        "-ss", str(start), "-to", str(end),
                        "-acodec", "mp3", "-ab", "64k", out, "-loglevel", "error"])
        chunks.append(out)
        start, idx = end, idx + 1
    return chunks


# ── 步驟 2：Groq Whisper 轉錄 ────────────────────────────────────────────────

def transcribe(audio_paths):
    print(f"\n步驟 2：Groq Whisper 轉錄（{len(audio_paths)} 個檔案）")

    cached = _load_cache("whisper")
    if cached:
        print(f"  ⚡ 快取命中：{len(cached)} 句")
        return cached

    client = Groq(api_key=GROQ_API_KEY)
    all_segs, offset = [], 0.0

    for i, path in enumerate(audio_paths):
        fname = os.path.basename(path)
        print(f"  轉錄 {i+1}/{len(audio_paths)}：{fname}")
        with open(path, "rb") as f:
            result = client.audio.transcriptions.create(
                file=(fname, f), model="whisper-large-v3",
                language="zh", response_format="verbose_json",
                timestamp_granularities=["segment"]
            )
        segs = getattr(result, "segments", []) or []
        for seg in segs:
            all_segs.append({
                "start": seg["start"] + offset,
                "end":   seg["end"]   + offset,
                "text":  seg["text"].strip()
            })
        if segs:
            offset += segs[-1]["end"]

    all_segs = [s for s in all_segs if s["text"]]
    print(f"  ✅ 共 {len(all_segs)} 句")
    _save_cache("whisper", all_segs)
    return all_segs


# ── 步驟 3：Gemma 校正 + 翻譯 + 分段 ────────────────────────────────────────

def _gemini_post(payload, timeout=300):
    def _call(model):
        p = payload
        if model not in THINKING_MODELS:
            gc = p.get("generationConfig", {})
            if "thinkingConfig" in gc:
                p = {**p, "generationConfig": {k: v for k, v in gc.items() if k != "thinkingConfig"}}
        url  = (f"https://generativelanguage.googleapis.com/v1beta/"
                f"models/{model}:generateContent?key={GEMINI_API_KEY}")
        data = json.dumps(p).encode("utf-8")
        req  = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    raise  # quota — let caller decide whether to fallback
                elif e.code in (500, 503) and attempt < 2:
                    wait = 10 * (attempt + 1)
                    print(f"  ⚠️  HTTP {e.code}，{wait}s 後重試（{attempt+1}/2）...")
                    time.sleep(wait)
                else:
                    raise
            except (TimeoutError, OSError):
                if attempt < 2:
                    wait = 15 * (attempt + 1)
                    print(f"  ⚠️  Timeout，{wait}s 後重試（{attempt+1}/2）...")
                    time.sleep(wait)
                else:
                    raise

    try:
        return _call(MODEL_PRIMARY)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            print(f"  ⚠️  {MODEL_PRIMARY} quota 耗盡，切換 {MODEL_FALLBACK}...")
            return _call(MODEL_FALLBACK)
        raise


def _extract_json(raw, anchor):
    """找 anchor 字串所在的 JSON 物件，回傳 json_str"""
    match = re.search(re.escape(anchor), raw)
    if not match:
        raise ValueError(f"找不到 JSON anchor '{anchor}'：{raw[:300]}")
    # 往前找開頭的 {
    start = raw.rfind('{', 0, match.start() + 1)
    if start == -1:
        raise ValueError("找不到 JSON 開頭")
    depth, json_str = 0, ""
    for i, ch in enumerate(raw[start:], start):
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return raw[start:i+1]
    raise ValueError("JSON 括號未匹配")


def _gemma_segment(title, sentences):
    """Step A：送全部句子，只要 Gemma 回傳語意分段的 index（輸出極小）"""
    n = len(sentences)
    numbered = "\n".join(f"{i+1}. {s}" for i, s in enumerate(sentences))

    prompt = f"""Segment this Chinese YouTube transcript into topic-based sections.
Video: "{title}"
Total sentences: {n}

Rules:
- Split ONLY at major topic shifts
- Target 2.5–3 minutes per segment (~70–90 sentences each)
- Prefer fewer, longer segments — avoid over-splitting
- Last segment must end at sentence {n}

Sentences:
{numbered}

Return ONLY valid JSON:
{{"segments": [{{"start": 1, "end": 80}}, {{"start": 81, "end": {n}}}]}}
(1-based sentence numbers)"""

    result = _gemini_post({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.1,
            "maxOutputTokens": 2048,
            "thinkingConfig": {"thinkingBudget": 0}
        }
    }, timeout=120)

    raw = _gemma_text(result)
    try:
        segs = json.loads(_extract_json(raw, '"segments"'))["segments"]
    except (ValueError, KeyError) as e:
        print(f"  ⚠️  分段解析失敗：{e}\n  raw: {raw[:500]}")
        raise

    boundaries = [(seg["start"] - 1, seg["end"]) for seg in segs]  # 0-based start, exclusive end
    # 確保最後一段覆蓋到底
    if boundaries and boundaries[-1][1] < n:
        boundaries[-1] = (boundaries[-1][0], n)
    return boundaries


def _gemma_translate(title, sentences):
    """Step B：校正中文 + 翻譯英文，回傳 [{zh, en}, ...] 列表"""
    numbered = "\n".join(f"{i+1}. {s}" for i, s in enumerate(sentences))

    prompt = f"""Correct and translate Chinese sentences from a YouTube video: "{title}"

STEP 1 — Correct & punctuate Chinese:
- Fix speech recognition errors
- Add proper punctuation: 。，？！

STEP 2 — Translate to English:
- Natural translation
- Add punctuation: . ? ! ,
- Skip channel intro/outro (greetings, subscribe reminders, "see you next episode")

Sentences:
{numbered}

Return ONLY valid JSON:
{{"sentences": [{{"zh": "校正後中文。", "en": "English translation."}}]}}"""

    result = _gemini_post({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.3,
            "maxOutputTokens": 8192,
            "thinkingConfig": {"thinkingBudget": 0}
        }
    })

    raw = _gemma_text(result)
    try:
        return json.loads(_extract_json(raw, '"sentences"'))["sentences"]
    except (ValueError, KeyError) as e:
        print(f"  ⚠️  翻譯解析失敗：{e}\n  raw tail: {raw[-300:]}")
        raise


def process_with_gemma(title, whisper_segs):
    print(f"\n步驟 3：Gemma 校正、分段、翻譯")

    cached = _load_cache("gemma")
    if cached:
        total = sum(len(sg["sentences"]) for sg in cached)
        print(f"  ⚡ 快取命中：{len(cached)} 段，共 {total} 句")
        return cached

    whisper_segs = _merge_short_fragments(whisper_segs)
    sentences = [s["text"] for s in whisper_segs if s["text"]]
    print(f"  共 {len(sentences)} 句（合併碎片後）")

    # Step A：分段（輸出只有 index，不截斷）
    print(f"  Step A：語意分段...")
    boundaries = _gemma_segment(title, sentences)
    print(f"  → {len(boundaries)} 段：{[(s, e) for s, e in boundaries]}")

    # Step B：逐段校正 + 翻譯（每段各自呼叫，輸出有限）
    segments = []
    for i, (start, end) in enumerate(boundaries):
        batch = sentences[start:end]
        print(f"  Step B 段落 {i+1}：翻譯 {len(batch)} 句...")
        sents = _gemma_translate(title, batch)
        segments.append({"sentences": sents})

    total_sents = sum(len(sg["sentences"]) for sg in segments)
    print(f"  ✅ {len(segments)} 段，共 {total_sents} 句")
    _save_cache("gemma", segments)
    return segments
# ── 步驟 4：生成摘要 ─────────────────────────────────────────────────────────

def generate_summary(title, segments):
    cached = _load_cache("summary")
    if cached:
        print("  ⚡ 摘要快取命中")
        return cached

    print("\n步驟 4：Gemini 生成摘要...")
    all_zh = "\n".join(
        s["zh"] for seg in segments for s in seg["sentences"]
    )
    prompt = f"""你是一位內容整理專家。請根據以下影片字幕，生成一份繁體中文結構化摘要。

影片標題：{title}

字幕內容：
{all_zh}

請直接回傳 JSON，不要有其他文字：
{{
  "overview": "100-200字的影片整體概述",
  "topics": [
    {{
      "title": "主題標題",
      "points": ["重點一", "重點二", "重點三"]
    }}
  ]
}}"""

    result = _gemini_post({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.3,
            "maxOutputTokens": 4096,
            "thinkingConfig": {"thinkingBudget": 0}
        }
    })
    raw = _gemma_text(result)
    summary = json.loads(_extract_json(raw, '"overview"'))
    print(f"  ✅ 摘要生成完成：{len(summary.get('topics', []))} 個主題")
    _save_cache("summary", summary)
    return summary


# ── 步驟 5：Google TTS（每段一個 mp3 + 逐句時間戳）──────────────────────────

TTS_SSML_LIMIT = 4500   # Google TTS 上限 5000 字元，留安全餘量


def _ssml_for_sents(sents, start_idx=0, leading_break=True):
    opening = '<speak><break time="600ms"/>' if leading_break else '<speak>'
    parts = [opening]
    for j, s in enumerate(sents):
        en = s["en"].rstrip()
        strength = "medium" if en.endswith((".", "?", "!", "…")) else "weak"
        parts.append(f'<mark name="s{start_idx + j}"/>{en}<break strength="{strength}"/>')
    parts.append("</speak>")
    return "".join(parts)


def _tts_api_call(ssml, tts_url):
    payload = {
        "input": {"ssml": ssml},
        "voice": {"languageCode": "en-US", "name": TTS_VOICE},
        "audioConfig": {"audioEncoding": "MP3", "speakingRate": 0.95},
        "enableTimePointing": ["SSML_MARK"]
    }
    data = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(tts_url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.loads(resp.read().decode("utf-8"))
    audio_bytes = base64.b64decode(result["audioContent"])
    tps = {tp["markName"]: tp["timeSeconds"] for tp in result.get("timepoints", [])}
    return audio_bytes, tps


def _mp3_duration(path):
    r = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", path],
        capture_output=True, text=True
    )
    return float(json.loads(r.stdout)["format"]["duration"])


def _split_into_ssml_batches(sents):
    """把句子列表依 SSML 字元限制切成多批，每批不超過 TTS_SSML_LIMIT"""
    batches, batch, cur_len = [], [], len('<speak><break time="600ms"/></speak>')
    for s in sents:
        entry_len = len(f'<mark name="s000"/>{s["en"]}<break strength="weak"/>')
        if batch and cur_len + entry_len > TTS_SSML_LIMIT:
            batches.append(batch)
            batch  = [s]
            cur_len = len('<speak><break time="600ms"/>') + entry_len + len('</speak>')
        else:
            batch.append(s)
            cur_len += entry_len
    if batch:
        batches.append(batch)
    return batches


def tts_segments(segments):
    print(f"\n步驟 5：Google TTS 生成語音")

    cached = _load_cache("tts")
    if cached:
        all_exist = all(
            os.path.exists(os.path.join(OUTPUT_DIR, seg.get("audio_path", "")))
            for seg in cached
        )
        if all_exist:
            print(f"  ⚡ 快取命中：{len(cached)} 個音訊檔")
            return cached

    audio_dir = os.path.join(OUTPUT_DIR, "audio")
    os.makedirs(audio_dir, exist_ok=True)
    tts_url = f"https://texttospeech.googleapis.com/v1beta1/text:synthesize?key={GOOGLE_TTS_KEY}"

    for i, seg in enumerate(segments):
        audio_path = os.path.join(audio_dir, f"segment_{i:02d}.mp3")

        if os.path.exists(audio_path) and all("tts_start" in s for s in seg["sentences"]):
            seg["audio_path"] = os.path.relpath(audio_path, OUTPUT_DIR)
            size_kb = os.path.getsize(audio_path) // 1024
            print(f"  ⚡ 段落 {i+1}：已有音訊（{size_kb} KB），略過")
            continue

        sents   = seg["sentences"]
        batches = _split_into_ssml_batches(sents)

        if len(batches) == 1:
            # 單批：直接寫入最終檔案
            ssml = _ssml_for_sents(sents)
            audio_bytes, tps = _tts_api_call(ssml, tts_url)
            with open(audio_path, "wb") as f:
                f.write(audio_bytes)
            for j, s in enumerate(sents):
                s["tts_start"] = tps.get(f"s{j}", 0.0)
        else:
            # 多批：各自 TTS → ffmpeg 合併 → 時間戳加偏移
            print(f"    (SSML 過長，分 {len(batches)} 批合併)")
            chunk_paths, chunk_tps_list = [], []
            global_idx = 0
            for bi, batch in enumerate(batches):
                ssml = _ssml_for_sents(batch, global_idx, leading_break=(bi == 0))
                audio_bytes, tps = _tts_api_call(ssml, tts_url)
                cp = audio_path.replace(".mp3", f"_c{bi}.mp3")
                with open(cp, "wb") as f:
                    f.write(audio_bytes)
                chunk_paths.append(cp)
                chunk_tps_list.append((tps, global_idx, len(batch)))
                global_idx += len(batch)

            # ffmpeg concat
            list_path = audio_path.replace(".mp3", "_list.txt")
            with open(list_path, "w") as f:
                for cp in chunk_paths:
                    f.write(f"file '{os.path.abspath(cp)}'\n")
            subprocess.run(["ffmpeg", "-y", "-f", "concat", "-safe", "0",
                            "-i", list_path, "-c", "copy", audio_path, "-loglevel", "error"])
            os.remove(list_path)

            # 計算時間戳偏移
            offset, batch_start = 0.0, 0
            for bi, (batch, cp) in enumerate(zip(batches, chunk_paths)):
                tps, start_idx, _ = chunk_tps_list[bi]
                for j, s in enumerate(batch):
                    s["tts_start"] = tps.get(f"s{start_idx + j}", 0.0) + offset
                offset += _mp3_duration(cp)
                os.remove(cp)

        seg["audio_path"] = os.path.relpath(audio_path, OUTPUT_DIR)
        size_kb = os.path.getsize(audio_path) // 1024
        print(f"  ✅ 段落 {i+1}：{len(sents)} 句，{size_kb} KB")

    _save_cache("tts", segments)
    return segments


# ── 步驟 6：產生 HTML 播放器 ──────────────────────────────────────────────────

def generate_html(title, segments, summary=None):
    data_json    = json.dumps({"title": title, "segments": segments}, ensure_ascii=False)
    summary_json = json.dumps(summary or {}, ensure_ascii=False)

    html = f"""<!DOCTYPE html>
<html lang="zh-Hant">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SayIt</title>
<style>
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
       background: #0f0f1a; color: #e8e8f0; min-height: 100vh; padding: 24px 16px; }}
.container {{ max-width: 780px; margin: 0 auto; }}

/* Header */
.header {{ margin-bottom: 24px; }}
h1 {{ font-size: 1.25em; color: #a0a8ff; line-height: 1.5; margin-bottom: 12px; }}
.mode-bar {{ display: flex; gap: 8px; }}
.mode-btn {{ padding: 8px 20px; border-radius: 20px; border: 1px solid #3a3a5a; background: transparent;
            color: #888; cursor: pointer; font-size: 0.9em; transition: all 0.2s; }}
.mode-btn.active {{ background: #2e2060; border-color: #7b8cff; color: #fff; }}

/* Segment */
.segment {{ background: #16162a; border-radius: 14px; padding: 20px; margin-bottom: 16px;
            border: 1px solid #2a2a4a; }}
.seg-nav {{ display: flex; align-items: center; justify-content: space-between;
            margin-bottom: 12px; font-size: 0.8em; color: #555; }}
audio {{ width: 100%; height: 38px; accent-color: #7b8cff; }}
.audio-row {{ margin-bottom: 14px; }}
.rewind-btns {{ display: flex; gap: 8px; margin-top: 6px; }}
.rewind-btns button {{ padding: 5px 14px; border-radius: 16px; border: 1px solid #3a3a5a;
                       background: #1a1a2e; color: #9090c0; cursor: pointer; font-size: 0.85em;
                       transition: all 0.15s; }}
.rewind-btns button:hover {{ background: #2e2060; color: #fff; border-color: #7b8cff; }}

/* Sentences */
.sent-pair {{ padding: 8px 10px; margin: 3px 0; border-radius: 8px; transition: background 0.15s;
              border-left: 3px solid transparent; cursor: pointer; }}
.sent-pair:hover {{ background: #1a1a30; }}
.sent-pair.active {{ background: #1e1a3a; border-left-color: #7b8cff; }}
.sent-zh {{ font-size: 0.92em; color: #9090b8; line-height: 1.6; }}
.sent-en {{ font-size: 1em; color: #d0d0f0; line-height: 1.6; margin-top: 2px; }}
.sent-pair.active .sent-zh {{ color: #b0b0e0; }}
.sent-pair.active .sent-en {{ color: #ffffff; }}

/* Practice */
.practice-zone {{ margin-top: 18px; padding-top: 16px; border-top: 1px solid #2a2a4a; }}
.record-btn {{ display: flex; align-items: center; gap: 8px; padding: 10px 20px;
               border-radius: 24px; border: none; cursor: pointer; font-size: 0.95em;
               background: #2e2060; color: #a0a8ff; transition: all 0.2s; }}
.record-btn.recording {{ background: #5a1a1a; color: #ff8080; animation: pulse 1s infinite; }}
@keyframes pulse {{ 0%,100% {{ opacity:1 }} 50% {{ opacity:0.6 }} }}
.transcript-box {{ margin-top: 12px; padding: 12px 14px; background: #1a1a2e;
                   border-radius: 8px; font-size: 0.92em; color: #c0c0e0; line-height: 1.7;
                   min-height: 48px; white-space: pre-wrap; }}
.feedback-box {{ margin-top: 10px; padding: 14px; background: #0f2a1a;
                 border-radius: 8px; font-size: 0.9em; color: #80c880; line-height: 1.8;
                 white-space: pre-wrap; display: none; }}
.feedback-box.visible {{ display: block; }}
.next-btn {{ margin-top: 12px; padding: 10px 24px; border-radius: 20px; border: none;
             cursor: pointer; background: #7b8cff; color: #fff; font-size: 0.95em;
             display: none; }}
.next-btn.visible {{ display: inline-block; }}
.label {{ font-size: 0.72em; color: #555; text-transform: uppercase;
          letter-spacing: 0.08em; margin-bottom: 5px; }}
.fb-section {{ margin-bottom: 14px; }}
.fb-label {{ font-size: 0.72em; color: #555; text-transform: uppercase;
             letter-spacing: 0.08em; margin-bottom: 6px; }}
.fb-corrected {{ font-size: 1em; color: #c8f0c8; line-height: 2; padding: 10px 12px;
                 background: #0f2a0f; border-radius: 8px; }}
.fb-translation {{ font-size: 0.95em; color: #9090b8; line-height: 1.8; padding: 10px 12px;
                   background: #16162a; border-radius: 8px; }}
.fb-text {{ font-size: 0.92em; color: #9090b8; line-height: 1.7; }}
.fb-text.warn {{ color: #e0c880; }}
.corr-btn {{ display: inline-block; padding: 1px 6px; margin: 0 2px;
             border-radius: 4px; border: 1px solid #ffcc44; background: transparent;
             color: #ffcc44; font-size: 0.82em; font-weight: bold;
             cursor: pointer; vertical-align: middle; transition: all 0.15s; }}
.corr-btn.active {{ background: #ffcc44; color: #000; }}
.corr-inline {{ display: block; margin: 6px 0 6px 12px; padding: 8px 12px;
                background: #1a1a2e; border-left: 3px solid #ffcc44;
                border-radius: 0 8px 8px 0; font-size: 0.88em; line-height: 1.7; }}
.corr-orig {{ color: #ff8080; text-decoration: line-through; margin-right: 6px; }}
.corr-arrow {{ color: #555; margin-right: 6px; }}
.corr-new {{ color: #80ff80; margin-right: 8px; font-weight: 500; }}
.corr-reason {{ display: block; color: #9090b8; margin-top: 4px; }}

/* ── Summary ── */
#summary-view {{ display: none; padding-top: 4px; }}
.summary-overview {{ background: #16162a; border: 1px solid #2a2a4a;
                     border-radius: 14px; padding: 20px 24px; margin-bottom: 20px; }}
.summary-overview-label {{ font-size: 0.72em; color: #7b8cff; text-transform: uppercase;
                            letter-spacing: 0.1em; margin-bottom: 10px; }}
.summary-overview-text {{ font-size: 1em; color: #d0d0f0; line-height: 1.9; }}
.summary-topic {{ background: #16162a; border: 1px solid #2a2a4a;
                  border-radius: 14px; padding: 18px 22px; margin-bottom: 14px; }}
.summary-topic-title {{ font-size: 1em; font-weight: 600; color: #a0a8ff;
                        margin-bottom: 12px; padding-bottom: 10px;
                        border-bottom: 1px solid #2a2a4a; }}
.summary-points {{ list-style: none; padding: 0; margin: 0; }}
.summary-points li {{ font-size: 0.93em; color: #c8c8e8; line-height: 1.8;
                      padding: 5px 0 5px 20px; position: relative; }}
.summary-points li::before {{ content: ""; position: absolute; left: 2px; top: 14px;
                               width: 6px; height: 6px; border-radius: 50%;
                               background: #7b8cff; opacity: 0.8; }}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1 id="vid-title"></h1>
    <div class="mode-bar">
      <button class="mode-btn active" id="btn-listen" onclick="setMode('listen')">聆聽模式</button>
      <button class="mode-btn" id="btn-practice" onclick="setMode('practice')">練習模式</button>
      <button class="mode-btn" id="btn-summary" onclick="setMode('summary')">摘要</button>
    </div>
  </div>
  <div id="segments-container"></div>
  <div id="summary-view"></div>
</div>

<script>
const DATA = {data_json};
const GEMINI_KEY = "{GEMINI_API_KEY}";
let mode = 'listen';

document.getElementById('vid-title').textContent = DATA.title;

function setMode(m) {{
  mode = m;
  document.getElementById('btn-listen').classList.toggle('active', m === 'listen');
  document.getElementById('btn-practice').classList.toggle('active', m === 'practice');
  document.getElementById('btn-summary').classList.toggle('active', m === 'summary');
  document.getElementById('segments-container').style.display = m === 'summary' ? 'none' : 'block';
  document.getElementById('summary-view').style.display = m === 'summary' ? 'block' : 'none';
  document.querySelectorAll('.practice-zone').forEach(z => {{
    z.style.display = m === 'practice' ? 'block' : 'none';
  }});
  document.querySelectorAll('audio').forEach(a => {{ a.pause(); a.currentTime = 0; }});
}}

function buildSegments() {{
  const container = document.getElementById('segments-container');
  DATA.segments.forEach((seg, si) => {{
    const div = document.createElement('div');
    div.className = 'segment';
    div.id = `seg-${{si}}`;

    div.innerHTML = `
      <div class="seg-nav">
        <span>段落 ${{si + 1}} / ${{DATA.segments.length}}</span>
      </div>
      <div class="audio-row">
        <audio id="audio-${{si}}" controls src="${{seg.audio_path}}"></audio>
        <div class="rewind-btns">
          <button onclick="rewind(${{si}},5)">↩ 5s</button>
          <button onclick="rewind(${{si}},10)">↩ 10s</button>
        </div>
      </div>
      <div id="sents-${{si}}"></div>
      <div class="practice-zone" style="display:none">
        <div class="label">口語練習</div>
        <button class="record-btn" id="rec-${{si}}" onclick="toggleRecord(${{si}})">
          🎤 開始錄音
        </button>
        <div class="label" style="margin-top:12px">你說的</div>
        <div class="transcript-box" id="trans-${{si}}">（錄音後顯示）</div>
        <div class="label" style="margin-top:10px">批改</div>
        <div class="feedback-box" id="fb-${{si}}"></div>
        <button class="next-btn" id="next-${{si}}" onclick="playNext(${{si}})">
          下一段 →
        </button>
      </div>
    `;
    container.appendChild(div);

    // build sentence pairs
    const sentsDiv = document.getElementById(`sents-${{si}}`);
    const audio = document.getElementById(`audio-${{si}}`);
    seg.sentences.forEach((s, j) => {{
      const p = document.createElement('div');
      p.className = 'sent-pair';
      p.id = `sp-${{si}}-${{j}}`;
      p.innerHTML = `<div class="sent-zh">${{s.zh}}</div><div class="sent-en">${{s.en}}</div>`;
      p.addEventListener('click', () => {{
        audio.currentTime = s.tts_start;
        audio.play();
      }});
      sentsDiv.appendChild(p);
    }});

    // sentence sync
    let lastIdx = -1;

    audio.addEventListener('timeupdate', () => {{
      const t = audio.currentTime;
      let active = 0;
      seg.sentences.forEach((s, j) => {{ if (t >= s.tts_start) active = j; }});
      if (active !== lastIdx) {{
        if (lastIdx >= 0) document.getElementById(`sp-${{si}}-${{lastIdx}}`).classList.remove('active');
        const el = document.getElementById(`sp-${{si}}-${{active}}`);
        el.classList.add('active');
        el.scrollIntoView({{ behavior: 'smooth', block: 'nearest' }});
        lastIdx = active;
      }}
    }});

    // auto-pause at end (practice mode) or auto-advance (listen mode)
    audio.addEventListener('ended', () => {{
      if (mode === 'listen') {{
        playNext(si);
      }}
      // practice mode: user manually proceeds after recording
    }});
  }});
}}

function rewind(si, sec) {{
  const audio = document.getElementById(`audio-${{si}}`);
  audio.currentTime = Math.max(0, audio.currentTime - sec);
}}

function playNext(si) {{
  const next = document.getElementById(`audio-${{si + 1}}`);
  if (next) {{
    next.play();
    next.scrollIntoView({{ behavior: 'smooth', block: 'start' }});
  }}
}}

// ── 錄音 ────────────────────────────────────────────────────────────────────
let recognition = null;
let isRecording = false;

function toggleRecord(si) {{
  const btn = document.getElementById(`rec-${{si}}`);
  if (isRecording) {{
    recognition && recognition.stop();
    return;
  }}

  const SpeechRec = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRec) {{
    alert('此瀏覽器不支援 Web Speech API，請用 Chrome。');
    return;
  }}

  recognition = new SpeechRec();
  recognition.lang = 'en-US';
  recognition.continuous = true;
  recognition.interimResults = true;

  const transBox = document.getElementById(`trans-${{si}}`);
  transBox.textContent = '🎤 錄音中...';
  btn.textContent = '⏹ 停止錄音';
  btn.classList.add('recording');
  isRecording = true;

  let finalText = '';
  recognition.onresult = e => {{
    let interim = '';
    for (let i = e.resultIndex; i < e.results.length; i++) {{
      if (e.results[i].isFinal) finalText += e.results[i][0].transcript + ' ';
      else interim += e.results[i][0].transcript;
    }}
    transBox.textContent = (finalText + interim).trim() || '🎤 錄音中...';
  }};

  recognition.onend = () => {{
    isRecording = false;
    btn.textContent = '🎤 開始錄音';
    btn.classList.remove('recording');
    const userText = finalText.trim();
    if (userText) {{
      transBox.textContent = userText;
      getGemmaFeedback(si, userText);
    }}
  }};

  recognition.start();
}}

// ── Gemma 批改 ───────────────────────────────────────────────────────────────
function gemmaOutputText(result) {{
  // 過濾 thought=true 的 part，只取真正的輸出
  const parts = result?.candidates?.[0]?.content?.parts || [];
  return parts.filter(p => !p.thought).map(p => p.text || '').join('').trim();
}}

function extractJson(text) {{
  const start = text.indexOf('{{');
  if (start === -1) return null;
  let depth = 0, end = -1;
  for (let i = start; i < text.length; i++) {{
    if (text[i] === '{{') depth++;
    else if (text[i] === '}}') {{ depth--; if (depth === 0) {{ end = i; break; }} }}
  }}
  if (end === -1) return null;
  try {{ return JSON.parse(text.slice(start, end + 1)); }} catch {{ return null; }}
}}

function toggleCorrDetail(si, idx) {{
  const el = document.getElementById(`corr-detail-${{si}}-${{idx}}`);
  const btn = document.getElementById(`corr-btn-${{si}}-${{idx}}`);
  const open = el.style.display !== 'none';
  el.style.display = open ? 'none' : 'block';
  btn.classList.toggle('active', !open);
}}

function renderFeedback(si, data) {{
  const fbBox = document.getElementById(`fb-${{si}}`);
  const corrections = data.corrections || [];

  // 把 [1][2] 換成可點擊的 button（附 inline 詳細面板）
  let corrected = data.corrected || '';
  corrections.forEach((c, idx) => {{
    const marker = `[${{idx + 1}}]`;
    const detail = `<span class="corr-inline" id="corr-detail-${{si}}-${{idx}}" style="display:none">
      <span class="corr-orig">${{c.original}}</span>
      <span class="corr-arrow">→</span>
      <span class="corr-new">${{c.corrected}}</span>
      <span class="corr-reason">${{c.reason}}</span>
    </span>`;
    const btn = `<button class="corr-btn" id="corr-btn-${{si}}-${{idx}}" onclick="toggleCorrDetail(${{si}},${{idx}})">${{marker}}</button>${{detail}}`;
    corrected = corrected.replace(marker, btn);
  }});

  let html = `
    <div class="fb-section">
      <div class="fb-label">修正後英文</div>
      <div class="fb-corrected">${{corrected}}</div>
    </div>
    <div class="fb-section">
      <div class="fb-label">中文翻譯</div>
      <div class="fb-translation">${{data.translation_zh || ''}}</div>
    </div>`;

  if (data.missing_points) {{
    html += `<div class="fb-section">
      <div class="fb-label">遺漏重點</div>
      <div class="fb-text warn">${{data.missing_points}}</div>
    </div>`;
  }}

  if (data.summary) {{
    html += `<div class="fb-section">
      <div class="fb-label">整體建議</div>
      <div class="fb-text">${{data.summary}}</div>
    </div>`;
  }}

  fbBox.innerHTML = html;
  fbBox.classList.add('visible');
}}

async function getGemmaFeedback(si, userSpeech) {{
  const fbBox  = document.getElementById(`fb-${{si}}`);
  const nextBtn = document.getElementById(`next-${{si}}`);
  fbBox.innerHTML = '<div style="color:#666;padding:8px">批改中...</div>';
  fbBox.classList.add('visible');

  const seg = DATA.segments[si];
  const original = seg.sentences.map(s => s.zh).join('\\n');

  const prompt = `你是嚴格但建設性的英語口語教練。學習者剛聽完一段英文音訊，用英文口頭描述內容。

原始中文內容（供你理解語意用）：
${{original}}

學習者說的英文：
"${{userSpeech}}"

任務：
1. 寫出修正後的完整英文（保留學習者的大意，修正文法/用字錯誤，補充遺漏重點）
   在修正後的文字中，用 [1] [2] [3]... 標記每個修正點的位置（標記放在修正詞彙之後）
2. 提供修正後英文的繁體中文翻譯
3. 列出學習者遺漏的重要內容（如有）
4. 針對每個標記的修正點，說明原本錯誤及正確用法（繁體中文說明）
5. 一句話整體建議

請直接回傳 JSON，不要有其他文字：
{{
  "corrected": "修正後的英文，用 [1][2] 標記修正點",
  "translation_zh": "修正後英文的繁體中文翻譯",
  "missing_points": "遺漏的重點（繁體中文，沒有遺漏則填 null）",
  "corrections": [
    {{"id": 1, "original": "學習者原話片段", "corrected": "正確說法", "reason": "繁體中文說明"}}
  ],
  "summary": "一句話整體建議（繁體中文）"
}}`;

  const FB_MODELS = ['gemini-3-flash-preview', 'gemini-3.1-flash-lite'];
  async function callFeedbackApi(model) {{
    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${{model}}:generateContent?key=${{GEMINI_KEY}}`,
      {{
        method: 'POST',
        headers: {{ 'Content-Type': 'application/json' }},
        body: JSON.stringify({{
          contents: [{{ parts: [{{ text: prompt }}] }}],
          generationConfig: {{ temperature: 0.3, maxOutputTokens: 2048 }}
        }})
      }}
    );
    if (resp.status === 429) throw Object.assign(new Error('quota'), {{quota: true}});
    return resp.json();
  }}

  try {{
    let result;
    try {{
      result = await callFeedbackApi(FB_MODELS[0]);
    }} catch(e) {{
      if (e.quota) {{
        console.log('批改切換備用模型:', FB_MODELS[1]);
        result = await callFeedbackApi(FB_MODELS[1]);
      }} else throw e;
    }}
    const text = gemmaOutputText(result);
    const data = extractJson(text);
    if (data) {{
      renderFeedback(si, data);
    }} else {{
      fbBox.textContent = text || '無法解析回饋';
    }}
  }} catch(e) {{
    fbBox.textContent = '批改失敗：' + e.message;
  }}

  nextBtn.classList.add('visible');
}}

function buildSummary(summary) {{
  if (!summary) return;
  const view = document.getElementById('summary-view');
  let html = `
    <div class="summary-overview">
      <div class="summary-overview-label">影片內容摘要</div>
      <div class="summary-overview-text">${{summary.overview}}</div>
    </div>`;
  (summary.topics || []).forEach(topic => {{
    const points = (topic.points || [])
      .map(p => `<li>${{p}}</li>`).join('');
    html += `
    <div class="summary-topic">
      <div class="summary-topic-title">${{topic.title}}</div>
      <ul class="summary-points">${{points}}</ul>
    </div>`;
  }});
  view.innerHTML = html;
}}

const SUMMARY = {summary_json};
buildSegments();
buildSummary(SUMMARY);
setMode('listen');
</script>
</body>
</html>"""
    return html


# ── 供外部呼叫的入口 ──────────────────────────────────────────────────────────

def get_video_id(url):
    m = re.search(r'(?:v=|youtu\.be/)([A-Za-z0-9_-]{11})', url)
    return m.group(1) if m else "video"


def run(url, voice="male"):
    """完整跑一部影片，回傳 (vid_id, title, segments)。供 FastAPI 呼叫。"""
    global OUTPUT_DIR, TTS_VOICE
    TTS_VOICE = "en-US-Wavenet-F" if voice == "female" else "en-US-Wavenet-D"
    vid_id = get_video_id(url)
    OUTPUT_DIR = os.path.join("tmp", "sayit", vid_id)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("\n步驟 1：取得逐字稿")
    whisper_segs = _transcribe_via_captions(vid_id)
    if whisper_segs is not None:
        title = _get_video_title(url)
        print(f"  標題：{title}")
    else:
        print("  改用下載 + Whisper")
        audio_paths, title = download_audio(url)
        whisper_segs = transcribe(audio_paths)

    segments           = process_with_gemma(title, whisper_segs)
    segments           = tts_segments(segments)

    html = generate_html(title, segments)
    with open(os.path.join(OUTPUT_DIR, "player.html"), "w", encoding="utf-8") as f:
        f.write(html)
    with open(os.path.join(OUTPUT_DIR, "data.json"), "w", encoding="utf-8") as f:
        json.dump({"title": title, "segments": segments}, f, ensure_ascii=False, indent=2)

    return vid_id, title, segments


if __name__ == "__main__":
    # 取得 URL
    if len(sys.argv) > 1:
        url = sys.argv[1].strip()
    else:
        print("=" * 50)
        print("  SayIt Pipeline")
        print("=" * 50)
        url = input("\n請輸入 YouTube URL：").strip()
        if not url:
            print("未輸入 URL，使用預設影片")
            url = YOUTUBE_URL
        gender = input("語音性別（m = 男聲, f = 女聲，預設 m）：").strip().lower()
        TTS_VOICE = "en-US-Wavenet-F" if gender == "f" else "en-US-Wavenet-D"
        print(f"語音：{TTS_VOICE}")

    # 每部影片獨立目錄（依 video ID）
    vid_id = get_video_id(url)
    OUTPUT_DIR = os.path.join("tmp", "sayit", vid_id)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print(f"\n輸出目錄：{OUTPUT_DIR}\n")

    # Step 1
    audio_paths, title = download_audio(url)

    # Step 2
    whisper_segs = transcribe(audio_paths)

    # Step 3
    segments = process_with_gemma(title, whisper_segs)

    # Step 4
    summary = generate_summary(title, segments)

    # Step 5
    segments = tts_segments(segments)

    # Step 6：產生 HTML
    html = generate_html(title, segments, summary)
    html_path = os.path.join(OUTPUT_DIR, "player.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)

    with open(os.path.join(OUTPUT_DIR, "data.json"), "w", encoding="utf-8") as f:
        json.dump({"title": title, "segments": segments}, f, ensure_ascii=False, indent=2)

    # 找一個空閒 port 啟動 server
    import socket, threading, webbrowser, http.server

    PORT = 8080
    while True:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(('localhost', PORT)) != 0:
                break
            PORT += 1

    os.chdir(OUTPUT_DIR)

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass

    server = http.server.HTTPServer(('', PORT), QuietHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    player_url = f"http://localhost:{PORT}/player.html"
    print(f"\n✅ 完成！")
    print(f"   標題：{title}")
    print(f"   段落：{len(segments)} 段，共 {sum(len(s['sentences']) for s in segments)} 句")
    print(f"\n🌐 播放器已啟動：{player_url}")
    print(f"   （練習模式請用 Chrome）")

    webbrowser.open(player_url)
    print(f"\n按 Ctrl+C 關閉 server")
    try:
        thread.join()
    except KeyboardInterrupt:
        server.shutdown()
        print("\nServer 已關閉")

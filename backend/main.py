"""
SayIt FastAPI 後端
- POST /process        接收 YouTube URL，背景跑 pipeline
- GET  /status/{job}   查詢處理進度
- GET  /video/{vid_id} 取得已處理影片資料（從 Supabase）
"""

import os, uuid, threading, traceback, json
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from supabase import create_client
from dotenv import load_dotenv
import pipeline

load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
STORAGE_BUCKET = "sayit-audio"
API_SECRET    = os.getenv("API_SECRET")

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def verify_secret(request: Request, call_next):
    if API_SECRET and request.headers.get("X-Api-Secret") != API_SECRET:
        return JSONResponse(status_code=401, content={"error": "unauthorized"})
    return await call_next(request)

# 記憶體內的 job 狀態（伺服器重啟會清空，但影片結果在 Supabase 不會消失）
jobs: dict = {}


# ── Models ───────────────────────────────────────────────────────────────────

class ProcessRequest(BaseModel):
    url: str
    voice: str = "male"


class FeedbackRequest(BaseModel):
    segment_sentences: list
    user_speech: str


# ── Endpoints ────────────────────────────────────────────────────────────────

@app.post("/process")
def process(req: ProcessRequest):
    vid_id = pipeline.get_video_id(req.url)

    # 已處理過就直接回傳，不重跑
    existing = supabase.table("videos").select("id, title").eq("id", vid_id).execute()
    if existing.data:
        return {"status": "cached", "video_id": vid_id}

    # 新 job
    job_id = str(uuid.uuid4())
    jobs[job_id] = {"status": "pending", "video_id": vid_id}
    t = threading.Thread(target=_run_job, args=(job_id, req.url, vid_id, req.voice), daemon=True)
    t.start()
    return {"status": "pending", "job_id": job_id, "video_id": vid_id}


@app.post("/feedback")
def feedback(req: FeedbackRequest):
    original = "\n".join(s["zh"] for s in req.segment_sentences)
    prompt = f"""你是嚴格但建設性的英語口語教練。學習者剛聽完一段英文音訊，用英文口頭描述內容。

原始中文內容（供你理解語意用）：
{original}

學習者說的英文：
"{req.user_speech}"

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
}}"""

    result = pipeline._gemini_post({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.3, "maxOutputTokens": 2048}
    })
    raw = pipeline._gemma_text(result)
    start = raw.find("{")
    end = raw.rfind("}") + 1
    if start == -1 or end == 0:
        return {"error": "parse_failed"}
    return json.loads(raw[start:end])


@app.get("/status/{job_id}")
def status(job_id: str):
    return jobs.get(job_id, {"status": "not_found"})


@app.get("/video/{video_id}")
def get_video(video_id: str):
    result = supabase.table("videos").select("*").eq("id", video_id).execute()
    if result.data:
        return result.data[0]
    raise HTTPException(status_code=404, detail="not found")


# ── Background job ────────────────────────────────────────────────────────────

def _run_job(job_id: str, url: str, vid_id: str, voice: str = "male"):
    try:
        _set(job_id, "downloading")
        vid_id, title, segments, summary = pipeline.run(url, voice=voice)

        _set(job_id, "uploading")
        updated_segments = _upload_audio(vid_id, segments)

        _set(job_id, "saving")
        supabase.table("videos").insert({
            "id": vid_id,
            "title": title,
            "data": {"title": title, "segments": updated_segments, "summary": summary}
        }).execute()

        # 清除本機暫存（mp4 原始檔 + mp3 音訊，資料已在 Supabase）
        import shutil
        local_dir = os.path.join("tmp", "sayit", vid_id)
        shutil.rmtree(local_dir, ignore_errors=True)

        _cleanup_old_videos()
        jobs[job_id] = {"status": "done", "video_id": vid_id}
        print(f"[job {job_id[:8]}] ✅ 完成：{title}")

    except Exception as e:
        jobs[job_id] = {"status": "error", "message": str(e), "trace": traceback.format_exc()}
        print(f"[job {job_id[:8]}] ❌ 錯誤：{e}")


def _set(job_id: str, status: str):
    jobs[job_id]["status"] = status
    print(f"[job {job_id[:8]}] → {status}")


MAX_VIDEOS = 10

def _cleanup_old_videos():
    result = supabase.table("videos").select("id, created_at").order("created_at").execute()
    videos = result.data
    if len(videos) <= MAX_VIDEOS:
        return
    for v in videos[:len(videos) - MAX_VIDEOS]:
        vid_id = v["id"]
        try:
            files = supabase.storage.from_(STORAGE_BUCKET).list(vid_id)
            if files:
                supabase.storage.from_(STORAGE_BUCKET).remove(
                    [f"{vid_id}/{f['name']}" for f in files]
                )
            supabase.table("videos").delete().eq("id", vid_id).execute()
            print(f"  🗑️  清除舊影片：{vid_id}")
        except Exception as e:
            print(f"  ⚠️  清除失敗 {vid_id}：{e}")


def _upload_audio(vid_id: str, segments: list) -> list:
    """把 mp3 上傳到 Supabase Storage，把 audio_path 換成公開 URL"""
    updated = []
    for seg in segments:
        local_path = os.path.join("tmp", "sayit", vid_id, seg["audio_path"])
        storage_path = f"{vid_id}/{os.path.basename(local_path)}"

        with open(local_path, "rb") as f:
            supabase.storage.from_(STORAGE_BUCKET).upload(
                storage_path, f,
                file_options={"content-type": "audio/mpeg", "upsert": "true"}
            )

        public_url = supabase.storage.from_(STORAGE_BUCKET).get_public_url(storage_path)
        seg_copy = dict(seg)
        seg_copy["audio_url"] = public_url
        updated.append(seg_copy)

    return updated

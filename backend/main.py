"""
SayIt FastAPI 後端
- POST /process        接收 YouTube URL，背景跑 pipeline
- GET  /status/{job}   查詢處理進度
- GET  /video/{vid_id} 取得已處理影片資料（從 Supabase）
"""

import os, uuid, threading, traceback
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from supabase import create_client
from dotenv import load_dotenv
import pipeline

load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
STORAGE_BUCKET = "sayit-audio"

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# 記憶體內的 job 狀態（伺服器重啟會清空，但影片結果在 Supabase 不會消失）
jobs: dict = {}


# ── Models ───────────────────────────────────────────────────────────────────

class ProcessRequest(BaseModel):
    url: str


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
    t = threading.Thread(target=_run_job, args=(job_id, req.url, vid_id), daemon=True)
    t.start()
    return {"status": "pending", "job_id": job_id, "video_id": vid_id}


@app.get("/status/{job_id}")
def status(job_id: str):
    return jobs.get(job_id, {"status": "not_found"})


@app.get("/video/{video_id}")
def get_video(video_id: str):
    result = supabase.table("videos").select("*").eq("id", video_id).execute()
    if result.data:
        return result.data[0]
    return {"error": "not found"}, 404


# ── Background job ────────────────────────────────────────────────────────────

def _run_job(job_id: str, url: str, vid_id: str):
    try:
        _set(job_id, "downloading")
        vid_id, title, segments = pipeline.run(url)

        _set(job_id, "uploading")
        updated_segments = _upload_audio(vid_id, segments)

        _set(job_id, "saving")
        supabase.table("videos").insert({
            "id": vid_id,
            "title": title,
            "data": {"title": title, "segments": updated_segments}
        }).execute()

        # 清除本機暫存（mp4 原始檔 + mp3 音訊，資料已在 Supabase）
        import shutil
        local_dir = os.path.join("tmp", "sayit", vid_id)
        shutil.rmtree(local_dir, ignore_errors=True)

        jobs[job_id] = {"status": "done", "video_id": vid_id}
        print(f"[job {job_id[:8]}] ✅ 完成：{title}")

    except Exception as e:
        jobs[job_id] = {"status": "error", "message": str(e), "trace": traceback.format_exc()}
        print(f"[job {job_id[:8]}] ❌ 錯誤：{e}")


def _set(job_id: str, status: str):
    jobs[job_id]["status"] = status
    print(f"[job {job_id[:8]}] → {status}")


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

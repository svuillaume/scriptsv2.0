from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import RedirectResponse

from .models import JobStatus, ScanRequest, ScanResponse, ScanResult
from .scanner import run_scan

app = FastAPI(
    title="FortiCNAPP AWS Inventory API",
    version="1.0.0",
    description=(
        "Wraps lw_aws_inventory.sh to provide an async HTTP API for collecting "
        "EC2, ECS Fargate, and Lambda inventory across AWS accounts."
    ),
)

# In-memory job store: job_id -> JobStatus
jobs: dict[str, JobStatus] = {}


# ─────────────────────────────────────────────────────────────────────────────
# Background task
# ─────────────────────────────────────────────────────────────────────────────

async def execute_scan(job_id: str, request: ScanRequest) -> None:
    """Background task: run the inventory scan and update the job record."""
    now = datetime.now(timezone.utc)
    jobs[job_id].status = "running"
    jobs[job_id].updated_at = now

    try:
        result: ScanResult = await run_scan(request)
        jobs[job_id].result = result
        jobs[job_id].status = "completed" if result.success else "failed"
    except Exception as exc:  # noqa: BLE001
        jobs[job_id].status = "failed"
        jobs[job_id].result = ScanResult(
            success=False,
            accounts=[],
            total_ec2_vcpus=0,
            total_ecs_vcpus=0,
            total_vcpus=0,
            errors=[f"Unhandled exception: {exc}"],
            duration_seconds=0.0,
        )
    finally:
        jobs[job_id].updated_at = datetime.now(timezone.utc)


# ─────────────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
async def root() -> RedirectResponse:
    """Redirect root to the interactive API docs."""
    return RedirectResponse(url="/docs")


@app.get("/health", tags=["Health"])
async def health() -> dict[str, Any]:
    """Liveness probe — returns 200 OK with version info."""
    return {"status": "ok", "version": "1.0.0"}


@app.post("/scan", response_model=ScanResponse, status_code=202, tags=["Scan"])
async def create_scan(
    request: ScanRequest,
    background_tasks: BackgroundTasks,
) -> ScanResponse:
    """
    Start an asynchronous AWS inventory scan.

    Returns a job_id that can be polled via GET /scan/{job_id}.
    """
    job_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    jobs[job_id] = JobStatus(
        job_id=job_id,
        status="pending",
        created_at=now,
        updated_at=now,
        request=request,
    )

    background_tasks.add_task(execute_scan, job_id, request)

    return ScanResponse(
        job_id=job_id,
        status="pending",
        message=f"Scan job {job_id} queued. Poll GET /scan/{job_id} for results.",
    )


@app.get("/scan/{job_id}", response_model=JobStatus, tags=["Scan"])
async def get_scan(job_id: str) -> JobStatus:
    """Retrieve the status (and result) of a scan job by its ID."""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found.")
    return jobs[job_id]


@app.get("/scans", response_model=list[JobStatus], tags=["Scan"])
async def list_scans(limit: int = 50) -> list[JobStatus]:
    """List all scan jobs, newest first (max 50)."""
    sorted_jobs = sorted(
        jobs.values(),
        key=lambda j: j.created_at,
        reverse=True,
    )
    return sorted_jobs[:limit]

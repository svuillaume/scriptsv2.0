from __future__ import annotations

import re
from datetime import datetime
from typing import Literal, Optional

from pydantic import BaseModel, field_validator


class ScanRequest(BaseModel):
    profile: Optional[str] = None
    regions: Optional[str] = None
    org_role: Optional[str] = None
    account_id: Optional[str] = None

    @field_validator("account_id")
    @classmethod
    def validate_account_id(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and not re.fullmatch(r"\d{12}", v):
            raise ValueError("account_id must be exactly 12 digits")
        return v


class AccountResult(BaseModel):
    profile: str
    account_id: str
    regions: str
    ec2_instances: int
    ec2_vcpus: int
    ecs_clusters: int
    ecs_running_tasks: int
    ecs_cpu_units: int
    ecs_license_vcpus: int
    lambda_functions: int
    total_vcpus: int


class ScanResult(BaseModel):
    success: bool
    accounts: list[AccountResult]
    total_ec2_vcpus: int
    total_ecs_vcpus: int
    total_vcpus: int
    errors: list[str]
    duration_seconds: float


class JobStatus(BaseModel):
    job_id: str
    status: Literal["pending", "running", "completed", "failed"]
    created_at: datetime
    updated_at: datetime
    request: ScanRequest
    result: Optional[ScanResult] = None


class ScanResponse(BaseModel):
    job_id: str
    status: str
    message: str

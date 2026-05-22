from __future__ import annotations

import asyncio
import csv
import io
import time

from .models import AccountResult, ScanRequest, ScanResult

# CSV column order produced by lw_aws_inventory.sh --output csv:
# "Profile","Account ID","Regions","EC2 Instances","EC2 vCPUs",
# "ECS Fargate Clusters","ECS Fargate Running Tasks","ECS Fargate CPU Units",
# "ECS Fargate License vCPUs","Lambda Functions (not used for licensing)","Total vCPUs"
_CSV_COLUMN_COUNT = 11


async def run_scan(request: ScanRequest) -> ScanResult:
    """Run lw_aws_inventory.sh and parse its CSV output into a ScanResult."""

    cmd = ["/bin/bash", "/app/scripts/lw_aws_inventory.sh", "--output", "csv"]

    if request.profile:
        cmd += ["-p", request.profile]
    if request.regions:
        cmd += ["-r", request.regions]
    if request.org_role:
        cmd += ["-o", request.org_role]
    if request.account_id:
        cmd += ["-a", request.account_id]

    start = time.monotonic()

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    stdout_bytes, stderr_bytes = await proc.communicate()
    duration = time.monotonic() - start

    stdout_text = stdout_bytes.decode("utf-8", errors="replace")
    stderr_text = stderr_bytes.decode("utf-8", errors="replace")

    # Collect errors/warnings from stderr
    errors: list[str] = []
    for line in stderr_text.splitlines():
        stripped = line.strip()
        # Strip ANSI escape codes before checking prefixes
        import re
        clean = re.sub(r"\x1b\[[0-9;]*m", "", stripped)
        if clean.startswith("ERROR:") or clean.startswith("WARN:"):
            errors.append(clean)

    # Parse CSV from stdout
    accounts: list[AccountResult] = []
    reader = csv.reader(io.StringIO(stdout_text))
    header_skipped = False
    for row in reader:
        if not row:
            continue
        # Skip blank rows
        if all(cell.strip() == "" for cell in row):
            continue
        # Skip the header row (first non-empty row)
        if not header_skipped:
            header_skipped = True
            continue
        # Guard against malformed rows
        if len(row) < _CSV_COLUMN_COUNT:
            errors.append(f"Skipped malformed CSV row (expected {_CSV_COLUMN_COUNT} columns, got {len(row)}): {row}")
            continue

        try:
            account = AccountResult(
                profile=row[0],
                account_id=row[1],
                regions=row[2],
                ec2_instances=int(row[3]),
                ec2_vcpus=int(row[4]),
                ecs_clusters=int(row[5]),
                ecs_running_tasks=int(row[6]),
                ecs_cpu_units=int(row[7]),
                ecs_license_vcpus=int(row[8]),
                lambda_functions=int(row[9]),
                total_vcpus=int(row[10]),
            )
            accounts.append(account)
        except (ValueError, IndexError) as exc:
            errors.append(f"Failed to parse CSV row {row}: {exc}")

    # Calculate totals
    total_ec2_vcpus = sum(a.ec2_vcpus for a in accounts)
    total_ecs_vcpus = sum(a.ecs_license_vcpus for a in accounts)
    total_vcpus = sum(a.total_vcpus for a in accounts)

    success = proc.returncode == 0

    return ScanResult(
        success=success,
        accounts=accounts,
        total_ec2_vcpus=total_ec2_vcpus,
        total_ecs_vcpus=total_ecs_vcpus,
        total_vcpus=total_vcpus,
        errors=errors,
        duration_seconds=round(duration, 3),
    )

#!/usr/bin/env python3
"""Retry CI only when GitHub failed to allocate hosted runners."""

import argparse
import json
import os
import subprocess

MAX_ATTEMPTS = 3
ALLOCATION_FAILURE = "The job was not acquired by Runner of type hosted even after multiple attempts"
PASSED = {"success", "skipped", "neutral"}


def recovery_jobs(run, jobs, annotations_for, expected_attempt=None):
    if run.get("name") != "CI" or run.get("path", "").split("@", 1)[0] != ".github/workflows/ci.yml":
        return [], "not the CI workflow"
    if run.get("status") != "completed" or run.get("conclusion") != "failure":
        return [], "run is not a completed failure"
    attempt = run["run_attempt"]
    if expected_attempt is not None and attempt != expected_attempt:
        return [], "a newer attempt already exists"
    if attempt >= MAX_ATTEMPTS:
        return [], "automatic recovery limit reached"

    failed = [job for job in jobs if job.get("conclusion") not in PASSED]
    if not failed:
        return [], "no failed jobs"
    for job in failed:
        if (job.get("status") != "completed" or
                job.get("conclusion") not in {"failure", "cancelled"} or
                job.get("runner_id") != 0 or job.get("steps") != []):
            return [], "a failed job started execution or lacks allocation evidence"
        if not any(annotation.get("annotation_level") == "failure" and
                   ALLOCATION_FAILURE in annotation.get("message", "")
                   for annotation in annotations_for(job)):
            return [], "a failed job has no hosted-runner allocation error"
    return [job["id"] for job in failed], "all failed jobs were unallocated hosted jobs"


def gh_json(*arguments):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", type=int)
    parser.add_argument("--attempt", type=int, help="Ignore a stale workflow_run event")
    parser.add_argument("--retry", action="store_true", help="Submit recovery; otherwise inspect only")
    args = parser.parse_args(arguments)
    repository = os.environ["GITHUB_REPOSITORY"]
    path = f"repos/{repository}/actions/runs/{args.run_id}"
    run = gh_json("api", path)
    pages = gh_json("api", "--paginate", "--slurp", f"{path}/jobs?filter=latest&per_page=100")
    jobs = [job for page in pages for job in page["jobs"]]

    def annotations_for(job):
        check_id = int(job["check_run_url"].rsplit("/", 1)[1])
        pages = gh_json("api", "--paginate", "--slurp",
                        f"repos/{repository}/check-runs/{check_id}/annotations?per_page=100")
        return [annotation for page in pages for annotation in page]

    failed, reason = recovery_jobs(run, jobs, annotations_for, args.attempt)
    print(f"CI runner recovery: {reason}", flush=True)
    if not failed:
        return
    print(f"Eligible: {len(failed)} job(s); next attempt {run['run_attempt'] + 1}/{MAX_ATTEMPTS}", flush=True)
    if not args.retry:
        return
    current = gh_json("api", path)
    if any(current.get(key) != run.get(key) for key in ("status", "conclusion", "run_attempt")):
        print("CI runner recovery: run changed during inspection; leaving it alone")
        return
    subprocess.run(["gh", "api", "--method", "POST", f"{path}/rerun-failed-jobs"], check=True)


if __name__ == "__main__":
    main()

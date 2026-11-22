#!/usr/bin/env python3
import copy
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("recover_ci_runner", ROOT / "scripts/recover_ci_runner.py")
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


def failed_run():
    return {"name": "CI", "path": ".github/workflows/ci.yml", "status": "completed",
            "conclusion": "failure", "run_attempt": 1}


def unallocated_job(job_id=10):
    return {"id": job_id, "status": "completed", "conclusion": "cancelled", "runner_id": 0,
            "steps": [], "check_run_url": f"https://api.github.com/repos/example/project/check-runs/{job_id}"}


ANNOTATIONS = [{"annotation_level": "failure", "message": recovery.ALLOCATION_FAILURE}]


class RecoveryDecisionTests(unittest.TestCase):
    def decide(self, run=None, jobs=None, annotations=None, attempt=None):
        return recovery.recovery_jobs(
            failed_run() if run is None else run,
            [unallocated_job()] if jobs is None else jobs,
            lambda job: ANNOTATIONS if annotations is None else annotations,
            attempt,
        )[0]

    def test_allocation_only_failure_keeps_successful_jobs(self):
        jobs = [unallocated_job(10), unallocated_job(11),
                {"id": 12, "conclusion": "success", "runner_id": 99, "steps": [{"name": "Build"}]},
                {"id": 13, "conclusion": "skipped"}]
        self.assertEqual(self.decide(jobs=jobs), [10, 11])

    def test_started_build_or_test_is_not_retried(self):
        for change in ({"runner_id": 99}, {"steps": [{"name": "Checkout", "conclusion": "failure"}]}):
            with self.subTest(change=change):
                job = unallocated_job()
                job.update(change)
                self.assertEqual(self.decide(jobs=[job]), [])

    def test_mixed_test_and_allocation_failure_requires_investigation(self):
        test_failure = unallocated_job(11)
        test_failure.update(runner_id=99, steps=[{"name": "Run tests", "conclusion": "failure"}])
        self.assertEqual(self.decide(jobs=[unallocated_job(), test_failure]), [])

    def test_notice_or_other_infrastructure_error_is_insufficient(self):
        for annotations in ([], [{"annotation_level": "notice", "message": recovery.ALLOCATION_FAILURE}],
                            [{"annotation_level": "failure", "message": "Internal server error"}]):
            with self.subTest(annotations=annotations):
                self.assertEqual(self.decide(annotations=annotations), [])

    def test_incomplete_job_metadata_fails_closed(self):
        for field in ("runner_id", "steps"):
            job = unallocated_job()
            del job[field]
            self.assertEqual(self.decide(jobs=[job]), [])

    def test_only_failed_ci_runs_are_eligible(self):
        for change in ({"name": "Other workflow"}, {"path": ".github/workflows/other.yml"},
                       {"status": "in_progress"}, {"conclusion": "cancelled"}, {"conclusion": "success"}):
            with self.subTest(change=change):
                run = failed_run()
                run.update(change)
                self.assertEqual(self.decide(run=run), [])
        self.assertEqual(self.decide(jobs=[]), [])

    def test_attempt_limit_and_stale_events(self):
        run = failed_run()
        run["run_attempt"] = 2
        self.assertEqual(self.decide(run=run, attempt=2), [10])
        self.assertEqual(self.decide(run=run, attempt=1), [])
        run["run_attempt"] = recovery.MAX_ATTEMPTS
        self.assertEqual(self.decide(run=run), [])


class RecoveryAPITests(unittest.TestCase):
    def invoke(self, retry=False, changed=False):
        run = failed_run()
        current = copy.deepcopy(run)
        if changed:
            current.update(status="queued", conclusion=None, run_attempt=2)
        responses = [run, [{"jobs": [unallocated_job()]}], [ANNOTATIONS]]
        if retry:
            responses.append(current)
        args = ["123", "--attempt", "1"] + (["--retry"] if retry else [])
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "example/project"}), \
             patch.object(recovery, "gh_json", side_effect=responses), \
             patch.object(recovery.subprocess, "run") as submit:
            recovery.main(args)
            return submit

    def test_inspection_does_not_submit_recovery(self):
        self.invoke().assert_not_called()

    def test_recovery_resubmits_only_failed_jobs_and_their_dependents(self):
        self.invoke(retry=True).assert_called_once_with(
            ["gh", "api", "--method", "POST", "repos/example/project/actions/runs/123/rerun-failed-jobs"],
            check=True,
        )

    def test_manual_rerun_during_inspection_prevents_duplicate_submission(self):
        self.invoke(retry=True, changed=True).assert_not_called()


if __name__ == "__main__":
    unittest.main()

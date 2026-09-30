"""Background jobs: each job runs in its own daemon thread, state and log in the db."""

import threading
import time
import traceback


class Job(object):
    def __init__(self, db, job_id, type, actor):
        self.db = db
        self.id = job_id
        self.type = type
        self.actor = actor

    def log(self, line):
        stamp = time.strftime("%H:%M:%S", time.gmtime())
        for part in str(line).splitlines() or [""]:
            self.db.append_job_log(self.id, "%s %s" % (stamp, part))


class JobRunner(object):
    def __init__(self, db):
        self.db = db
        self._threads = {}
        self._lock = threading.Lock()

    def submit(self, type, actor, fn):
        """Create a job row and run fn(job) in a daemon thread. Returns the job id."""
        job_id = self.db.create_job(type, actor)
        job = Job(self.db, job_id, type, actor)
        t = threading.Thread(target=self._run, args=(job, fn), name="job-%s" % job_id)
        t.daemon = True
        with self._lock:
            self._threads[job_id] = t
        t.start()
        return job_id

    def _run(self, job, fn):
        db = self.db
        db.update_job(job.id, status="running", started=time.time())
        try:
            result = fn(job)
            if result is not None and not isinstance(result, dict):
                result = {"value": result}
            db.update_job(job.id, status="succeeded", finished=time.time(), result=result,
                          message=(result or {}).get("message", "") if isinstance(result, dict) else "")
        except Exception as exc:  # the job's failure is its result
            msg = "%s: %s" % (type(exc).__name__, exc)
            try:
                job.log("ERROR " + msg)
                job.log(traceback.format_exc(limit=5))
            except Exception:
                pass
            db.update_job(job.id, status="failed", finished=time.time(), message=msg[:1000])
        finally:
            with self._lock:
                self._threads.pop(job.id, None)

    def running(self, type=None):
        """Jobs currently queued or running (optionally of one type)."""
        return self.db.active_jobs(type)

    def wait(self, job_id, timeout=None):
        """Test/CLI helper: wait for the thread of a job started by this runner."""
        with self._lock:
            t = self._threads.get(job_id)
        if t is not None:
            t.join(timeout)
        return self.db.get_job(job_id)

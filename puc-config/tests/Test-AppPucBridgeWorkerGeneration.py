import contextlib
import io
import json
import sys
from pathlib import Path


scripts_dir = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(scripts_dir))

from AppPucBridge import AppPucBridge


class SuccessService:
    def create_groups(self, *, members, group_count, on_progress):
        on_progress({"event": "batch_started"})
        return {"results": []}


class ErrorService:
    def create_groups(self, *, members, group_count, on_progress):
        raise RuntimeError("worker failed")


def drain(service, generation):
    bridge = AppPucBridge()
    bridge.batch_service = service
    bridge._run_batch([], 1, generation)
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        bridge._drain_events()
    return [json.loads(line) for line in output.getvalue().splitlines()]


success = drain(SuccessService(), 31)
assert [item.get("generation") for item in success] == [31, 31], success
assert success[0]["event"] == "batch_progress", success
assert success[1]["data"]["state"] == "completed", success

error = drain(ErrorService(), 32)
assert len(error) == 1 and error[0]["generation"] == 32 and not error[0]["ok"], error

print("PASS AppPucBridgeWorkerGeneration")

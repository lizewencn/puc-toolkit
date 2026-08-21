import threading
import time

from app_puc_login import get_active_app_session
from app_puc_login.events import RequestDisconnected

from .models import (
    AppGroupBatchBusyError, AppGroupBatchProgress, AppGroupBatchResult,
    AppGroupBatchSummary, AppGroupInputError, AppGroupItemStatus,
)


def normalize_members(members, *, owner_account: str, owner_puc_id: str):
    if not members:
        raise AppGroupInputError("members must not be empty")
    normalized = []
    seen = {}
    for member in members:
        account = member.account.strip()
        puc_id = member.app_puc_id.strip()
        if not account or not puc_id:
            raise AppGroupInputError("member account and app_puc_id are required")
        if account in seen:
            if seen[account] != puc_id:
                raise AppGroupInputError(f"conflicting app_puc_id for {account}")
            continue
        if account == owner_account and puc_id != owner_puc_id:
            raise AppGroupInputError("owner app_puc_id does not match active session")
        seen[account] = puc_id
        normalized.append({"account": account, "account_type": 7,
                           "role": 1 if account == owner_account else 0,
                           "alias": account, "puc_id": puc_id, "realm": "puc.com"})
    if owner_account not in seen:
        normalized.append({"account": owner_account, "account_type": 7, "role": 1,
                           "alias": owner_account, "puc_id": owner_puc_id,
                           "realm": "puc.com"})
    return normalized


class AppPucGroupBatchService:
    _batch_lock = threading.Lock()

    def create_groups(self, *, members, group_count: int, on_progress=None):
        if group_count <= 0:
            raise AppGroupInputError("group_count must be positive")
        session = get_active_app_session()
        if session is None:
            raise AppGroupInputError("active APP PUC session is required")
        wire_members = normalize_members(
            members, owner_account=session.app_user_id,
            owner_puc_id=session.app_puc_id,
        )
        if not self._batch_lock.acquire(blocking=False):
            raise AppGroupBatchBusyError("another APP PUC group batch is running")
        started = time.monotonic()
        results = []
        self._emit(on_progress, "batch_started")
        try:
            for index in range(group_count):
                if not self._session_matches(session):
                    self._append_unavailable(results, index, group_count, on_progress)
                    break
                temporary = f"index-{index}"
                self._emit(on_progress, "group_creating", index)
                try:
                    create = session.client.request(
                        {"cmd_name": "chat_create_group", "subject": temporary,
                         "members": wire_members},
                        expected_ack="chat_create_group_ack",
                    )
                except RequestDisconnected:
                    self._append_unavailable(results, index, group_count, on_progress)
                    break
                except Exception as exc:
                    result = self._create_failure(index, temporary, None, str(exc))
                    results.append(result); self._emit(on_progress, "group_failed", index, result)
                    continue
                if create.get("result") != 0:
                    result = self._create_failure(index, temporary, create.get("result"),
                                                  self._message(create))
                    results.append(result); self._emit(on_progress, "group_failed", index, result)
                    continue
                group = create.get("group") if isinstance(create.get("group"), dict) else {}
                owner = next((m for m in create.get("members", [])
                              if isinstance(m, dict) and m.get("role") == 1), None)
                group_id, stamp = group.get("group_id"), group.get("time_stamp")
                final = f"index-{stamp}" if stamp not in (None, "") else None
                self._emit(on_progress, "group_created", index)
                missing = not all((group_id, group.get("puc_id"), group.get("realm"), final, owner))
                if missing:
                    result = self._rename_failure(index, temporary, final, group_id, stamp,
                                                  None, "create ACK missing rename metadata")
                    results.append(result); self._emit(on_progress, "group_failed", index, result)
                    continue
                if not self._session_matches(session):
                    self._append_unavailable(results, index, group_count, on_progress)
                    break
                self._emit(on_progress, "group_renaming", index)
                try:
                    rename = session.client.request({
                        "cmd_name": "chat_update_group_subject", "group_id": group_id,
                        "puc_id": group["puc_id"], "realm": group["realm"],
                        "subject": final, "operator": owner,
                    }, expected_ack="chat_update_group_subject_ack")
                except RequestDisconnected:
                    self._append_unavailable(results, index, group_count, on_progress)
                    break
                except Exception as exc:
                    result = self._rename_failure(index, temporary, final, group_id, stamp,
                                                  None, str(exc))
                else:
                    if rename.get("result") == 0:
                        result = AppGroupBatchResult(index, temporary, final, group_id, stamp,
                            0, "", 0, "", AppGroupItemStatus.RENAMED)
                    else:
                        result = self._rename_failure(index, temporary, final, group_id, stamp,
                            rename.get("result"), self._message(rename))
                results.append(result)
                self._emit(on_progress, "group_completed" if result.status is AppGroupItemStatus.RENAMED else "group_failed", index, result)
            summary = self._summary(group_count, started, results)
            self._emit(on_progress, "batch_completed")
            return summary
        finally:
            self._batch_lock.release()

    @staticmethod
    def _session_matches(session):
        current = get_active_app_session()
        return current is not None and current.app_session_id == session.app_session_id and current.client is session.client

    @staticmethod
    def _emit(callback, event, index=None, result=None):
        if callback:
            try: callback(AppGroupBatchProgress(event, index, result))
            except Exception: pass

    def _append_unavailable(self, results, start, count, callback):
        for index in range(start, count):
            result = AppGroupBatchResult(index, f"index-{index}", status=AppGroupItemStatus.SESSION_UNAVAILABLE)
            results.append(result); self._emit(callback, "session_unavailable", index, result)

    @staticmethod
    def _message(response): return str(response.get("message") or response.get("msg") or "")

    @staticmethod
    def _create_failure(index, temporary, code, message):
        return AppGroupBatchResult(index, temporary, create_code=code,
                                   create_message=message, status=AppGroupItemStatus.CREATE_FAILED)

    @staticmethod
    def _rename_failure(index, temporary, final, group_id, stamp, code, message):
        return AppGroupBatchResult(index, temporary, final, group_id, stamp, 0, "",
                                   code, message, AppGroupItemStatus.RENAME_FAILED)

    @staticmethod
    def _summary(count, started, results):
        statuses = [r.status for r in results]
        renamed = statuses.count(AppGroupItemStatus.RENAMED)
        rename_failed = statuses.count(AppGroupItemStatus.RENAME_FAILED)
        return AppGroupBatchSummary(count, renamed + rename_failed, renamed,
            rename_failed, statuses.count(AppGroupItemStatus.CREATE_FAILED),
            statuses.count(AppGroupItemStatus.SESSION_UNAVAILABLE),
            time.monotonic() - started, tuple(results))

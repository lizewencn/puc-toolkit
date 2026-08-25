import re
import threading
import time
import uuid

from app_puc_login import get_active_app_session
from app_puc_login.events import RequestDisconnected

from .models import (
    AppGroupBatchBusyError, AppGroupBatchProgress, AppGroupBatchResult,
    AppGroupBatchSummary, AppGroupInputError, AppGroupItemStatus,
    AppGroupMemberInput,
)


class AppDispatcherSearchError(RuntimeError):
    pass


def dispatcher_account_prefix(account: str) -> str:
    prefix = re.sub(r"\d+$", "", account.strip())
    if not prefix:
        raise AppGroupInputError("current account must contain a non-numeric prefix")
    return prefix


def _search_dispatchers(session, keyword: str, *, page: int = 1, page_size: int = 100):
    query = keyword.strip()
    if not query:
        raise AppDispatcherSearchError("dispatcher search keyword is required")
    response = session.client.post_authenticated({
        "puc_id": session.app_puc_id,
        "cmd_guid": str(uuid.uuid4()),
        "user_id": session.app_user_id,
        "realm": session.app_realm,
        "page": page,
        "keyword": query,
        "product_name": "WebPUC",
        "version": "10",
        "cmd_name": "page_piece_account_list_request",
        "page_size": page_size,
        "version_seq": "0",
    })
    result = response.get("result")
    if str(result) != "0":
        message = response.get("message") or response.get("msg") or "no message"
        raise AppDispatcherSearchError(
            f"dispatcher search failed (result={result!r}): {message}"
        )
    command = response.get("cmd_name")
    if command != "page_piece_account_list_request_ack":
        raise AppDispatcherSearchError(
            f"dispatcher search returned an unexpected ACK: {command!r}"
        )
    results = []
    seen = set()
    for item in response.get("account_list") or []:
        if not isinstance(item, dict):
            continue
        account = str(item.get("dispatcher_account") or "").strip()
        name = str(item.get("dispatcher_name") or "").strip()
        app_puc_id = str(item.get("puc_id") or "").strip()
        key = account.lower()
        if not account or not app_puc_id or key in seen:
            continue
        seen.add(key)
        results.append({
            "account": account,
            "name": name,
            "appPucId": app_puc_id,
            "label": f"{name}({account})" if name and name != account else account,
        })
    return results


def search_dispatchers(keyword: str, *, page: int = 1, page_size: int = 100):
    session = get_active_app_session()
    if session is None:
        raise AppDispatcherSearchError("active APP PUC session is required")
    return _search_dispatchers(session, keyword, page=page, page_size=page_size)


def normalize_members(
    members, *, owner_account: str, owner_puc_id: str, owner_realm: str = "puc.com",
    owner_alias: str = "",
):
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
        normalized.append({"guid": str(uuid.uuid4()), "account": account, "account_type": 7,
                           "role": 1 if account == owner_account else 0,
                           "alias": member.alias.strip() or account,
                           "puc_id": puc_id, "realm": owner_realm,
                           "system_id": "000"})
    if owner_account not in seen:
        normalized.append({"guid": str(uuid.uuid4()), "account": owner_account,
                           "account_type": 7, "role": 1,
                           "alias": owner_alias.strip() or owner_account, "puc_id": owner_puc_id,
                           "realm": owner_realm, "system_id": "000"})
    return normalized


def _protocol_request(session, payload):
    return {
        "product_name": "PUC",
        "version": "10",
        "puc_id": session.app_puc_id,
        "user_id": session.app_user_id,
        "realm": session.app_realm,
        **payload,
    }


def _create_subject(members):
    subject = "、".join(str(member.get("alias") or member.get("account") or "")
                        for member in members)
    return subject if len(subject) <= 32 else subject[:28] + "..."


class AppPucGroupBatchService:
    _batch_lock = threading.Lock()

    def create_groups(self, *, member_count: int, group_count: int, on_progress=None):
        if group_count <= 0:
            raise AppGroupInputError("group_count must be positive")
        if member_count < 3:
            raise AppGroupInputError("member_count must be at least 3 (including owner)")
        session = get_active_app_session()
        if session is None:
            raise AppGroupInputError("active APP PUC session is required")
        prefix = dispatcher_account_prefix(session.app_user_id)
        candidates = _search_dispatchers(session, prefix)
        owner_key = session.app_user_id.casefold()
        prefix_key = prefix.casefold()
        selected = [
            AppGroupMemberInput(item["account"], item["appPucId"], item.get("name", ""))
            for item in candidates
            if item["account"].casefold() != owner_key
            and re.sub(r"\d+$", "", item["account"].strip()).casefold() == prefix_key
        ][:member_count - 1]
        if len(selected) < member_count - 1:
            raise AppGroupInputError(
                f"insufficient matching dispatchers for prefix {prefix!r}: "
                f"need {member_count - 1}, found {len(selected)}"
            )
        wire_members = normalize_members(
            selected, owner_account=session.app_user_id,
            owner_puc_id=session.app_puc_id,
            owner_realm=session.app_realm,
            owner_alias=getattr(session, "app_user_alias", ""),
        )
        result_members = tuple({
            "account": str(member["account"]),
            "alias": str(member.get("alias") or member["account"]),
        } for member in wire_members)
        if not self._batch_lock.acquire(blocking=False):
            raise AppGroupBatchBusyError("another APP PUC group batch is running")
        started = time.monotonic()
        results = []
        self._emit(on_progress, "batch_started")
        try:
            for index in range(group_count):
                if not self._session_matches(session):
                    self._append_unavailable(
                        results, index, group_count, on_progress, result_members,
                    )
                    break
                temporary = f"index-{index}"
                create_subject = _create_subject(wire_members)
                self._emit(on_progress, "group_creating", index)
                try:
                    create = session.client.request(
                        _protocol_request(session, {
                            "cmd_name": "chat_create_group", "subject": create_subject,
                            "members": wire_members,
                        }),
                        expected_ack="chat_create_group_ack",
                    )
                except RequestDisconnected:
                    self._append_unavailable(
                        results, index, group_count, on_progress, result_members,
                    )
                    break
                except Exception as exc:
                    result = self._create_failure(
                        index, temporary, None, str(exc), result_members,
                    )
                    results.append(result); self._emit(on_progress, "group_failed", index, result)
                    continue
                if create.get("result") != 0:
                    result = self._create_failure(
                        index, temporary, create.get("result"), self._message(create),
                        result_members,
                    )
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
                                                  None, "create ACK missing rename metadata",
                                                  result_members)
                    results.append(result); self._emit(on_progress, "group_failed", index, result)
                    continue
                if not self._session_matches(session):
                    self._append_unavailable(
                        results, index, group_count, on_progress, result_members,
                    )
                    break
                self._emit(on_progress, "group_renaming", index)
                try:
                    rename = session.client.request(_protocol_request(session, {
                        "cmd_name": "chat_update_group_subject", "group_id": group_id,
                        "puc_id": group["puc_id"], "realm": group["realm"],
                        "subject": final, "operator": owner,
                    }), expected_ack="chat_update_group_subject_ack")
                except RequestDisconnected:
                    self._append_unavailable(
                        results, index, group_count, on_progress, result_members,
                    )
                    break
                except Exception as exc:
                    result = self._rename_failure(index, temporary, final, group_id, stamp,
                                                  None, str(exc), result_members)
                else:
                    if rename.get("result") == 0:
                        result = AppGroupBatchResult(index, temporary, final, group_id, stamp,
                            0, "", 0, "", AppGroupItemStatus.RENAMED, result_members)
                    else:
                        result = self._rename_failure(index, temporary, final, group_id, stamp,
                            rename.get("result"), self._message(rename), result_members)
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

    def _append_unavailable(self, results, start, count, callback, members=()):
        for index in range(start, count):
            result = AppGroupBatchResult(
                index, f"index-{index}", status=AppGroupItemStatus.SESSION_UNAVAILABLE,
                members=members,
            )
            results.append(result); self._emit(callback, "session_unavailable", index, result)

    @staticmethod
    def _message(response): return str(response.get("message") or response.get("msg") or "")

    @staticmethod
    def _create_failure(index, temporary, code, message, members=()):
        return AppGroupBatchResult(index, temporary, create_code=code,
                                   create_message=message, status=AppGroupItemStatus.CREATE_FAILED,
                                   members=members)

    @staticmethod
    def _rename_failure(index, temporary, final, group_id, stamp, code, message, members=()):
        return AppGroupBatchResult(index, temporary, final, group_id, stamp, 0, "",
                                   code, message, AppGroupItemStatus.RENAME_FAILED, members)

    @staticmethod
    def _summary(count, started, results):
        statuses = [r.status for r in results]
        renamed = statuses.count(AppGroupItemStatus.RENAMED)
        rename_failed = statuses.count(AppGroupItemStatus.RENAME_FAILED)
        return AppGroupBatchSummary(count, renamed + rename_failed, renamed,
            rename_failed, statuses.count(AppGroupItemStatus.CREATE_FAILED),
            statuses.count(AppGroupItemStatus.SESSION_UNAVAILABLE),
            time.monotonic() - started, tuple(results))

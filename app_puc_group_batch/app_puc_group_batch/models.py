from dataclasses import dataclass
from enum import Enum


class AppGroupBatchError(RuntimeError): pass
class AppGroupBatchBusyError(AppGroupBatchError): pass
class AppGroupInputError(AppGroupBatchError): pass
class AppGroupSessionUnavailableError(AppGroupBatchError): pass


@dataclass(frozen=True)
class AppGroupMemberInput:
    account: str
    app_puc_id: str


class AppGroupItemStatus(str, Enum):
    RENAMED = "renamed"
    RENAME_FAILED = "rename_failed"
    CREATE_FAILED = "create_failed"
    SESSION_UNAVAILABLE = "session_unavailable"


@dataclass(frozen=True)
class AppGroupBatchResult:
    index: int
    temporary_subject: str
    final_subject: str | None = None
    group_id: str | None = None
    create_time: int | str | None = None
    create_code: int | None = None
    create_message: str = ""
    rename_code: int | None = None
    rename_message: str = ""
    status: AppGroupItemStatus = AppGroupItemStatus.CREATE_FAILED


@dataclass(frozen=True)
class AppGroupBatchProgress:
    event: str
    index: int | None = None
    result: AppGroupBatchResult | None = None


@dataclass(frozen=True)
class AppGroupBatchSummary:
    requested_count: int
    created_count: int
    renamed_count: int
    rename_failed_count: int
    create_failed_count: int
    session_unavailable_count: int
    elapsed_seconds: float
    results: tuple[AppGroupBatchResult, ...]

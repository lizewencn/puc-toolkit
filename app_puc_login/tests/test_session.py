from app_puc_login.session import (
    clear_active_app_session,
    get_active_app_session,
    publish_active_app_session,
)


def test_registry_replacement_cannot_be_cleared_by_stale_session():
    first = publish_active_app_session(
        app_puc_id="1001", app_user_id="owner", app_realm="puc.com",
        app_user_alias="Owner", client=object(),
    )
    second = publish_active_app_session(
        app_puc_id="1002", app_user_id="next", app_realm="puc.com",
        app_user_alias="Next", client=object(),
    )

    assert first.app_session_id != second.app_session_id
    clear_active_app_session(first.app_session_id)
    assert get_active_app_session() is second
    clear_active_app_session(second.app_session_id)
    assert get_active_app_session() is None

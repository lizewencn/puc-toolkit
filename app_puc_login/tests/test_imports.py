def test_canonical_and_legacy_imports_share_public_types():
    import app_puc_login
    import puc_login

    assert puc_login.LoginConfig is app_puc_login.LoginConfig
    assert puc_login.PucLoginClient is app_puc_login.PucLoginClient

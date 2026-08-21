# APP PUC Login Client

本地 Python 账号密码登录客户端，复刻 Android SDK 的标准 PUC 登录协议并保持 WebSocket 在线。它直接使用传入的服务器地址，不探测或切换主备节点；不支持 SSO、3K 直客和手机号登录。

登录域固定为 `puc.com`，调用方和命令行均不需要传入 realm。

## 安装

```powershell
# 在仓库根目录执行
python -m pip install -e .\app_puc_login
```

支持 Python 3.10 及以上版本，运行依赖为 `requests`、`websocket-client` 和 `pycryptodome`。

## 模块接入

```python
from app_puc_login import (
    LoginConfig, PucLoginClient, get_active_app_session,
)


def on_event(event):
    # 回调运行在登录工作线程。PyQt、Tkinter 等界面应在此切回 UI 线程。
    print(event.event_type.value, event.code, event.payload)


config = LoginConfig(
    account="dispatcher01",
    password="password",
    server="https://10.0.0.10:16663",
    imei_list=("local-tool-device",),
    sn="local-tool-device",
)

client = PucLoginClient()
client.start(config, on_event)  # 立即返回，不阻塞界面线程

# LOGIN_SUCCESS 后可供同进程 APP 模块读取；不包含密码或 Token。
session = get_active_app_session()

# 在窗口关闭或切换账号前调用。
client.stop()
```

同一实例不能并发启动两次。切换账号时先调用 `stop()`，再以新配置调用 `start()`。

事件类型包括 `connecting`、`token_acquired`、`websocket_connected`、`login_success`、`message`、`disconnected`、`reconnecting`、`error` 和 `stopped`。密码、Authorization 和 Token 会从事件负载中脱敏。

登录成功后的网络断开会重新执行完整账号密码登录，默认等待时间依次为 1、2、4、8、16、30 秒，之后固定为 30 秒。账号密码错误、账号锁定和服务端明确拒绝不会循环重试。

## 命令行调试

推荐通过环境变量提供密码，避免出现在命令历史中：

```powershell
$env:PUC_PASSWORD = 'password'
python -m app_puc_login --account dispatcher01 --server https://10.0.0.10:16663 --password-env PUC_PASSWORD
```

不传 `--password-env` 时会安全提示输入密码。命令以 JSON Lines 输出结构化事件，按 `Ctrl+C` 关闭连接。仅在受控测试环境使用 `--insecure`；默认验证 TLS 证书。

## 验证

```powershell
# 在仓库根目录执行
python -m pytest .\app_puc_login\tests -q
```

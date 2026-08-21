# 新增角色

新增角色只需要角色名称。工作流先读取角色列表、接口/菜单权限树、系统与接入点列表及全网和通讯录顶级组织，然后构造 `add_role` 请求：接口权限和菜单权限树递归全选，数据权限选择系统与接入点全集，组织字段使用根节点 `00`。预检阶段不写入；明确指定角色名称后可直接进入 live 阶段。角色别名重复或任一前置接口失败时停止，不重试写入请求。

运行：

```powershell
scripts\Invoke-PucScript.cmd Invoke-PucRole.ps1 -Environment <环境主机> -RoleAlias <角色名称> -DryRun
scripts\Invoke-PucScript.cmd Invoke-PucRole.ps1 -Environment <环境主机> -RoleAlias <角色名称> -Live -ConfirmLive
```

只使用 `Invoke-PucHttpRequest`/`Invoke-PucJsonRequest`，不输出令牌、Cookie、密码或接入点密钥。接口返回 `result != 0` 时保留完整的凭证脱敏响应预览。

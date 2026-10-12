# KeepAwake —— 菜单栏「合盖不休眠」开关

解决「有时需要合上盖子让电脑继续跑，但常开会严重发热耗电」的问题：
需要时点一下开启，用完点一下关闭。菜单栏常挂，图标显示当前状态。

## 使用

菜单栏图标含义：
- 🌙 `moon` = 正常休眠（合盖即睡）
- ☀️ `sun.max.fill` = 合盖不休眠中（继续运行，发热耗电）

菜单项：
- **开启合盖不休眠**：合上盖子机器继续运行（下载/跑服务/挂机）
- **关闭合盖不休眠**：恢复正常休眠，同时把空闲休眠修回 10 分钟
- **修复：空闲休眠恢复为 10 分钟**：仅当检测到 `sleep 0`（永不休眠）时出现

每次切换会弹一次系统管理员密码框（修改电源设置需要 root 权限）。

## 原理

| 开关 | 底层命令 | 效果 |
|---|---|---|
| 开 | `sudo pmset -a disablesleep 1` | 合盖不休眠 |
| 关 | `sudo pmset -a disablesleep 0; sudo pmset -a sleep 10` | 恢复正常 |

之前「耗电发热严重」的根源是 `sleep 0`（永不空闲休眠）——那是用错了开关，
正确的是 `disablesleep`（只管合盖），工具的「关闭/修复」会把它纠正回来。

## 开机自启（可选）

系统设置 → 通用 → 登录项与扩展 → 添加 `KeepAwake.app`。

## 免密切换（可选）

默认每次切换要输管理员密码。想零弹窗，配置 sudoers 只放行这两条 pmset 命令：

```bash
sudo visudo -f /etc/sudoers.d/keepawake
```

写入一行（把 lihuiyang 换成你的用户名）：

```
lihuiyang ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a sleep 10
```

保存后工具自动走免密路径（先试 `sudo -n`，成功就不再弹密码框）。

## 重新构建

```bash
./build.sh
```

## 热量提示

合盖运行时散热变差（键盘出风口被盖住），建议：
- 尽量插电使用
- 盖子留一点缝或机器竖放
- 避免合盖跑重负载任务（编译/训练），轻负载（下载、本地服务）没问题

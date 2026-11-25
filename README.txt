百度网盘剪贴板清理 v1.0.1
==========================

用途与升级
----------
复制包含百度网盘分享链接的文字，自动生成带 https:// 的简洁链接。
使用 Windows 自带的 Win+V 历史记录保留原始分享文本。
原版 v1.0.0 无需删除；升级时先右键旧版托盘图标选择“退出”，再解压新版并运行 Start.vbs。两个版本共用单实例锁，不可同时运行。

首次使用
--------
1. 按 Win+V，确认已开启 Windows 剪贴板历史（也可在设置→系统→剪贴板开启）。
2. 解压整个文件夹，保留所有文件在同一目录，双击 Start.vbs。无需安装，无命令行窗口，右下角系统托盘显示蓝色“i”图标。
3. 复制百度网盘分享文字，等待系统完成处理，再 Ctrl+V。
4. Win+V 预期显示最新一项为简洁链接，第二项为完整原文。可点击原文粘贴。
   若系统未能识别历史项的恢复来源，或 Win+V 历史顺序异常，可右键托盘选择“恢复上次清理前的原文”再粘贴。

示例 1
原文：链接: https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: ABCD
结果：https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD

示例 2
原文：链接: https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA 提取码: ABCD
结果：https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=ABCD

托盘菜单
--------
- 顶部显示最近处理状态（不会显示分享文本或密码）。
- 暂停自动清理：再次点击恢复监听；暂停、恢复均不会自动改写现有剪贴板。
- 立即清理当前剪贴板：手动处理一次，仍需确认原文进入历史。
- 恢复上次清理前的原文：恢复本次运行最近成功处理的一份完整文本。仅在内存暂存，不写磁盘，不主动增加历史条目；退出程序即丢弃内存副本。
- 退出：停止监听与后台进程。

处理机制与局限
--------------
Windows 的剪贴板历史服务异步读取剪贴板；立即覆盖可能让原文漏存。
本版在剪贴板事件触发后，利用 Windows Runtime 的 GetHistoryItemsAsync 查询历史，等待最新历史文本与当前原文完全一致，随后在 Win32 剪贴板锁内核对序号并写入干净链接，同时显式标记允许加入历史。这样避免主动制造重复原文，也避免覆盖后来复制的新内容。
查询采用异步任务和短时定时器，常驻空闲期间不轮询；单次确认最多约 3 秒。历史关闭、策略禁止访问、原文未进入历史、或者顺序无法确认时，保留原文而不清理。可检查托盘状态。脚本不会自动启用历史。
Windows 决定 Win+V 的最终记录、去重与展示顺序，脚本无法直接插入指定历史位置。脚本识别常见 Windows 历史恢复进程并跳过自动清理；识别属于兼容性策略，不能保证所有 Windows 版本都可准确区分恢复与普通复制。
若复制后立刻粘贴，可能早于历史确认，粘贴到原文。再次粘贴即可；如超过约 3 秒仍是原文，请检查托盘状态。若手动选原文时再次被清理，使用托盘恢复原文功能。
Windows 历史最多 25 项，每项上限 4 MB，后续复制、去重、固定项、同步及系统清理等会影响顺序或可用性。脚本不改变这些机制。原文保留指完整纯文本；历史中的原始富文本能力由 Windows 决定。

其它处理规则
------------
- 仅匹配 pan.baidu.com/s/1... 格式的分享链接，允许 http://、https://、www. 或无协议输入，统一输出 https://pan.baidu.com/s/...。
- 保留分享 ID 与 pwd；网址缺少密码时从“提取码”“提取密码”“访问码”“访问密码”中补全（4-8 位英文字母或数字）。
- 多链接、冲突密码、未知格式的 pwd：保留原文；规范化 HTTPS 链接不再次写入。
- 普通文本、其它网盘、图片等不做清理；尊重源程序禁止历史记录的剪贴板标记；若源程序禁止云同步，清理结果同样标记禁止云同步。
- 原文与链接均不会由本脚本发送到网络或保存至磁盘；Windows 自身剪贴板历史及跨设备同步仍依照系统设置运行。
- 无开机自启、无权限提升、无注册表修改。若需开机启动，Win+R 输入 shell:startup，把 Start.vbs 快捷方式放入启动文件夹即可。

系统要求及验收
--------------
Windows 10 1809 或更新版本 / Windows 11，Windows PowerShell 5.1、.NET Framework、Windows Script Host，且剪贴板历史功能可用。
双击 SelfTest.cmd：编译内嵌 C# 并运行 16 组解析用例（包含判断规范化链接不会重复写入）。自检不访问或改写剪贴板历史。
发布前只在非 Windows 环境做了源码与解析规则检查；尚未执行 Windows 实机编译、托盘、WinRT 及剪贴板历史测试。请以以下验收为准：
A. 分别复制两个带分享标题、会员签名的完整样例，Ctrl+V 应输出 HTTPS 简洁链接。
B. 每次紧接着 Win+V，确认第一项简洁链接，第二项含原始标题、提取码、会员签名和原始换行；点击第二项，确认粘贴原文而未被再次覆盖。
C. 重复复制同一分享；若 Windows 历史去重导致没有确认最新原文，则脚本应保留原文。
D. 快速连续复制分享与普通文字，确认最终剪贴板是最新普通文字，且不会被旧任务覆盖。
E. 关闭历史后再复制新分享，应保留原文；重新开启后复制新分享应正常处理。
F. 普通文字、已规范化 HTTPS、冲突提取码及多个分享链接均保持原样；暂停/恢复、立即清理、恢复原文、重复启动与退出功能正常。
G. 若托盘提示历史未开启或无法确认，即使 Win+V 已开启，请反馈托盘状态及 Windows 版本；若无法启动，请反馈 SelfTest.cmd 完整输出。

参考实现依据
------------
Microsoft Learn: Clipboard Formats (Cloud Clipboard and Clipboard History Formats)
https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats
Microsoft DevBlogs: How can I wait for Clipboard History to recognize a clipboard change before I change it again?
https://devblogs.microsoft.com/oldnewthing/20250509-00/?p=111169
Microsoft DevBlogs: Enumerating Windows clipboard history in PowerShell
https://devblogs.microsoft.com/oldnewthing/20230303-00/?p=107894

版本历史
--------
v1.0.1：统一输出 HTTPS，确认原文历史后再写入清理结果，原子序号核对，历史恢复保护与托盘原文恢复，更新测试与说明。待 Windows 实机验收。
v1.0.0：事件驱动监听、百度网盘链接及提取码清理、托盘暂停/退出、单实例、短暂占用重试与自检。

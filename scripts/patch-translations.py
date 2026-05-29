#!/usr/bin/env python3
# Patch hand-written Chinese (zh-Hans) translations into
# Localizable.xcstrings. Source strings that aren't already in the
# catalog are added; existing English-only entries get their
# localization filled in. Translations I already shipped are NOT
# overwritten unless --force is passed.
#
# This is a one-time bulk patch — write the Chinese here, run, ship.
# Subsequent edits the user makes flow through the Refresh
# translations button (LLM-powered, memory-steered), not this script.

import json
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "Glotty" / "Resources" / "Localizable.xcstrings"

# Source string -> zh-Hans translation. Grouped by tab/area for
# readability; ordering doesn't matter at write time.
TRANSLATIONS = {
    # --- HUD (Fn-leader panel) ---
    "Fn held": "按住 Fn",
    "held": "按下",
    "Translate to": "翻译成",
    "Explain in": "解释（用",
    "Chat with Glotty in": "和 Glotty 聊天（用",
    "Release": "松开",
    "to cancel": "可取消",

    # --- Profile tab ---
    "Optional. Used to address you in practice feedback and chat replies.": "可选。用于在练习反馈和聊天回复中称呼你。",
    "Your native language": "你的母语",
    "Native language": "母语",
    "The language you speak natively. Drives auto-detected source / target choices and biases translation behavior toward what you're likely reading or writing. Separate from Glotty's UI language below.": "你的母语。用于自动判断源语言 / 目标语言,并优化你常读写语言的翻译表现。与下方 Glotty 的界面语言相互独立。",
    "e.g. \"I'm learning German for a job in Berlin. Native English speaker, intermediate level.\"": "例如:「我正在为在柏林的工作学习德语。母语是英语,中级水平。」",
    "A short blurb about your learning goals or background — fed into LLM prompts so suggestions feel tailored. Optional.": "简单介绍一下你的学习目标或背景 —— 会传给 LLM 让建议更贴合你。可选。",

    # --- Translation tab ---
    "Default source language": "默认源语言",
    "Default target language": "默认目标语言",
    "Source can stay on Auto detect. Pin it if you only translate from a fixed language.": "源语言可以保持「自动检测」。如果你只从一种固定语言翻译,可以将它固定。",
    "Backend": "后端",
    "Translation engine": "翻译引擎",
    "Apple Translation (on-device)": "Apple 翻译(本地)",
    "Other engines (DeepL, Google, Claude, GPT) coming after the spike validates the core flow.": "其他引擎(DeepL、Google、Claude、GPT)将在核心流程验证后陆续支持。",
    "This Mac doesn't support Apple Intelligence": "此 Mac 不支持 Apple Intelligence",
    "Apple Intelligence requires an Apple Silicon Mac with sufficient memory. Use a cloud LLM provider instead.": "Apple Intelligence 需要 Apple 芯片的 Mac 并拥有足够的内存。请改用云端 LLM 服务商。",
    "Recheck": "重新检查",
    "Auto detect": "自动检测",
    "Auto (based on source)": "自动(根据源语言)",

    # --- Dictionaries tab ---
    "Dictionary library": "词典库",
    "Install Dictionary": "安装词典",
    "Installed dictionaries": "已安装词典",
    "Use all": "全部使用",
    "Bilingual": "双语",
    "Bilingual dictionary": "双语词典",
    "Top-to-bottom priority controls lookup order for the current Translation source and target.": "从上到下的优先级决定了当前翻译源 / 目标语言对的查询顺序。",
    "Active": "已启用",
    "Apple Translation can't translate this pair": "Apple 翻译不支持此语言对",

    # --- Polish tab ---
    "Polish output language": "润色输出语言",
    "The language Fn → R rewrites your selection into. Not the same as Translation's target.": "Fn → R 将所选文本重写为的语言。与「翻译」的目标语言不同。",

    # --- Hotkey tab ---
    "Translate (target → native)": "翻译(目标 → 母语)",
    "Explain (LLM)": "解释(LLM)",
    "Polish to idiomatic": "润色为地道表达",
    "Press Record, then tap the key you want as the second step of the hotkey. Esc during recording cancels. Reset restores the default.": "点击「录制」,然后按下你想作为快捷键第二步的按键。录制时按 Esc 取消,「重置」恢复默认值。",
    "Press **Record**, then tap the key you want as the second step of the hotkey. **Esc** during recording cancels. **Reset** restores the default.": "点击 **录制**,然后按下你想作为快捷键第二步的按键。录制时按 **Esc** 取消,**重置** 恢复默认值。",

    # --- Chat tab (was Practice) ---
    "How Glotty acts in chat. Reset by clearing the fields. Affects the conversational chat (Fn → C) and proactive reminder notifications.": "决定 Glotty 在聊天里的语气。清空字段即可重置。影响对话式聊天(Fn → C)和主动提醒通知。",
    "Proactive chat reminders": "主动聊天提醒",
    "Glotty posts a notification at the cadence you pick. Click the notification to open a chat in your target language. Same as triggering Fn → C manually.": "Glotty 会按你选择的频率发送通知。点击通知即可用目标语言开始对话,效果等同于手动按 Fn → C。",
    "Yesterday": "昨天",
    "One thread per day (boundary 4 AM local). Click a row to open a read-only view of that conversation. Today's chat resumes on Fn → C until 4 AM rollover.": "每天一段对话(以本地凌晨 4 点为界)。点击任意一行可只读查看那天的对话。当天的聊天在 Fn → C 中继续,直到凌晨 4 点切换。",
    "Reminder frequency": "提醒频率",
    "Send a chat reminder now": "立即发送一次聊天提醒",

    # --- Memory tab ---
    "Memory extraction": "记忆提取",
    "Glotty proposes new memories after every chat reply. Highest token usage.": "Glotty 在每次聊天回复后都会提取新记忆。token 消耗最高。",
    "Memories are only extracted when you click 'Extract memories' in the chat. Lower cost.": "只有在聊天中点击「提取记忆」时才会提取。开销较低。",
    "No memory extraction at all. Existing accepted memories still inject into prompts.": "完全不提取记忆。已接受的记忆仍会注入到提示词中。",
    "Every memory still requires your approval before it's injected into LLM prompts.": "所有记忆在注入到 LLM 提示词之前,都需要你的确认。",
    "Persistent facts about you, injected into every LLM prompt regardless of which context is active.": "关于你的稳定事实,无论当前上下文是哪一个,都会被注入到每一次 LLM 调用中。",
    "Contexts let you keep parallel sets of memories. When a context is active, its memories inject alongside Global ones; memories scoped to other contexts stay dormant.": "上下文让你可以保存多组平行的记忆。当某个上下文处于激活状态时,它的记忆会和全局记忆一起注入;其他上下文的记忆保持休眠。",
    "Delete — memories scoped to this context become orphaned and stop injecting.": "删除 —— 归属此上下文的记忆将成为孤立项,不再注入。",
    "After you chat with Glotty under a polish or explain popup, new memories Glotty notices will land here for review.": "在「润色」或「解释」弹窗里与 Glotty 对话后,Glotty 注意到的新记忆会出现在此处供你审阅。",
    "Click a suggestion to reopen the conversation that produced it — approve or reject it from there. Or use Dismiss all to clear the whole queue.": "点击建议可重新打开产生它的对话 —— 在那里接受或拒绝。也可以使用「全部忽略」清空整个队列。",
    "Open conversation to review": "打开对话以审阅",
    "Source conversation no longer in History.": "原对话已不在历史记录中。",
    "No accepted memories yet. Approve a suggestion above to add one.": "暂无已接受的记忆。请在上方接受一条建议来添加。",
    "No memories in this scope.": "此范围内没有记忆。",
    "No memories in \"%@\" yet.": "「%@」中暂无记忆。",
    "No global memories yet.": "暂无全局记忆。",
    "Nothing archived.": "没有已归档项。",
    "fact": "事实",
    "glossary": "术语",
    "preference": "偏好",
    "project": "项目",

    # --- Backup tab ---
    "Preferences + Memory/Contexts + Chat history (Recommended)": "偏好设置 + 记忆/上下文 + 聊天历史(推荐)",
    "Use **Export** to write a single JSON file with your Glotty settings, learned memories, chat threads, and activity history. Use **Import** on another machine (or this one, after a wipe) to restore it. Imports REPLACE local data — you'll get a confirmation prompt first.": "使用「导出」将你的 Glotty 设置、学到的记忆、聊天对话和活动历史写入一个 JSON 文件。在另一台设备(或本机重置后)使用「导入」来恢复。导入会**替换**本地数据 —— 操作前会先弹出确认。",
    "Profile, persona, languages, hotkeys, memory mode, polish & chat settings.": "个人资料、Glotty 人设、语言、快捷键、记忆模式、润色与聊天设置。",
    "Accepted memories with scope, pending suggestions, your defined contexts.": "带范围的已接受记忆、待审阅的建议、你定义的上下文。",
    "All past daily chat threads with corrections.": "所有过往的每日聊天对话及更正记录。",
    "Every translate / explain / polish event.": "每一次翻译 / 解释 / 润色记录。",
    "Stored in Keychain. Not included so the bundle stays safe to share.": "保存在钥匙串中。出于安全考虑,导出包不包含密钥。",
    "Local to this machine.": "仅保留在此设备上。",
    "Replace local data with backup?": "用备份替换本地数据?",
    "This will OVERWRITE existing preferences, memories, contexts, chat history, and activity history on this machine.": "此操作将**覆盖**本机现有的偏好设置、记忆、上下文、聊天历史和活动历史。",
    "Bundle contents:": "备份内容:",
    "preferences": "项偏好设置",
    "memories": "条记忆",
    "contexts": "个上下文",
    "days of chat": "天聊天",
    "activity events": "条活动记录",

    # --- System tab ---
    "Glotty's UI language": "Glotty 的界面语言",
    "The language Glotty itself uses for buttons, menus, settings — separate from your native language above. Switching kicks off an LLM translation of any missing strings, then relaunches the app so the new language takes effect everywhere.": "Glotty 用于按钮、菜单、设置等界面元素的语言 —— 与上方的母语彼此独立。切换后会通过 LLM 翻译尚未翻译的字符串,然后重启应用让新语言在各处生效。",
    "Translations": "翻译",
    "Refresh translations": "刷新翻译",
    "Re-translates every UI string in the current language via the LLM, ignoring cached results. The translation prompt picks up your accepted memories (Settings → Memory → Accepted) so saved preferences influence wording — record a memory like “prefer 「润色」 over 「打磨」 for Polish” to steer the result. Pre-shipped translations baked into the app aren't overwritten unless you force a refresh.": "用当前语言通过 LLM 重新翻译所有界面文案,忽略已缓存的结果。翻译提示词会读取你已接受的记忆(设置 → 记忆 → 已接受),让保存的偏好影响用词 —— 例如记录一条「Polish 偏好用「润色」而不是「打磨」」就能引导结果。除非强制刷新,否则随应用预置的翻译不会被覆盖。",
    "Debug": "调试",
    "Capture all settings tabs": "捕获所有设置标签",
    "Writes one PNG per Settings tab (plus the Fn HUD) to /tmp/glotty-screenshots/ then opens that folder in Finder. Used for the in-flight localization audit.": "为每个设置标签(以及 Fn HUD)在 /tmp/glotty-screenshots/ 写入一张 PNG,然后在访达中打开该文件夹。用于正在进行的本地化检查。",
    "Translating UI… %@ / %@": "正在翻译界面… %@ / %@",
    "Nothing to translate.": "没有需要翻译的内容。",
    "Use system default": "跟随系统",

    # --- Permissions tab (couldn't capture, audited from source) ---
    "Glotty is ready!": "Glotty 准备就绪!",
    "Both permissions granted. Try it out below.": "两项权限均已授予。下方就可以试用了。",
    "How to translate": "如何翻译",
    "Highlight any text in another app (browser, PDF, Notes, etc.).": "在任意其他应用(浏览器、PDF、备忘录等)中选中一段文本。",
    "Press the **Fn** key, then within 600ms press **T**.": "按下 **Fn** 键,然后在 600 毫秒内按 **T**。",
    "A popup appears with the translation, no focus stolen.": "弹窗会显示翻译,不会抢占焦点。",
    "Glotty lives in your menu bar — click the mascot for options.": "Glotty 常驻菜单栏 —— 点击吉祥物查看选项。",
    "Glotty needs these permissions": "Glotty 需要以下权限",
    "Status updates live. Grant in System Settings — this window refreshes automatically.": "状态实时更新。在「系统设置」中授权 —— 此窗口会自动刷新。",
    "Granted but Glotty still says ✗?": "已授权但 Glotty 仍显示 ✗?",
    "Dev builds are ad-hoc signed, so each rebuild has a different code signature. macOS's TCC tracks per-signature — your previous grant may belong to an older build. Two things to try:": "开发版本使用临时签名,所以每次重新构建签名都不一样。macOS 的 TCC 按签名记录权限 —— 之前的授权可能属于旧版本。可以试试这两个方法:",
    "Then quit & relaunch Glotty.": "然后退出并重新启动 Glotty。",
    "Diagnostic info": "诊断信息",
    "Troubleshooting": "故障排查",
    "Some permissions missing — Fn → T won't work yet.": "缺少部分权限 —— Fn → T 暂时无法使用。",
    "All set. Quit & relaunch if you just granted permissions.": "全部就绪。如果你刚授予权限,请退出并重新启动。",
    "Re-register Missing": "重新登记缺失项",
    "Granted ✓": "已授予 ✓",
    "Open Settings": "打开系统设置",
    "Re-register": "重新登记",
    "Done": "完成",

    # --- History tab ---
    "Recording": "记录",
    "Record history": "记录历史",
    "Show records from": "显示时间段",
    "Last 24 hours": "最近 24 小时",
    "Last 7 days": "最近 7 天",
    "Last 30 days": "最近 30 天",
    "All time": "全部时间",
    "Events recorded": "已记录事件",
    "Glotty saves what you searched and which mistakes Polish flagged. Stored locally in Application Support; never sent off-device. The time range only filters the lists below — history itself is never pruned.": "Glotty 会保存你查询过的内容和「润色」标记的错误。仅保存在本机的 Application Support 中,不会上传。时间范围只用于过滤下方列表 —— 历史本身永不删除。",
    "No activity yet. Use Fn → T / E / P and your runs will show up here.": "暂无活动。使用 Fn → T / E / P,你的记录会出现在这里。",
    "Showing the most recent %@ of %@ events. Narrow the time range above to see fewer.": "正在显示最近 %@ / %@ 条记录。缩小上方时间范围可减少显示数量。",
    "Frequently looked up": "高频查询",
    "Common mistake types": "常见错误类型",
    "Click a row to reopen the most recent polish run that flagged this category.": "点击行可重新打开标记了此类型的最近一次润色记录。",

    # --- Hotkey tab (row titles passed as string variable) ---
    "Translate (target → native)": "翻译 (目标 → 母语)",
    "Explain (LLM)": "解释 (LLM)",
    "Chat with Glotty": "和 Glotty 聊天",
    "Press a key…": "请按一个键…",
    "Two commands are bound to the same key — only the first will fire.": "两个命令绑定了同一个按键 —— 只有第一个会生效。",

    # --- Usage tab ---
    "Token usage": "用量明细",
    "Time range": "时间范围",
    "Today": "今天",
    "This week": "本周",
    "This month": "本月",
    "All time": "全部时间",
    "Total tokens": "总 token 数",
    "Calls": "调用次数",
    "Prompt": "输入",
    "Completion": "输出",
    "By feature": "按功能",
    "By provider": "按服务商",
    "Chat (ad-hoc)": "聊天(即兴)",
    "Practice generation": "练习生成",
    "Practice Q&A": "练习问答",
    "Memory extraction": "记忆提取",
    "Clear all usage history": "清空所有用量记录",
    "Tokens consumed by the configured LLM provider. Stored locally at ~/Library/Application Support/Glotty/usage.jsonl.": "当前 LLM 服务商已消耗的 token 数量。本地保存于 ~/Library/Application Support/Glotty/usage.jsonl。",

    # --- Polish tab (newly moved Common mistake types) ---
    "No mistake patterns yet. Polish will tag your drafts with categories (verb tense, articles, word choice, …) once it has rewritten a few.": "暂无错误模式。润色几次之后,Glotty 会为你的草稿打上类别标签(动词时态、冠词、用词等)。",

    # --- Menu bar (mascot status menu) ---
    "Context": "上下文",
    "None": "无",
    "Settings…": "设置…",
    "Quit Glotty": "退出 Glotty",
    "Manage contexts…": "管理上下文…",
    "None (global only)": "无(仅全局)",

    # --- Misc / shared ---
    "Reply in": "回复语言",
    "Discuss with Glotty": "和 Glotty 讨论",
    "Better:": "更地道:",
    "Extract memories": "提取记忆",
    "Glotty noticed": "Glotty 注意到",
    "Glotty is reviewing this chat…": "Glotty 正在浏览这段对话…",
    "Ask a follow-up — replies will appear here.": "提一个后续问题 —— 回复会出现在这里。",
    "Not satisfied? Ask a follow-up…": "不满意?提一个后续问题…",
    "Not satisfied? Discuss with Glotty": "不满意?和 Glotty 讨论",
    "Suggestions": "建议",
    "Accepted": "已接受",
    "Archive": "归档",
    "Active context": "当前上下文",
    "New context name": "新上下文名称",
    "Manage contexts…": "管理上下文…",
    "Manage memories…": "管理记忆…",
    "Dismiss all": "全部忽略",
    "Clear all chat history": "清空所有聊天历史",
    "from you": "条来自你",
    "Apple Intelligence": "Apple Intelligence",
    "Mono": "单语",
    "Bi": "双语",
}

force = "--force" in sys.argv

with CATALOG.open("r", encoding="utf-8") as f:
    catalog = json.load(f)

strings = catalog.setdefault("strings", {})
updated = 0
skipped = 0
added = 0

for source, zh in TRANSLATIONS.items():
    entry = strings.setdefault(source, {"localizations": {}})
    locs = entry.setdefault("localizations", {})
    existing = locs.get("zh-Hans", {}).get("stringUnit", {}).get("value")
    if existing and not force:
        skipped += 1
        continue
    locs["zh-Hans"] = {
        "stringUnit": {
            "state": "translated",
            "value": zh,
        }
    }
    if existing:
        updated += 1
    else:
        added += 1

with CATALOG.open("w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)

print(f"Catalog patched: +{added} new, ~{updated} updated, ={skipped} skipped (already had translation; use --force to overwrite)")
print(f"Total source strings: {len(strings)}")

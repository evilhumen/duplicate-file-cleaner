# 文件查重清理助手（duplicate-file-cleaner）

一个用于 WorkBuddy 的 Skill：按文件内容精准查找重复文件，保留最新版本，并在用户确认后安全清理。

> 适用平台：WorkBuddy。Windows 下针对回收站配额、特殊字符文件名等陷阱做了专门防护。

## 功能

- **精准查重**：按大小分组 → 首尾 64 KiB 指纹预筛 → 完整 SHA-256 比对；超大文件可选多段强采样加速。
- **保留最新**：每组重复文件保留修改时间最新的一份。
- **先报告后删除**：生成 JSON 报告 + CSV 决定清单，用户确认后才删除。
- **安全删除**：每批最多 10 个，逐批校验，失败即停；删除前预检回收站配额，不可靠时改走同盘隔离区，保证可恢复。
- **参数可调**：查重标准、日期依据、采样阈值、线程数均可配置。

## 安装

将本仓库的 `duplicate-file-cleaner` 内容放到 WorkBuddy 用户级技能目录：

```bash
# 克隆仓库
git clone https://github.com/<your-account>/duplicate-file-cleaner.git

# 复制到 WorkBuddy 技能目录
# Windows (Git Bash)
mkdir -p ~/.workbuddy/skills/duplicate-file-cleaner
cp -r duplicate-file-cleaner/* ~/.workbuddy/skills/duplicate-file-cleaner/

# macOS / Linux
mkdir -p ~/.workbuddy/skills/duplicate-file-cleaner
cp -r duplicate-file-cleaner/* ~/.workbuddy/skills/duplicate-file-cleaner/
```

重启 WorkBuddy 后即可通过自然语言触发，例如：

> 对 D:\Downloads 查重并清理，按内容判定重复，保留修改时间最新的文件。

也可以直接下载本仓库 Release 里的 `duplicate-file-cleaner.zip`，解压到上述目录。

## 目录结构

```
duplicate-file-cleaner/
├── SKILL.md                          # 技能主文档与工作流
├── scripts/
│   ├── scan_duplicates.py            # 三阶段查重扫描（只读）
│   ├── delete_duplicates.ps1         # 分批删除 + 同盘隔离区兜底
│   └── verify_recycle_bin.ps1        # Windows 回收站配额/载荷校验
└── references/
    └── windows-gotchas.md            # Windows 踩坑记录与规避方法
```

## 扫描器用法

```bash
python scripts/scan_duplicates.py "<目标文件夹>" --output "<报告目录>"
```

常用参数：

| 参数 | 说明 |
|------|------|
| `--output DIR` | 报告输出目录（必填） |
| `--skip NAME` | 跳过的顶层目录名，可重复 |
| `--workers N` | 并行线程数，默认 12 |
| `--sample-threshold N` | 超过该字节数改用强采样，默认 268435456（256 MiB），设为 0 则全部完整哈希 |
| `--min-size N` | 忽略小于该字节数的文件 |

输出：
- `dedupe_report.json`：分组详情（keep / delete 列表、判定方式）
- `dedupe_decisions.csv`：逐条决定清单，UTF-8 BOM，便于用 Excel 核对

## 删除脚本用法（Windows）

删除前务必先做回收站预检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_recycle_bin.ps1 -Drive 'G:'
```

若输出 `QUOTA_NOT_CONFIGURED` 或回收载荷为 0，说明 `SendToRecycleBin` 会退化为永久删除。此时建议加 `-QuarantineOnly`，让所有删除变成同盘可恢复的移动：

```powershell
# 先 DryRun 看目标数量
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/delete_duplicates.ps1 -Report '<报告目录>\dedupe_report.json' -DryRun

# 正式删除
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/delete_duplicates.ps1 -Report '<报告目录>\dedupe_report.json'

# 回收站不可靠时
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/delete_duplicates.ps1 -Report '<报告目录>\dedupe_report.json' -QuarantineOnly
```

## 安全设计

1. 只读扫描，绝不隐含删除。
2. 删除前展示清单并以加粗警告要求用户确认。
3. 每批不超过 10 个文件，逐批校验，失败立即停止。
4. 文件名含 `[` `]` `*` `?` 时自动改走同盘隔离区，规避 VB FileIO 的通配符解析问题。
5. 删除后校验：所有 delete 路径不存在、所有 keep 路径仍存在，并如实报告文件去向（回收站 / 隔离区 / 永久删除）。

详见 `references/windows-gotchas.md`。

## License

MIT

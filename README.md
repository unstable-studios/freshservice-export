# Freshservice Solutions → Markdown + PDF Exporter

Export all your Freshservice knowledge-base articles via the API to local Markdown and PDF files, with images and attachments downloaded alongside. Designed to run daily — uses SHA-256 hash comparison to skip unchanged articles and backs up old versions before overwriting.

Available as both a **Bash script** (macOS/Linux) and a **PowerShell script** (Windows).

## Prerequisites

### macOS / Linux (`freshservice-export.sh`)

- **curl** — HTTP requests (preinstalled)
- **jq** — JSON parsing (`brew install jq` / `apt install jq`)
- **pandoc** — HTML-to-Markdown conversion (`brew install pandoc` / `apt install pandoc`)
- **For PDF generation** (optional): a LaTeX engine or similar
  - `brew install --cask basictex` (gives you `xelatex`/`pdflatex`)
  - or `pip install weasyprint`
  - or `brew install wkhtmltopdf`

### Windows (`freshservice-export.ps1`)

- **pandoc** — https://pandoc.org/installing.html
- **For PDF generation** (optional):
  - MiKTeX (https://miktex.org/) — gives you `xelatex`/`pdflatex`
  - or wkhtmltopdf (https://wkhtmltopdf.org/)

The PowerShell version uses native `Invoke-RestMethod` and `Get-FileHash`, so no curl or jq needed.

## Quick start

### Bash (macOS/Linux)

```bash
export FRESHSERVICE_DOMAIN="your-company"    # for your-company.freshservice.com
export FRESHSERVICE_API_KEY="your-api-key"   # Profile → API Key

chmod +x freshservice-export.sh
./freshservice-export.sh
```

### PowerShell (Windows)

```powershell
$env:FRESHSERVICE_DOMAIN = "your-company"
$env:FRESHSERVICE_API_KEY = "your-api-key"

.\freshservice-export.ps1
```

## Configuration

Both scripts share the same options. Edit the variables at the top of either script, or set them as environment variables.

| Variable | Default | Description |
|---|---|---|
| `FRESHSERVICE_DOMAIN` | — | Your subdomain (e.g. `acme` for `acme.freshservice.com`) |
| `FRESHSERVICE_API_KEY` | — | Your API key (find it under your profile in Freshservice) |
| `OUTPUT_DIR` | `./freshservice-export` | Where the files land |
| `PER_PAGE` | `100` | Results per API page (max 100) |
| `RATE_LIMIT_SLEEP` | `0.5` | Seconds between API calls to avoid 429 rate limits |
| `PUBLISHED_ONLY` | `false` | Set to `true` to skip draft articles |
| `GENERATE_PDF` | `true` | Set to `false` to skip PDF generation |
| `BACKUP_ON_CHANGE` | `true` | Set to `false` to skip backing up old files before overwriting |

## Output structure

```
freshservice-export/
├── General/
│   ├── Getting-Started/
│   │   ├── assets/
│   │   │   ├── screenshot1.png
│   │   │   └── diagram.svg
│   │   ├── How-to-Reset-Your-Password.md
│   │   ├── How-to-Reset-Your-Password.pdf
│   │   └── VPN-Setup-Guide.md
│   └── Policies/
│       └── Acceptable-Use-Policy.md
├── IT-Operations/
│   └── Runbooks/
│       └── Incident-Response-Playbook.md
└── ...
```

Each Markdown file includes YAML frontmatter with metadata:

```yaml
---
title: "How to Reset Your Password"
id: 12345
folder_id: 678
created_at: 2024-03-15T10:30:00Z
updated_at: 2025-01-20T14:22:00Z
tags: [password, self-service]
status: 2
source: freshservice
---
```

## How change detection works

The script is safe to run repeatedly (e.g. on a daily cron/scheduled task):

1. Each article is fetched and converted to markdown in a temp file
2. The temp file is SHA-256 hashed and compared against the existing file
3. **Hash match** → the article is skipped entirely (no write, no PDF rebuild)
4. **Hash differs** → the old `.md` and `.pdf` are backed up with the original file's last-modified timestamp (e.g. `article.20260205-091530.bak.md`), then the new version is written
5. **New article** → written directly, no backup needed

Set `BACKUP_ON_CHANGE=false` to disable backups and just overwrite in place.

## Images and attachments

Images embedded in article HTML are automatically downloaded to an `assets/` folder next to the article, and the markdown image links are rewritten to use relative local paths (`assets/image.png`).

Explicit file attachments on articles are also downloaded to the same `assets/` folder.

## Tips

- **Large knowledge bases**: Increase `RATE_LIMIT_SLEEP` to `1` or higher to stay within API rate limits.
- **Drafts**: `PUBLISHED_ONLY` is `false` by default, so drafts are included. Set to `true` to skip them.
- **PDF engine auto-detection**: The script checks for `xelatex`, `pdflatex`, `weasyprint`, and `wkhtmltopdf` in that order. If none are found, it logs a warning and skips PDF generation.
- **Scheduling**: On macOS/Linux, add a cron entry. On Windows, use Task Scheduler to run the PowerShell script daily.

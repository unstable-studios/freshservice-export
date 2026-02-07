<#
.SYNOPSIS
    Export Freshservice Solutions (knowledge-base articles) to local Markdown
    and (optionally) PDF files, with images/attachments downloaded alongside.

.DESCRIPTION
    Walks the Freshservice Solutions hierarchy (Categories -> Folders -> Articles)
    via the API v2, converts each article's HTML body to Markdown using pandoc,
    downloads embedded images and attachments, and optionally generates PDFs.

    Features:
    - SHA-256 hash comparison: only overwrites files that actually changed
    - Backup on change: renames old files with the original file's timestamp
    - Min-content safety: refuses to write suspiciously small responses
    - PDF generation with auto-detected engine

.NOTES
    Requirements: pandoc (https://pandoc.org/installing.html)
    For PDF:      a PDF engine — xelatex, pdflatex, weasyprint, or wkhtmltopdf

.EXAMPLE
    # Set credentials and run:
    $env:FRESHSERVICE_DOMAIN = "your-company"
    $env:FRESHSERVICE_API_KEY = "your-api-key"
    .\freshservice-export.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────
$FRESHSERVICE_DOMAIN  = if ($env:FRESHSERVICE_DOMAIN)  { $env:FRESHSERVICE_DOMAIN }  else { "your-company" }
$FRESHSERVICE_API_KEY = if ($env:FRESHSERVICE_API_KEY) { $env:FRESHSERVICE_API_KEY } else { "your-api-key-here" }

$OUTPUT_DIR        = if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { ".\freshservice-export" }
$PER_PAGE          = 100
$RATE_LIMIT_MS     = 500       # milliseconds between API calls
$PUBLISHED_ONLY    = $false
$GENERATE_PDF      = $true
$BACKUP_ON_CHANGE  = $true

# ──────────────────────────────────────────────
# INTERNALS
# ──────────────────────────────────────────────
$BASE_URL = "https://${FRESHSERVICE_DOMAIN}.freshservice.com/api/v2"
$script:TOTAL_ARTICLES    = 0
$script:FAILED_ARTICLES   = 0
$script:SKIPPED_UNCHANGED = 0
$script:TOTAL_PDFS        = 0
$script:PDF_ENGINE        = ""

# Build auth header (Basic auth: api_key:X)
$AuthBytes  = [System.Text.Encoding]::ASCII.GetBytes("${FRESHSERVICE_API_KEY}:X")
$AuthBase64 = [System.Convert]::ToBase64String($AuthBytes)
$Headers    = @{ "Authorization" = "Basic $AuthBase64"; "Content-Type" = "application/json" }

# ──────────────────────────────────────────────
# Logging helpers
# ──────────────────────────────────────────────
function Log-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Log-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Log-Error { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Log-Ok    { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }

# ──────────────────────────────────────────────
# Sanitize a string for use as a directory/file name
# ──────────────────────────────────────────────
function Sanitize-Name {
    param([string]$Name)
    $safe = $Name -replace '[^a-zA-Z0-9._-]+', '-'
    $safe = $safe -replace '^-+|-+$', ''
    $safe = $safe -replace '-{2,}', '-'
    if ($safe.Length -gt 200) { $safe = $safe.Substring(0, 200) }
    return $safe
}

# ──────────────────────────────────────────────
# SHA-256 hash of a file
# ──────────────────────────────────────────────
function Get-FileHashValue {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

# ──────────────────────────────────────────────
# Preflight checks
# ──────────────────────────────────────────────
function Test-Preflight {
    # Check pandoc
    if (-not (Get-Command "pandoc" -ErrorAction SilentlyContinue)) {
        Log-Error "pandoc is not installed. Download from https://pandoc.org/installing.html"
        exit 1
    }

    # Detect PDF engine
    if ($GENERATE_PDF) {
        foreach ($engine in @("xelatex", "pdflatex", "weasyprint", "wkhtmltopdf")) {
            if (Get-Command $engine -ErrorAction SilentlyContinue) {
                $script:PDF_ENGINE = $engine
                break
            }
        }
        if ($script:PDF_ENGINE) {
            Log-Info "PDF engine: $($script:PDF_ENGINE)"
        } else {
            Log-Warn "No PDF engine found. PDF generation will be skipped."
            Log-Warn "Install MiKTeX (https://miktex.org/) or wkhtmltopdf (https://wkhtmltopdf.org/)"
            $script:GENERATE_PDF = $false
        }
    }

    # Check credentials
    if ($FRESHSERVICE_DOMAIN -eq "your-company" -or $FRESHSERVICE_API_KEY -eq "your-api-key-here") {
        Log-Error "Please set FRESHSERVICE_DOMAIN and FRESHSERVICE_API_KEY."
        Log-Error '  $env:FRESHSERVICE_DOMAIN = "acme"'
        Log-Error '  $env:FRESHSERVICE_API_KEY = "abcdef123456"'
        exit 1
    }
}

# ──────────────────────────────────────────────
# API helper — handles pagination automatically
# Returns: array of all results across pages
# ──────────────────────────────────────────────
function Invoke-FreshserviceApi {
    param(
        [string]$Endpoint,
        [string]$ResultKey
    )
    $page = 1
    $allResults = @()

    while ($true) {
        $separator = if ($Endpoint.Contains("?")) { "&" } else { "?" }
        $url = "${BASE_URL}${Endpoint}${separator}per_page=${PER_PAGE}&page=${page}"

        try {
            $response = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -ErrorAction Stop
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode) {
                Log-Error "API returned HTTP $statusCode for $url"
            } else {
                Log-Error "Request failed for $url : $($_.Exception.Message)"
            }
            return @()
        }

        # Extract the array from the response using the key
        $pageResults = $response.$ResultKey
        if (-not $pageResults -or $pageResults.Count -eq 0) {
            break
        }

        $allResults += $pageResults

        if ($pageResults.Count -lt $PER_PAGE) {
            break
        }

        $page++
        Start-Sleep -Milliseconds $RATE_LIMIT_MS
    }

    return $allResults
}

# ──────────────────────────────────────────────
# Download images from HTML, rewrite paths, convert to Markdown
# ──────────────────────────────────────────────
function Convert-HtmlToMarkdownWithImages {
    param(
        [string]$Html,
        [string]$AssetsDir
    )

    if (-not (Test-Path $AssetsDir)) {
        New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
    }

    $modifiedHtml = $Html

    # Extract image src URLs from HTML
    $matches_found = [regex]::Matches($Html, 'src="([^"]+)"')
    $urls = @()
    foreach ($m in $matches_found) {
        $url = $m.Groups[1].Value
        # Skip data URIs
        if ($url -match '^data:') { continue }
        # Keep if it's an image extension or a Freshservice URL
        if ($url -match '\.(png|jpg|jpeg|gif|svg|webp|bmp)(\?|$)' -or $url -match 'freshservice') {
            $urls += $url
        }
    }
    $urls = $urls | Select-Object -Unique

    $counter = 0
    foreach ($url in $urls) {
        if (-not $url) { continue }
        $counter++

        # Determine filename
        try {
            $filename = [System.IO.Path]::GetFileName(([Uri]$url).LocalPath)
        } catch {
            $filename = "image-$counter.png"
        }
        if (-not $filename -or $filename -notmatch '\.') {
            $filename = "image-$counter.png"
        }
        $filename = Sanitize-Name $filename

        # Download the image
        $outPath = Join-Path $AssetsDir $filename
        try {
            Invoke-WebRequest -Uri $url -Headers $Headers -OutFile $outPath -ErrorAction Stop 2>$null
            # Rewrite the URL in HTML to the local relative path
            $modifiedHtml = $modifiedHtml.Replace($url, "assets/$filename")
        } catch {
            Log-Warn "  Failed to download image: $url"
        }
    }

    # Convert HTML to Markdown using pandoc
    $tempHtml = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempHtml, $modifiedHtml, [System.Text.Encoding]::UTF8)

    try {
        $markdown = & pandoc -f html -t gfm --wrap=none $tempHtml 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log-Warn "  pandoc conversion issue"
        }
    } catch {
        Log-Warn "  pandoc conversion failed: $($_.Exception.Message)"
        $markdown = ""
    } finally {
        Remove-Item $tempHtml -Force -ErrorAction SilentlyContinue
    }

    return ($markdown | Out-String)
}

# ──────────────────────────────────────────────
# Download file attachments listed in the article
# ──────────────────────────────────────────────
function Save-Attachments {
    param(
        [object]$Article,
        [string]$AssetsDir
    )

    if (-not (Test-Path $AssetsDir)) {
        New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
    }

    $attachments = $Article.attachments
    if (-not $attachments -or $attachments.Count -eq 0) { return }

    Log-Info "    Downloading $($attachments.Count) attachment(s)..."

    foreach ($att in $attachments) {
        $attUrl  = $att.attachment_url
        $attName = $att.name
        if (-not $attUrl) { continue }

        $attName = Sanitize-Name $attName
        $outPath = Join-Path $AssetsDir $attName

        try {
            Invoke-WebRequest -Uri $attUrl -Headers $Headers -OutFile $outPath -ErrorAction Stop 2>$null
            Log-Ok "    Downloaded attachment: $attName"
        } catch {
            Log-Warn "    Failed to download attachment: $attName"
        }
    }
}

# ──────────────────────────────────────────────
# Process a single folder and export its articles
# ──────────────────────────────────────────────
function Process-Folder {
    param(
        [object]$Folder,
        [string]$ParentDir
    )

    $folderId   = $Folder.id
    $folderName = if ($Folder.name) { $Folder.name } else { "Unnamed-Folder" }
    $safeFolderName = Sanitize-Name $folderName

    $folderDir = Join-Path $ParentDir $safeFolderName
    if (-not (Test-Path $folderDir)) {
        New-Item -ItemType Directory -Path $folderDir -Force | Out-Null
    }

    Log-Info "  Folder: $folderName (id: $folderId)"

    # Fetch articles in this folder
    $articles = Invoke-FreshserviceApi -Endpoint "/solutions/articles?folder_id=$folderId" -ResultKey "articles"
    $articleCount = if ($articles) { $articles.Count } else { 0 }

    Log-Info "    Found $articleCount article(s)"

    foreach ($article in $articles) {
        $artId     = $article.id
        $artTitle  = if ($article.title) { $article.title } else { "Untitled" }
        $artStatus = if ($article.status) { $article.status } else { 1 }

        # Skip drafts if configured
        if ($PUBLISHED_ONLY -and $artStatus -ne 2) {
            Log-Info "    Skipping draft: $artTitle"
            continue
        }

        Log-Info "    Processing: $artTitle"

        # Fetch full article details
        try {
            $fullResponse = Invoke-RestMethod -Uri "${BASE_URL}/solutions/articles/${artId}" -Headers $Headers -Method Get
            $fullArticle = if ($fullResponse.article) { $fullResponse.article } else { $fullResponse }
        } catch {
            Log-Warn "    Failed to fetch article $artId, skipping"
            $script:FAILED_ARTICLES++
            continue
        }

        $description = $fullArticle.description
        if (-not $description) {
            Log-Warn "    Article has no content, skipping: $artTitle"
            $script:FAILED_ARTICLES++
            continue
        }

        $safeTitle = Sanitize-Name $artTitle
        $mdPath    = Join-Path $folderDir "$safeTitle.md"
        $assetsDir = Join-Path $folderDir "assets"

        # ── Build new content into a temp file ──
        $tmpMd = [System.IO.Path]::GetTempFileName()

        $createdAt = $fullArticle.created_at
        $updatedAt = $fullArticle.updated_at
        $tags = if ($fullArticle.tags) { ($fullArticle.tags -join ", ") } else { "" }

        # Build frontmatter
        $frontmatter = @("---")
        $frontmatter += "title: `"$($artTitle -replace '"', '\"')`""
        $frontmatter += "id: $artId"
        $frontmatter += "folder_id: $folderId"
        if ($createdAt) { $frontmatter += "created_at: $createdAt" }
        if ($updatedAt) { $frontmatter += "updated_at: $updatedAt" }
        if ($tags)      { $frontmatter += "tags: [$tags]" }
        $frontmatter += "status: $artStatus"
        $frontmatter += "source: freshservice"
        $frontmatter += "---"
        $frontmatter += ""
        $frontmatter += "# $artTitle"
        $frontmatter += ""

        $frontmatterText = $frontmatter -join "`n"

        # Convert HTML to Markdown, downloading images along the way
        $markdownBody = Convert-HtmlToMarkdownWithImages -Html $description -AssetsDir $assetsDir

        $fullContent = $frontmatterText + $markdownBody
        [System.IO.File]::WriteAllText($tmpMd, $fullContent, [System.Text.Encoding]::UTF8)

        # ── Hash compare: only write if content actually changed ──
        $needsWrite = $true
        if (Test-Path $mdPath) {
            $oldHash = Get-FileHashValue -Path $mdPath
            $newHash = Get-FileHashValue -Path $tmpMd
            if ($oldHash -eq $newHash) {
                Log-Info "    Unchanged (hash match), skipping: $(Split-Path $mdPath -Leaf)"
                $script:SKIPPED_UNCHANGED++
                $needsWrite = $false
            } else {
                Log-Info "    Content changed, updating: $(Split-Path $mdPath -Leaf)"
                # Back up the old file before overwriting
                if ($BACKUP_ON_CHANGE) {
                    # Use the existing file's last-modified date as the backup timestamp
                    $fileDate = (Get-Item $mdPath).LastWriteTime.ToString("yyyyMMdd-HHmmss")
                    $backupPath = $mdPath -replace '\.md$', ".$fileDate.bak.md"
                    Copy-Item $mdPath $backupPath
                    Log-Info "    Backed up: $(Split-Path $backupPath -Leaf)"
                    # Also back up the old PDF if it exists
                    $oldPdf = $mdPath -replace '\.md$', '.pdf'
                    if (Test-Path $oldPdf) {
                        $pdfBackup = $oldPdf -replace '\.pdf$', ".$fileDate.bak.pdf"
                        Copy-Item $oldPdf $pdfBackup
                    }
                }
            }
        }

        if ($needsWrite) {
            Move-Item $tmpMd $mdPath -Force

            # Download any explicit attachments
            Save-Attachments -Article $fullArticle -AssetsDir $assetsDir

            $script:TOTAL_ARTICLES++
            Log-Ok "    Saved: $mdPath"

            # Generate PDF from the markdown file
            if ($GENERATE_PDF -and $script:PDF_ENGINE) {
                $pdfPath = $mdPath -replace '\.md$', '.pdf'
                $mdFilename  = Split-Path $mdPath -Leaf
                $pdfFilename = Split-Path $pdfPath -Leaf

                try {
                    Push-Location $folderDir
                    $pdfErr = & pandoc $mdFilename -o $pdfFilename `
                        --pdf-engine="$($script:PDF_ENGINE)" `
                        -V geometry:margin=1in `
                        -V colorlinks=true `
                        --resource-path="." 2>&1

                    if ($LASTEXITCODE -eq 0) {
                        $script:TOTAL_PDFS++
                        Log-Ok "    Saved: $pdfPath"
                    } else {
                        Log-Warn "    PDF generation failed: $pdfErr"
                    }
                } catch {
                    Log-Warn "    PDF generation failed: $($_.Exception.Message)"
                } finally {
                    Pop-Location
                }
            }
        } else {
            Remove-Item $tmpMd -Force -ErrorAction SilentlyContinue
        }

        Start-Sleep -Milliseconds $RATE_LIMIT_MS
    }
}

# ──────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────
function Main {
    Test-Preflight

    Log-Info "Starting Freshservice Solutions export..."
    Log-Info "Domain: ${FRESHSERVICE_DOMAIN}.freshservice.com"
    Log-Info "Output: ${OUTPUT_DIR}"
    Write-Host ""

    if (-not (Test-Path $OUTPUT_DIR)) {
        New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
    }

    # 1. Fetch all categories
    Log-Info "Fetching categories..."
    $categories = Invoke-FreshserviceApi -Endpoint "/solutions/categories" -ResultKey "categories"
    $catCount = if ($categories) { $categories.Count } else { 0 }

    if ($catCount -eq 0) {
        Log-Warn "No solution categories found. Check your API key and domain."
        exit 1
    }

    Log-Info "Found $catCount category/categories"
    Write-Host ""

    # 2. Walk each category
    foreach ($category in $categories) {
        $catId   = $category.id
        $catName = if ($category.name) { $category.name } else { "Unnamed-Category" }
        $safeCatName = Sanitize-Name $catName

        $catDir = Join-Path $OUTPUT_DIR $safeCatName
        if (-not (Test-Path $catDir)) {
            New-Item -ItemType Directory -Path $catDir -Force | Out-Null
        }

        Log-Info "Category: $catName (id: $catId)"

        # 3. Fetch folders in this category
        $folders = Invoke-FreshserviceApi -Endpoint "/solutions/folders?category_id=$catId" -ResultKey "folders"
        $folderCount = if ($folders) { $folders.Count } else { 0 }

        Log-Info "  Found $folderCount folder(s)"

        foreach ($folder in $folders) {
            Process-Folder -Folder $folder -ParentDir $catDir
        }

        Write-Host ""
    }

    # Summary
    Write-Host ""
    Write-Host ("=" * 40)
    Log-Ok "Export complete!"
    Log-Info "Markdown files:  $($script:TOTAL_ARTICLES)"
    if ($GENERATE_PDF)              { Log-Info "PDF files:       $($script:TOTAL_PDFS)" }
    if ($script:SKIPPED_UNCHANGED -gt 0) { Log-Info "Unchanged:       $($script:SKIPPED_UNCHANGED)" }
if ($script:FAILED_ARTICLES -gt 0)   { Log-Warn "Skipped (empty):  $($script:FAILED_ARTICLES)" }
    Log-Info "Output directory: $OUTPUT_DIR"
    Write-Host ("=" * 40)
}

Main

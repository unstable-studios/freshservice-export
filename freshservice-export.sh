#!/usr/bin/env bash
#
# freshservice-export.sh
# ----------------------
# Export Freshservice Solutions (knowledge-base articles) to local Markdown
# and (optionally) PDF files, with images/attachments downloaded alongside.
#
# Requirements: curl, jq, pandoc
# For PDF:      a PDF engine — xelatex, pdflatex, weasyprint, or wkhtmltopdf
# Auth: Freshservice API v2 — Basic auth with your API key
#
# Usage:
#   1. Set FRESHSERVICE_DOMAIN and FRESHSERVICE_API_KEY below (or export them).
#   2. chmod +x freshservice-export.sh
#   3. ./freshservice-export.sh
#
# Output structure:
#   output/
#   ├── Category-Name/
#   │   ├── Folder-Name/
#   │   │   ├── assets/           ← downloaded images & attachments
#   │   │   ├── article-title.md
#   │   │   └── another-article.md
#   │   └── Another-Folder/
#   │       └── ...
#   └── ...
#
set -euo pipefail

# ──────────────────────────────────────────────
# CONFIGURATION — edit these or export as env vars
# ──────────────────────────────────────────────
FRESHSERVICE_DOMAIN="${FRESHSERVICE_DOMAIN:-your-company}"          # e.g. "acme" for acme.freshservice.com
FRESHSERVICE_API_KEY="${FRESHSERVICE_API_KEY:-your-api-key-here}"   # Settings → API key

OUTPUT_DIR="${OUTPUT_DIR:-./freshservice-export}"
PER_PAGE=100          # max allowed by Freshservice
RATE_LIMIT_SLEEP=0.5  # seconds between API calls (avoid 429s)
PUBLISHED_ONLY=false  # set to true to skip draft articles
GENERATE_PDF=true     # set to false to skip PDF generation
BACKUP_ON_CHANGE=true # set to false to skip backing up old files before overwriting

# ──────────────────────────────────────────────
# INTERNALS
# ──────────────────────────────────────────────
BASE_URL="https://${FRESHSERVICE_DOMAIN}.freshservice.com/api/v2"
AUTH="${FRESHSERVICE_API_KEY}:X"
TOTAL_ARTICLES=0
FAILED_ARTICLES=0
SKIPPED_UNCHANGED=0
TOTAL_PDFS=0
PDF_ENGINE=""

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Portable hash function (macOS uses shasum, Linux uses sha256sum)
file_hash() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

log()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# ──────────────────────────────────────────────
# Preflight checks
# ──────────────────────────────────────────────
preflight() {
    local missing=()
    for cmd in curl jq pandoc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
        err "Install them and try again."
        exit 1
    fi

    # Detect a PDF engine if PDF generation is enabled
    if [[ "$GENERATE_PDF" == "true" ]]; then
        if command -v xelatex &>/dev/null; then
            PDF_ENGINE="xelatex"
        elif command -v pdflatex &>/dev/null; then
            PDF_ENGINE="pdflatex"
        elif command -v weasyprint &>/dev/null; then
            PDF_ENGINE="weasyprint"
        elif command -v wkhtmltopdf &>/dev/null; then
            PDF_ENGINE="wkhtmltopdf"
        else
            warn "No PDF engine found. PDF generation will be skipped."
            warn "Install one of: basictex (brew install --cask basictex),"
            warn "  weasyprint (pip install weasyprint), or wkhtmltopdf (brew install wkhtmltopdf)"
            GENERATE_PDF=false
        fi

        if [[ -n "$PDF_ENGINE" ]]; then
            log "PDF engine: $PDF_ENGINE"
        fi
    fi

    if [[ "$FRESHSERVICE_DOMAIN" == "your-company" || "$FRESHSERVICE_API_KEY" == "your-api-key-here" ]]; then
        err "Please set FRESHSERVICE_DOMAIN and FRESHSERVICE_API_KEY."
        err "Either edit this script or export them as environment variables:"
        err "  export FRESHSERVICE_DOMAIN=acme"
        err "  export FRESHSERVICE_API_KEY=abcdef123456"
        exit 1
    fi
}

# ──────────────────────────────────────────────
# API helper — handles pagination automatically
# Returns: JSON array of all results across pages
# Args: $1 = endpoint path (relative to BASE_URL)
#        $2 = jq key to extract array from (e.g. ".categories")
# ──────────────────────────────────────────────
api_get_all() {
    local endpoint="$1"
    local jq_key="$2"
    local page=1
    local all_results="[]"

    while true; do
        # Build URL with pagination
        local separator="?"
        [[ "$endpoint" == *"?"* ]] && separator="&"
        local url="${BASE_URL}${endpoint}${separator}per_page=${PER_PAGE}&page=${page}"

        local response
        response=$(curl -sS -w "\n%{http_code}" -u "$AUTH" \
            -H "Content-Type: application/json" "$url" 2>&1) || {
            err "curl failed for $url"
            echo "[]"
            return 1
        }

        # Split response body and HTTP status code
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')

        # Check for errors
        if [[ "$http_code" -ge 400 ]]; then
            err "API returned HTTP $http_code for $url"
            err "Response: $body"
            echo "[]"
            return 1
        fi

        # Extract the relevant array
        local page_results
        page_results=$(echo "$body" | jq -r "$jq_key // []") || {
            warn "Could not parse JSON from $url"
            break
        }

        local count
        count=$(echo "$page_results" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            break
        fi

        # Merge into running results
        all_results=$(echo "$all_results" "$page_results" | jq -s '.[0] + .[1]')

        # If we got fewer than PER_PAGE, we've reached the last page
        if [[ "$count" -lt "$PER_PAGE" ]]; then
            break
        fi

        page=$((page + 1))
        sleep "$RATE_LIMIT_SLEEP"
    done

    echo "$all_results"
}

# ──────────────────────────────────────────────
# Sanitize a string for use as a directory/file name
# ──────────────────────────────────────────────
sanitize_name() {
    echo "$1" | sed -E 's/[^a-zA-Z0-9._-]+/-/g; s/^-+|-+$//g; s/-{2,}/-/g' | head -c 200
}

# ──────────────────────────────────────────────
# Download images from HTML, rewrite paths, convert to Markdown
# Args: $1 = HTML content
#        $2 = output directory for assets
#        $3 = article markdown file path (for relative links)
# Prints: converted markdown with local image paths
# ──────────────────────────────────────────────
html_to_markdown_with_images() {
    local html="$1"
    local assets_dir="$2"
    local md_file="$3"

    mkdir -p "$assets_dir"

    # Extract image URLs from the HTML (skip data: URIs)
    # Use grep -oE (POSIX extended) + sed instead of grep -P (Perl) for macOS compatibility
    local img_urls
    img_urls=$(echo "$html" | grep -oE 'src="[^"]+"' | sed 's/^src="//;s/"$//' \
        | grep -v '^data:' \
        | grep -iE '\.(png|jpg|jpeg|gif|svg|webp|bmp)(\?[^"]*)?$' || true)

    # Also grab images from Freshservice attachment URLs (which may not have extensions)
    local attachment_urls
    attachment_urls=$(echo "$html" | grep -oE 'src="[^"]+"' | sed 's/^src="//;s/"$//' \
        | grep -v '^data:' \
        | grep -i 'freshservice' || true)

    # Combine and deduplicate
    local all_urls
    all_urls=$(echo -e "${img_urls}\n${attachment_urls}" | sort -u | grep -v '^$' || true)

    local modified_html="$html"

    if [[ -n "$all_urls" ]]; then
        local counter=0
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            counter=$((counter + 1))

            # Determine filename
            local filename
            filename=$(basename "$url" | sed 's/\?.*//')  # strip query params
            # If no extension, default to .png
            if [[ ! "$filename" =~ \. ]]; then
                filename="image-${counter}.png"
            fi
            # Sanitize
            filename=$(sanitize_name "$filename")

            # Download the image
            if curl -sS -L -u "$AUTH" -o "${assets_dir}/${filename}" "$url" 2>/dev/null; then
                # Rewrite the URL in HTML to the local relative path
                # Escape ALL sed special chars in the URL: \ & | . * [ ] ^ $ ( ) { } + ?
                local escaped_url
                escaped_url=$(printf '%s' "$url" | sed 's/[\\&|.*^$()\[\]{}\+\?]/\\&/g')
                local escaped_path
                escaped_path=$(printf '%s' "assets/${filename}")
                modified_html=$(echo "$modified_html" | sed "s|${escaped_url}|${escaped_path}|g")
            else
                warn "  Failed to download image: $url"
            fi
        done <<< "$all_urls"
    fi

    # Convert HTML to Markdown using pandoc
    local pandoc_output pandoc_err
    pandoc_err=$(mktemp)
    pandoc_output=$(echo "$modified_html" | pandoc -f html -t gfm --wrap=none 2>"$pandoc_err") || {
        warn "  pandoc conversion issue: $(cat "$pandoc_err")"
    }
    rm -f "$pandoc_err"
    echo "$pandoc_output"
}

# ──────────────────────────────────────────────
# Download file attachments listed in the article JSON
# Args: $1 = article JSON, $2 = assets directory
# ──────────────────────────────────────────────
download_attachments() {
    local article_json="$1"
    local assets_dir="$2"

    mkdir -p "$assets_dir"

    # Check if attachments array exists and is non-empty
    local attachments
    attachments=$(echo "$article_json" | jq -r '.attachments // []')
    local count
    count=$(echo "$attachments" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        return
    fi

    log "    Downloading $count attachment(s)..."

    for i in $(seq 0 $((count - 1))); do
        local att_url att_name
        att_url=$(echo "$attachments" | jq -r ".[$i].attachment_url // empty")
        att_name=$(echo "$attachments" | jq -r ".[$i].name // \"attachment-$i\"")

        if [[ -n "$att_url" ]]; then
            att_name=$(sanitize_name "$att_name")
            if curl -sS -L -u "$AUTH" -o "${assets_dir}/${att_name}" "$att_url" 2>/dev/null; then
                ok "    Downloaded attachment: $att_name"
            else
                warn "    Failed to download attachment: $att_name"
            fi
        fi
    done
}

# ──────────────────────────────────────────────
# Process a single folder and export its articles
# Args: $1 = folder JSON object
#        $2 = parent output directory path
# Note: Freshservice API v2 does not expose a subfolders endpoint.
#       All folders (including nested) are returned by the category listing.
# ──────────────────────────────────────────────
process_folder() {
    local folder_json="$1"
    local parent_dir="$2"

    local folder_id folder_name
    folder_id=$(echo "$folder_json" | jq -r '.id')
    folder_name=$(echo "$folder_json" | jq -r '.name // "Unnamed-Folder"')
    local safe_folder_name
    safe_folder_name=$(sanitize_name "$folder_name")

    local folder_dir="${parent_dir}/${safe_folder_name}"
    mkdir -p "$folder_dir"

    log "  Folder: $folder_name (id: $folder_id)"

    # Fetch articles in this folder
    local articles
    articles=$(api_get_all "/solutions/articles?folder_id=${folder_id}" ".articles")
    local article_count
    article_count=$(echo "$articles" | jq 'length')

    log "    Found $article_count article(s)"

    for i in $(seq 0 $((article_count - 1))); do
        local article
        article=$(echo "$articles" | jq ".[$i]")

        local art_id art_title art_status
        art_id=$(echo "$article" | jq -r '.id')
        art_title=$(echo "$article" | jq -r '.title // "Untitled"')
        art_status=$(echo "$article" | jq -r '.status // 1')

        # Skip drafts if PUBLISHED_ONLY is true
        # Status: 1=draft, 2=published
        if [[ "$PUBLISHED_ONLY" == "true" && "$art_status" != "2" ]]; then
            log "    Skipping draft: $art_title"
            continue
        fi

        log "    Processing: $art_title"

        # Fetch full article details (the list endpoint may not include full body)
        local full_article
        full_article=$(curl -sS -u "$AUTH" -H "Content-Type: application/json" \
            "${BASE_URL}/solutions/articles/${art_id}" 2>/dev/null)

        # Extract the article object from the response wrapper
        full_article=$(echo "$full_article" | jq '.article // .')

        local description
        description=$(echo "$full_article" | jq -r '.description // ""')

        if [[ -z "$description" || "$description" == "null" ]]; then
            warn "    Article has no content, skipping: $art_title"
            FAILED_ARTICLES=$((FAILED_ARTICLES + 1))
            continue
        fi

        local safe_title
        safe_title=$(sanitize_name "$art_title")
        local md_path="${folder_dir}/${safe_title}.md"
        local assets_dir="${folder_dir}/assets"

        # ── Build new content into a temp file ──
        local tmp_md
        tmp_md=$(mktemp)

        local created_at updated_at
        created_at=$(echo "$full_article" | jq -r '.created_at // ""')
        updated_at=$(echo "$full_article" | jq -r '.updated_at // ""')
        local tags
        tags=$(echo "$full_article" | jq -r '(.tags // []) | join(", ")')

        {
            echo "---"
            echo "title: $(echo "$art_title" | jq -R .)"
            echo "id: $art_id"
            echo "folder_id: $folder_id"
            [[ -n "$created_at" && "$created_at" != "null" ]] && echo "created_at: $created_at"
            [[ -n "$updated_at" && "$updated_at" != "null" ]] && echo "updated_at: $updated_at"
            [[ -n "$tags" ]] && echo "tags: [$tags]"
            echo "status: $art_status"
            echo "source: freshservice"
            echo "---"
            echo ""
            echo "# $art_title"
            echo ""
        } > "$tmp_md"

        # Convert HTML to Markdown, downloading images along the way
        local markdown_body
        markdown_body=$(html_to_markdown_with_images "$description" "$assets_dir" "$tmp_md")
        echo "$markdown_body" >> "$tmp_md"

        # ── Hash compare: only write if content actually changed ──
        local needs_write=true
        if [[ -f "$md_path" ]]; then
            local old_hash new_hash
            old_hash=$(file_hash "$md_path")
            new_hash=$(file_hash "$tmp_md")
            if [[ "$old_hash" == "$new_hash" ]]; then
                log "    Unchanged (hash match), skipping: $(basename "$md_path")"
                SKIPPED_UNCHANGED=$((SKIPPED_UNCHANGED + 1))
                needs_write=false
            else
                log "    Content changed, updating: $(basename "$md_path")"
                # Back up the old file before overwriting
                if [[ "$BACKUP_ON_CHANGE" == "true" ]]; then
                    # Use the existing file's last-modified date as the backup timestamp
                    local timestamp
                    timestamp=$(stat -f '%Sm' -t '%Y%m%d-%H%M%S' "$md_path" 2>/dev/null \
                             || stat -c '%y' "$md_path" 2>/dev/null | sed 's/[- :]//g; s/\..*//; s/\(....\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3-\4\5\6/')
                    local backup_path="${md_path%.md}.${timestamp}.bak.md"
                    cp "$md_path" "$backup_path"
                    log "    Backed up: $(basename "$backup_path")"
                    # Also back up the old PDF if it exists
                    local old_pdf="${md_path%.md}.pdf"
                    if [[ -f "$old_pdf" ]]; then
                        cp "$old_pdf" "${old_pdf%.pdf}.${timestamp}.bak.pdf"
                    fi
                fi
            fi
        fi

        if [[ "$needs_write" == "true" ]]; then
            mv "$tmp_md" "$md_path"

            # Download any explicit attachments
            download_attachments "$full_article" "$assets_dir"

            TOTAL_ARTICLES=$((TOTAL_ARTICLES + 1))
            ok "    Saved: $md_path"

            # Generate PDF from the markdown file
            if [[ "$GENERATE_PDF" == "true" ]]; then
                local pdf_path="${md_path%.md}.pdf"
                local pdf_err
                pdf_err=$(mktemp)

                if (cd "$folder_dir" && pandoc "$(basename "$md_path")" \
                        -o "$(basename "$pdf_path")" \
                        --pdf-engine="$PDF_ENGINE" \
                        -V geometry:margin=1in \
                        -V colorlinks=true \
                        --resource-path="." \
                        2>"$pdf_err"); then
                    TOTAL_PDFS=$((TOTAL_PDFS + 1))
                    ok "    Saved: $pdf_path"
                else
                    warn "    PDF generation failed: $(cat "$pdf_err")"
                fi
                rm -f "$pdf_err"
            fi
        else
            rm -f "$tmp_md"
        fi

        sleep "$RATE_LIMIT_SLEEP"
    done

}

# ──────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────
main() {
    preflight

    log "Starting Freshservice Solutions export..."
    log "Domain: ${FRESHSERVICE_DOMAIN}.freshservice.com"
    log "Output: ${OUTPUT_DIR}"
    echo ""

    mkdir -p "$OUTPUT_DIR"

    # 1. Fetch all categories
    log "Fetching categories..."
    local categories
    categories=$(api_get_all "/solutions/categories" ".categories")
    local cat_count
    cat_count=$(echo "$categories" | jq 'length')

    if [[ "$cat_count" -eq 0 ]]; then
        warn "No solution categories found. Check your API key and domain."
        exit 1
    fi

    log "Found $cat_count category/categories"
    echo ""

    # 2. Walk each category
    for i in $(seq 0 $((cat_count - 1))); do
        local category cat_id cat_name
        category=$(echo "$categories" | jq ".[$i]")
        cat_id=$(echo "$category" | jq -r '.id')
        cat_name=$(echo "$category" | jq -r '.name // "Unnamed-Category"')
        local safe_cat_name
        safe_cat_name=$(sanitize_name "$cat_name")

        local cat_dir="${OUTPUT_DIR}/${safe_cat_name}"
        mkdir -p "$cat_dir"

        log "Category: $cat_name (id: $cat_id)"

        # 3. Fetch folders in this category
        local folders
        folders=$(api_get_all "/solutions/folders?category_id=${cat_id}" ".folders")
        local folder_count
        folder_count=$(echo "$folders" | jq 'length')

        log "  Found $folder_count folder(s)"

        for j in $(seq 0 $((folder_count - 1))); do
            local folder
            folder=$(echo "$folders" | jq ".[$j]")
            process_folder "$folder" "$cat_dir"
        done

        echo ""
    done

    # Summary
    echo ""
    echo "═══════════════════════════════════════"
    ok "Export complete!"
    log "Markdown files:  $TOTAL_ARTICLES"
    [[ "$GENERATE_PDF" == "true" ]] && log "PDF files:       $TOTAL_PDFS"
    [[ "$SKIPPED_UNCHANGED" -gt 0 ]] && log "Unchanged:       $SKIPPED_UNCHANGED"
[[ "$FAILED_ARTICLES" -gt 0 ]] && warn "Skipped (empty):  $FAILED_ARTICLES"
    log "Output directory: $OUTPUT_DIR"
    echo "═══════════════════════════════════════"
}

main "$@"

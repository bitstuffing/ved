# Offline Windows Update catalog discovery and staging, written entirely in
# Bash. No Python interpreter and no third-party Python modules are involved:
# HTTPS uses curl (or wget) and every parser is sed/awk/grep/od.
#
# This file is sourced by lib/backends/powershell.sh. It can also be run
# directly for diagnostics:
#   bash lib/windows_update.sh --windows-root /mnt/win --stage-dir /mnt/win/VEDUpdates
# Nothing here ever applies an update; DISM runs later from booted Windows.

WU_USER_AGENT='Mozilla/5.0 (compatible; ved-windows-update/1.0)'
WU_COOKIE_JAR=""
WU_PE_VERSION=""
WU_PE_ARCH=""
WU_CURRENT_VERSION=""
WU_ARCH=""
WU_PRODUCT=""
WU_PACKAGE_NAMES=""
WU_PACKAGE_URLS=""

# ---------------------------------------------------------------------------
# Version helpers. Versions are major.minor.build.revision strings so they can
# be compared component by component without bc or Python.
# ---------------------------------------------------------------------------

# Microsoft servicing packages write versions as build.revision.branch.revision
# (for example 26100.9711.1.30), while PE version resources and the catalog use
# 10.0.build.revision. Normalize both forms before comparing or filtering.
windows_update_normalize_version() {
    local value="$1" major=0 minor=0 build=0 revision=0
    local -a parts=()
    local IFS='.'
    read -r -a parts <<<"$value"
    major="${parts[0]:-0}"
    minor="${parts[1]:-0}"
    build="${parts[2]:-0}"
    revision="${parts[3]:-0}"
    if ((major >= 10000)); then
        printf '10.0.%s.%s' "$major" "$minor"
        return
    fi
    printf '%s.%s.%s.%s' "$major" "$minor" "$build" "$revision"
}

windows_update_pad_version() {
    local value
    value="$(windows_update_normalize_version "$1")"
    printf '%s' "$value"
}

windows_update_version_ge() {
    local left="$1" right="$2" i
    local -a lhs=() rhs=()
    local IFS='.'
    read -r -a lhs <<<"$left"
    read -r -a rhs <<<"$right"
    for ((i = 0; i < 4; i++)); do
        if (( ${lhs[i]:-0} > ${rhs[i]:-0} )); then
            return 0
        fi
        if (( ${lhs[i]:-0} < ${rhs[i]:-0} )); then
            return 1
        fi
    done
    return 0
}

windows_update_parse_build() {
    windows_update_normalize_version "$1"
}

windows_update_product() {
    local major=0 minor=0 build=0 revision=0 normalized
    local IFS='.'
    normalized="$(windows_update_normalize_version "$1")"
    read -r major minor build revision <<<"$normalized"
    if (( build >= 22000 )); then
        printf 'Windows 11'
    else
        printf 'Windows 10'
    fi
}

windows_update_display_version() {
    case "$1" in
        10240) printf '1507' ;;
        10586) printf '1511' ;;
        14393) printf '1607' ;;
        15063) printf '1703' ;;
        16299) printf '1709' ;;
        17134) printf '1803' ;;
        17763) printf '1809' ;;
        18362) printf '19H1' ;;
        18363) printf '19H2' ;;
        19041) printf '2004' ;;
        19042) printf '20H2' ;;
        19043) printf '21H1' ;;
        19044) printf '21H2' ;;
        19045) printf '22H2' ;;
        22000) printf '21H2' ;;
        22621) printf '22H2' ;;
        22631) printf '23H2' ;;
        26100) printf '24H2' ;;
        26200) printf '25H2' ;;
        28000) printf '26H2' ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Reading the offline build. The PE version resource of ntoskrnl.exe is the
# primary source; the versions embedded in servicing .mum filenames are a more
# precise fallback (they carry the installed UBR). The newest of the two wins.
# ---------------------------------------------------------------------------

# Print an unsigned little-endian integer read from a file at a byte offset.
windows_update_read_le() {
    local file="$1" offset="$2" count="$3" i value=0
    local -a bytes=()
    mapfile -t bytes < <(
        od -An -v -tu1 -j "$offset" -N "$count" "$file" 2>/dev/null |
            tr -s '[:space:]' '\n' | sed '/^$/d'
    )
    for ((i = 0; i < ${#bytes[@]}; i++)); do
        value=$((value + bytes[i] * (1 << (8 * i))))
    done
    printf '%d' "$value"
}

# Locate the VS_FIXEDFILEINFO signature without loading the whole file into
# shell memory. GNU grep is fast; the od/awk path covers minimal grep builds.
windows_update_version_signature_offset() {
    local file="$1"
    if printf '\xbd\x04\xef\xfe' | LC_ALL=C grep -qP '\xBD\x04\xEF\xFE' 2>/dev/null; then
        LC_ALL=C grep -aobP '\xBD\x04\xEF\xFE' "$file" 2>/dev/null |
            head -n1 | cut -d: -f1
        return 0
    fi
    LC_ALL=C od -An -v -tu1 "$file" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF - 3; i++) {
                if ($i == 189 && $(i + 1) == 4 &&
                    $(i + 2) == 239 && $(i + 3) == 254) {
                    print (NR - 1) * 16 + i - 1
                    exit
                }
            }
        }
    ' | head -n1
}

# Set WU_PE_VERSION and WU_PE_ARCH from a PE image.
windows_update_pe_version() {
    local kernel="$1" pe_offset machine sig_offset
    local file_ms file_ls product_ms product_ls major minor build revision

    [[ -f "$kernel" ]] || return 1
    [[ "$(LC_ALL=C dd if="$kernel" bs=2 count=1 status=none 2>/dev/null)" == "MZ" ]] ||
        return 1

    pe_offset="$(windows_update_read_le "$kernel" 60 4)"
    ((pe_offset > 0)) || return 1
    machine="$(windows_update_read_le "$kernel" "$((pe_offset + 4))" 2)"
    case "$machine" in
        332)   WU_PE_ARCH='x86' ;;
        34404) WU_PE_ARCH='x64' ;;
        43620) WU_PE_ARCH='arm64' ;;
        *)     WU_PE_ARCH='x64' ;;
    esac

    sig_offset="$(windows_update_version_signature_offset "$kernel")"
    [[ -n "$sig_offset" ]] || return 1
    file_ms="$(windows_update_read_le "$kernel" "$((sig_offset + 8))" 4)"
    file_ls="$(windows_update_read_le "$kernel" "$((sig_offset + 12))" 4)"
    product_ms="$(windows_update_read_le "$kernel" "$((sig_offset + 16))" 4)"
    product_ls="$(windows_update_read_le "$kernel" "$((sig_offset + 20))" 4)"

    major=$(((product_ms >> 16) & 0xffff))
    minor=$((product_ms & 0xffff))
    build=$(((product_ls >> 16) & 0xffff))
    revision=$((product_ls & 0xffff))
    if ((major == 0 && minor == 0 && build == 0 && revision == 0)); then
        major=$(((file_ms >> 16) & 0xffff))
        minor=$((file_ms & 0xffff))
        build=$(((file_ls >> 16) & 0xffff))
        revision=$((file_ls & 0xffff))
    fi
    ((major || minor || build || revision)) || return 1
    WU_PE_VERSION="$(printf '%d.%d.%d.%d' "$major" "$minor" "$build" "$revision")"
}

windows_update_version_from_packages() {
    local root="$1" dir="$1/Windows/servicing/Packages" path name candidate best=""
    [[ -d "$dir" ]] || return 0
    for path in "$dir"/*.mum; do
        [[ -f "$path" ]] || continue
        name="${path##*/}"
        [[ "$name" == *RollupFix* || "$name" == *Package_for_KB* ]] || continue
        if [[ "$name" =~ ~([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            candidate="$(windows_update_pad_version "${BASH_REMATCH[1]}")"
            if [[ -z "$best" ]] || windows_update_version_ge "$candidate" "$best"; then
                best="$candidate"
            fi
        fi
    done
    printf '%s' "$best"
}

windows_update_offline_state() {
    local root="$1" override="${2:-}" arch_override="${3:-}"
    local kernel="$root/Windows/System32/ntoskrnl.exe" package_version="" best="" arch

    WU_PE_VERSION=""
    WU_PE_ARCH=""
    if [[ -f "$kernel" ]] && ! windows_update_pe_version "$kernel"; then
        printf 'warning: could not read %s\n' "$kernel" >&2
    fi
    package_version="$(windows_update_version_from_packages "$root")"

    best="$WU_PE_VERSION"
    if [[ -n "$package_version" ]] &&
       { [[ -z "$best" ]] || windows_update_version_ge "$package_version" "$best"; }; then
        best="$package_version"
    fi
    [[ -z "$override" ]] || best="$(windows_update_parse_build "$override")"
    [[ -n "$best" ]] || return 1

    arch="${WU_PE_ARCH:-x64}"
    [[ -z "$arch_override" ]] || arch="${arch_override,,}"
    case "$arch" in
        x64|x86|arm64) ;;
        *) arch='x64' ;;
    esac

    WU_CURRENT_VERSION="$best"
    WU_ARCH="$arch"
    WU_PRODUCT="$(windows_update_product "$best")"
}

# ---------------------------------------------------------------------------
# HTTPS. A cookie jar keeps the ASP.NET session alive between the search, the
# download dialog and the file requests.
# ---------------------------------------------------------------------------

windows_update_http_init() {
    WU_COOKIE_JAR="$1/ved-cookies.txt"
    : >"$WU_COOKIE_JAR"
}

windows_update_urlencode() {
    local value="$1" out="" i char hex
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
            [A-Za-z0-9._~-]) out+="$char" ;;
            ' ') out+='+' ;;
            *) printf -v hex '%%%02X' "'$char"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

windows_update_http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 -A "$WU_USER_AGENT" \
            -b "$WU_COOKIE_JAR" -c "$WU_COOKIE_JAR" "$url"
    else
        wget -qO- --timeout=60 --tries=2 --user-agent="$WU_USER_AGENT" \
            --load-cookies="$WU_COOKIE_JAR" --save-cookies="$WU_COOKIE_JAR" \
            --keep-session-cookies "$url"
    fi
}

windows_update_http_post() {
    local encoded="$1" url="https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 -A "$WU_USER_AGENT" \
            -b "$WU_COOKIE_JAR" -c "$WU_COOKIE_JAR" \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data "updateIDs=$encoded" "$url"
    else
        wget -qO- --timeout=60 --tries=2 --user-agent="$WU_USER_AGENT" \
            --load-cookies="$WU_COOKIE_JAR" --save-cookies="$WU_COOKIE_JAR" \
            --keep-session-cookies --post-data="updateIDs=$encoded" "$url"
    fi
}

# Emit one TSV row per catalog result: id, title, last updated, size.
windows_update_parse_search_rows() {
    LC_ALL=C awk -v RS='</tr>' '
        match($0, /<tr id="/) {
            id = substr($0, RSTART + RLENGTH, 36)
            if (length(id) != 36 || id !~ /^[0-9a-fA-F-]+$/) next
            count = split($0, cells, "</td>")
            if (count < 7) next
            title = cells[2]; date = cells[5]; size = cells[7]
            gsub(/<[^>]*>/, " ", title)
            gsub(/<[^>]*>/, " ", date)
            gsub(/<[^>]*>/, " ", size)
            gsub(/&nbsp;/, " ", title)
            gsub(/&amp;/, "&", title)
            gsub(/&#39;/, "\047", title)
            gsub(/&quot;/, "\"", title)
            gsub(/[[:space:]]+/, " ", title)
            gsub(/[[:space:]]+/, " ", date)
            gsub(/[[:space:]]+/, " ", size)
            sub(/^ /, "", title); sub(/ $/, "", title)
            sub(/^ /, "", date); sub(/ $/, "", date)
            sub(/^ /, "", size); sub(/ $/, "", size)
            gsub(/\t/, " ", title)
            print id "\t" title "\t" date "\t" size
        }
    '
}

windows_update_search() {
    local query="$1" encoded url page
    encoded="$(windows_update_urlencode "$query")"
    url="https://www.catalog.update.microsoft.com/Search.aspx?q=$encoded"
    page="$(windows_update_http_get "$url")" || return 1
    printf '%s\n' "$page" | windows_update_parse_search_rows
}

# Filter raw rows into: version components, KB, id, title, date.
# A KB filter keeps older updates too; automatic discovery keeps only updates
# newer than the installed build and from the same build family.
windows_update_filter_rows() {
    local rows="$1" kb="${2:-}"
    LC_ALL=C awk -F '\t' \
        -v arch="$WU_ARCH" -v product="$WU_PRODUCT" \
        -v current="$WU_CURRENT_VERSION" -v kb="$kb" '
        BEGIN {
            split(current, cur, ".")
            for (i = 1; i <= 4; i++) cur[i] = cur[i] + 0
        }
        {
            title = $2
            low = tolower(title)
            # The catalog occasionally serves a localized title for the same
            # query. "cumulativ" is shared by every translation we care about
            # (cumulative/cumulativo/cumulativa/kumulatives).
            if (index(low, "cumulativ") == 0) next
            if (index(low, "preview") ||
                index(low, "anteprima") ||
                index(low, "dynamic update") ||
                index(low, "aggiornamento dinamico") ||
                index(low, "setup update") ||
                index(low, "safe os") ||
                index(low, ".net framework") ||
                index(low, "silverlight") ||
                index(low, "adobe") ||
                index(low, "server operating system") ||
                index(low, "windows server") ||
                index(low, "critical update")) next

            family = ""
            if (index(low, "arm64")) family = "arm64"
            else if (index(low, "x64")) family = "x64"
            else if (index(low, "x86")) family = "x86"
            if (family != arch) next
            if (index(low, tolower(product)) == 0) next
            if (kb != "" && index(low, tolower(kb)) == 0) next

            ver = ""
            if (match(title, /\([0-9]+(\.[0-9]+)+\)/)) {
                ver = substr(title, RSTART + 1, RLENGTH - 2)
            }
            if (ver != "") {
                split(ver, parts, ".")
                if (parts[1] + 0 >= 10000) {
                    v[1] = cur[1]; v[2] = cur[2]
                    v[3] = parts[1] + 0; v[4] = parts[2] + 0
                } else {
                    for (i = 1; i <= 4; i++) v[i] = parts[i] + 0
                }
                if (v[3] != cur[3]) next
            } else {
                if (kb == "") next
                for (i = 1; i <= 4; i++) v[i] = cur[i]
            }

            if (kb == "") {
                newer = 0
                for (i = 1; i <= 4; i++) {
                    if (v[i] > cur[i]) { newer = 1; break }
                    if (v[i] < cur[i]) break
                }
                if (!newer) next
            }

            found_kb = ""
            if (match(title, /\(KB[0-9]+\)/)) {
                found_kb = substr(title, RSTART + 1, RLENGTH - 2)
            }
            print v[1] "\t" v[2] "\t" v[3] "\t" v[4] "\t" found_kb \
                "\t" $1 "\t" title "\t" $3
        }
    ' "$rows"
}

windows_update_sort_candidates() {
    local order="$1"
    if [[ "$order" == 'ascending' ]]; then
        sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n -k8,8r
    else
        sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k8,8r
    fi
}

# Ask the download dialog for the MSU/CAB URLs of one update ID.
windows_update_download_urls() {
    local update_id="$1" payload encoded dialog url path name kbnum
    payload="[{\"size\":0,\"updateID\":\"$update_id\",\"uidInfo\":\"$update_id\"}]"
    encoded="$(windows_update_urlencode "$payload")"
    dialog="$(windows_update_http_post "$encoded")" || return 1
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        path="${url%%\?*}"
        name="${path##*/}"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.(msu|cab)$ ]] || continue
        case "$url" in
            https://download.windowsupdate.com/*| \
            https://*.download.windowsupdate.com/*| \
            https://*.windowsupdate.com/*| \
            https://*.microsoft.com/*) ;;
            *) continue ;;
        esac
        kbnum="$(printf '%s' "$name" | sed -n 's/.*[kK][bB]\([0-9][0-9]*\).*/\1/p' | head -n1)"
        [[ -n "$kbnum" ]] || kbnum=0
        printf '%s\t%s\n' "$kbnum" "$url"
    done < <(
        printf '%s\n' "$dialog" |
            LC_ALL=C grep -oE "url[[:space:]]*=[[:space:]]*'[^']+'" |
            sed -E "s/.*'([^']+)'.*/\1/" |
            LC_ALL=C awk '!seen[$0]++'
    ) | sort -t $'\t' -k1,1n | cut -f2-
}

windows_update_download_package() {
    local url="$1" dest="$2" tmp
    tmp="$dest.part"
    if [[ -s "$dest" ]]; then
        printf 'already staged: %s\n' "${dest##*/}"
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 900 -A "$WU_USER_AGENT" \
            -b "$WU_COOKIE_JAR" -c "$WU_COOKIE_JAR" -o "$tmp" "$url" || return 1
    else
        wget -q -O "$tmp" --timeout=120 --tries=3 --user-agent="$WU_USER_AGENT" \
            --load-cookies="$WU_COOKIE_JAR" --save-cookies="$WU_COOKIE_JAR" \
            --keep-session-cookies "$url" || return 1
    fi
    [[ -s "$tmp" ]] || return 1
    mv -f "$tmp" "$dest" || return 1
    printf 'staged: %s (%s bytes)\n' "${dest##*/}" "$(stat -c %s "$dest")"
}

windows_update_write_plan() {
    local stage="$1" current="$2" candidate="$3" kb="$4" query="$5"
    local count=0 i name url tmp_json=""
    local -a names=() urls=()

    if [[ -n "${WU_PACKAGE_NAMES:-}" ]]; then
        IFS=' ' read -r -a names <<<"$WU_PACKAGE_NAMES"
    fi
    if [[ -n "${WU_PACKAGE_URLS:-}" ]]; then
        mapfile -t urls <<<"${WU_PACKAGE_URLS}"
    fi
    count=${#names[@]}

    {
        printf 'VED_UPDATE_CURRENT_BUILD=%s\n' "$current"
        printf 'VED_UPDATE_CANDIDATE_VERSION=%s\n' "$candidate"
        printf 'VED_UPDATE_KB=%s\n' "$kb"
        printf 'VED_UPDATE_PACKAGE_COUNT=%d\n' "$count"
        printf 'VED_UPDATE_SEARCH_QUERY=%s\n' "$query"
        printf 'VED_UPDATE_PACKAGE_NAMES=%s\n' "$WU_PACKAGE_NAMES"
    } >"$stage/ved-update-plan.env" || return 1

    for ((i = 0; i < count; i++)); do
        name="${names[i]//\\/\\\\}"
        name="${name//\"/\\\"}"
        url="${urls[i]:-}"
        url="${url//\\/\\\\}"
        url="${url//\"/\\\"}"
        ((i == 0)) || tmp_json+=','
        tmp_json+="{\"name\":\"$name\",\"url\":\"$url\"}"
    done
    {
        printf '{\n'
        printf '  "current_version": "%s",\n' "$current"
        printf '  "arch": "%s",\n' "$WU_ARCH"
        printf '  "product": "%s",\n' "$WU_PRODUCT"
        printf '  "query": "%s",\n' "$query"
        printf '  "candidate_version": "%s",\n' "$candidate"
        printf '  "kb": "%s",\n' "$kb"
        printf '  "packages": [%s]\n' "$tmp_json"
        printf '}\n'
    } >"$stage/ved-update-plan.json" || return 1
}

# Full discovery + staging pipeline.
windows_update_discover() (
    local windows_root="$1" stage_dir="$2" kb_filter="${3:-}"
    local plan_only="${4:-0}" build_override="${5:-}" arch_override="${6:-}"
    local tmp rows_file candidates_file query display kb="" build="" item=""
    local seen_kb=""
    local urls_blob="" candidate="" candidate_line=""
    local -a kb_list=() selected_lines=() kb_names=() urls=()
    local line vm vn vb vr found_kb id title url name

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        printf 'error: curl or wget is required for Windows Update discovery\n' >&2
        return 1
    fi
    if ! windows_update_offline_state "$windows_root" "$build_override" "$arch_override"; then
        printf 'error: could not determine the offline Windows build\n' >&2
        return 1
    fi

    tmp="$(mktemp -d)" || return 1
    trap 'rm -rf "$tmp"' EXIT
    windows_update_http_init "$stage_dir" || return 1
    rows_file="$tmp/rows.tsv"
    candidates_file="$tmp/candidates.tsv"

    printf 'Offline build: %s (%s, %s)\n' \
        "$WU_CURRENT_VERSION" "$WU_ARCH" "$WU_PRODUCT"

    if [[ -n "$kb_filter" ]]; then
        IFS=',' read -r -a kb_list <<<"${kb_filter^^}"
        if ((${#kb_list[@]} == 1)); then
            query="${kb_list[0]}"
        else
            query="KB list: "
            for kb in "${kb_list[@]}"; do
                [[ "$query" == *"$kb"* ]] || query+="$kb, "
            done
            query="${query%, }"
        fi
    else
        build="${WU_CURRENT_VERSION#*.*.}"
        build="${build%%.*}"
        query="$WU_CURRENT_VERSION"
        display="$(windows_update_display_version "$build")" || display=""
        if [[ -z "$display" ]] && windows_update_search "$build" \
            >"$rows_file" 2>/dev/null; then
            display="$(LC_ALL=C awk -F '\t' '
                {
                    if (match($2, /[0-9][0-9]H[0-9]/))
                        print toupper(substr($2, RSTART, RLENGTH))
                }
            ' "$rows_file" | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')"
        fi
        : >"$rows_file"
        if [[ -n "$display" ]]; then
            query="$WU_PRODUCT Version $display Cumulative Update $WU_ARCH"
        else
            query="$build Cumulative Update for $WU_PRODUCT $WU_ARCH"
        fi
    fi
    printf 'Catalog query: %s\n' "$query"

    : >"$candidates_file"
    if [[ -n "$kb_filter" ]]; then
        for kb in "${kb_list[@]}"; do
            : >"$rows_file"
            windows_update_search "$kb" >"$rows_file" || return 1
            windows_update_filter_rows "$rows_file" "$kb" >>"$candidates_file" ||
                return 1
        done
        mapfile -t selected_lines < <(
            windows_update_sort_candidates ascending <"$candidates_file" |
                LC_ALL=C awk -F '\t' '!seen[$6]++'
        )
    else
        windows_update_search "$query" >"$rows_file" || return 1
        windows_update_filter_rows "$rows_file" "" >"$candidates_file" || return 1
        mapfile -t selected_lines < <(
            windows_update_sort_candidates descending <"$candidates_file" | head -n1
        )
    fi

    WU_PACKAGE_NAMES=""
    WU_PACKAGE_URLS=""
    if ((${#selected_lines[@]} == 0)) ||
       [[ -z "${selected_lines[0]}" ]]; then
        printf 'No newer matching cumulative update was found.\n'
        windows_update_write_plan "$stage_dir" "$WU_CURRENT_VERSION" "" "" \
            "$query" || return 1
        return 0
    fi

    for line in "${selected_lines[@]}"; do
        IFS=$'\t' read -r vm vn vb vr found_kb id title _date <<<"$line"
        printf 'Available update: %s (%s.%s.%s.%s)\n' \
            "${found_kb:-cumulative update}" "$vm" "$vn" "$vb" "$vr"
        printf 'Title: %s\n' "$title"
        if [[ -n "$found_kb" ]]; then
            seen_kb=""
            for item in "${kb_names[@]}"; do
                if [[ "$item" == "$found_kb" ]]; then
                    seen_kb="$item"
                    break
                fi
            done
            [[ "$found_kb" == "$seen_kb" ]] || kb_names+=("$found_kb")
        fi
        urls_blob="$(windows_update_download_urls "$id")" || return 1
        if [[ -n "$urls_blob" ]]; then
            mapfile -t urls <<<"$urls_blob"
        else
            urls=()
        fi
        ((${#urls[@]} > 0)) || {
            printf 'error: the catalog returned no MSU/CAB download URLs\n' >&2
            return 1
        }
        for url in "${urls[@]}"; do
            [[ -n "$url" ]] || continue
            name="${url%%\?*}"
            name="${name##*/}"
            WU_PACKAGE_NAMES+="${WU_PACKAGE_NAMES:+ }$name"
            WU_PACKAGE_URLS+="${WU_PACKAGE_URLS:+$'\n'}$url"
            if [[ "$plan_only" == '1' ]]; then
                printf 'would download: %s\n' "$name"
            else
                windows_update_download_package "$url" "$stage_dir/$name" || return 1
            fi
        done
    done

    candidate_line="$(printf '%s\n' "${selected_lines[@]}" |
        windows_update_sort_candidates descending | head -n1)"
    IFS=$'\t' read -r vm vn vb vr _kb _id _title _date <<<"$candidate_line"
    candidate="$(printf '%d.%d.%d.%d' "${vm:-0}" "${vn:-0}" "${vb:-0}" "${vr:-0}")"
    kb="$(IFS=,; printf '%s' "${kb_names[*]}")"
    [[ -n "$kb" ]] || kb="${kb_filter// /, }"

    windows_update_write_plan "$stage_dir" "$WU_CURRENT_VERSION" "$candidate" \
        "$kb" "$query" || return 1
    printf 'Staged %d package(s) in %s\n' \
        "$(printf '%s' "$WU_PACKAGE_NAMES" | wc -w)" "$stage_dir"
)

windows_update_main() {
    local windows_root="" stage_dir="" build="" arch="" kb="" plan_only=0
    while (($#)); do
        case "$1" in
            --windows-root) windows_root="${2:-}"; shift 2 ;;
            --stage-dir) stage_dir="${2:-}"; shift 2 ;;
            --build) build="${2:-}"; shift 2 ;;
            --arch) arch="${2:-}"; shift 2 ;;
            --kb) kb="${2:-}"; shift 2 ;;
            --plan-only) plan_only=1; shift ;;
            -h|--help)
                printf 'Usage: windows_update.sh --windows-root DIR --stage-dir DIR [--build V] [--arch A] [--kb KB[,KB]] [--plan-only]\n'
                return 0 ;;
            *)
                printf 'unknown option: %s\n' "$1" >&2
                return 2 ;;
        esac
    done
    if [[ -z "$windows_root" || -z "$stage_dir" ]]; then
        printf 'error: --windows-root and --stage-dir are required\n' >&2
        return 2
    fi
    windows_update_discover "$windows_root" "$stage_dir" "$kb" \
        "$plan_only" "$build" "$arch"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    windows_update_main "$@"
fi

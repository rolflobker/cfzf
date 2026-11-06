#!/usr/bin/env bash
# cfzf.sh - cfzf: fzf with a cached list. Pipe the command to run into cfzf.
# cfzf keeps the output in a file. bkt is an optional cache store (CFZF_BKT=1).
#
# WHAT IT DOES
#   echo 'COMMAND' | cfzf [FZF FLAGS]
#   cfzf runs COMMAND with bash -c and shows the output in fzf. Every flag goes to fzf.
#   - First use, no data yet: fzf opens at once with "Fetching data ...".
#     The list fills in when the command ends.
#   - Next uses: fzf opens at once with the old list. One fresh fetch runs.
#     The new list replaces the old list when the fetch ends.
#   Every open runs the command once. The command gets /dev/null as stdin.
#   The selected line goes to stdout, as with fzf.
#
# WARNING
#   cfzf binds the fzf events "start" and "load". If you pass your own --bind for
#   one of these events, it can replace ours. The refresh then does not run.
#
# SETUP
#   1. Optional: use bkt as the cache store. Install it (cargo install bkt) and set
#      export CFZF_BKT=1 in ~/.bashrc. Use bkt when other scripts share the cache.
#      If bkt is missing, cfzf uses the file store.
#   2. Source this file in bash:  source cfzf.sh
#      Add this line to ~/.bashrc to keep it. The file exports the functions that
#      the fzf reload needs, because fzf runs the fetch in a new bash.
#   3. Optional, for keys (see KEYS). Add to ~/.bashrc:
#        declare -A CFZF_KEYS=(
#            [az]='az account show --query id -o tsv'
#            [gh]='gh api user -q .login'
#        )
#
# KEYS
#   A key separates two lists that have the same command text. Example: az group list
#   gives different results in two subscriptions. Without a key, both share one list.
#
#   cfzf takes the first word of the command, for example az, and looks it up in
#   CFZF_KEYS. It runs the key command and adds the result to the cache name.
#
#   - No entry for the first word: no key.
#   - The key command runs on every open. Keep it fast.
#   - For one call, set the key yourself. This wins over CFZF_KEYS:
#       echo 'ls -l' | CFZF_KEY=home cfzf
#   - A line that starts with another word, such as "cd x && az ...", gets no key.
#
# EXAMPLES
#   Test with random lines. The command waits 3 seconds, then prints 5 lines:
#     echo 'sleep 3; for i in $(seq 1 5); do echo "item-$RANDOM"; done' | cfzf
#
#   First run: "Fetching data ..." shows, then 5 lines. Run it again: the old 5 lines
#   show at once, and the header shows their time and "updating ...". After about
#   3 seconds, 5 new lines replace them, and the header shows the new time.
#
#   Azure resource groups. The key is the subscription:
#     echo 'az group list --query "[].name" -o tsv' | cfzf
#
#   With fzf flags:
#     echo 'az group list --query "[].name" -o tsv' | cfzf --height 40% --prompt 'group> '
#
#   Keep the choice in a variable:
#     group=$(echo 'az group list --query "[].name" -o tsv' | cfzf)
#
#   A pipeline in the command:
#     echo 'gh repo list --limit 100 | cut -f1' | cfzf
#
# QUOTING
#   The whole command is one string, and bash -c runs it. Escape quotes as bash needs.
#   Use single quotes around the string, so your shell does not expand $ early.
#
# FILES
#   $CFZF_CACHE_DIR (default ~/.cache/cfzf) holds the cache data and the stamp files.
#   A stamp file name starts with the first word of the command, for example az-1a2b3c.ok.
#   Start one list again: delete its stamp. fzf then opens with "Fetching data ...".
#   Delete all lists: rm -rf ~/.cache/cfzf
#
# HOW IT WORKS
#   cfzf writes the output to a file next to the stamp (name.out). With CFZF_BKT=1,
#   bkt keeps the output instead. The stamp file, one for each key and command,
#   records a successful fetch. It tells us whether old data exists, because bkt
#   does not report a hit or a miss.
#
# LIMITS
#   - A failed fetch can leave an empty list. The header then stays on "Fetching data ...".
#   - The file store has no time limit: the old list stays until a fetch succeeds.
#     bkt keeps data for 1 day. After that, the old-list step runs the command first,
#     and fzf opens when it ends.
#   - With the file store, a failed fetch keeps the old file, and the reload then shows an empty list.
#   - Do not switch between the file store and bkt for one list. The next run shows
#     an empty list until the fetch ends.
#   - Only stdout becomes the list.
#
# bkt NOTES
#   - bkt caches a failed command by default. Always pass --discard-failures.
#   - bkt builds its cache key from the flags. Every call for one list must use the same flags.

CFZF_CACHE_DIR="${CFZF_CACHE_DIR:-$HOME/.cache/cfzf}"

# True when cfzf uses bkt: CFZF_BKT is set and bkt is installed.
_cb_use_bkt() {
    [[ -n "${CFZF_BKT:-}" ]] && command -v bkt >/dev/null 2>&1
}

# Print the key for the command line LINE. CFZF_KEY wins. Otherwise look up the first
# word in CFZF_KEYS and run that key command. Print nothing when there is no key.
_cb_key() {
    local line="$1" first key_cmd
    if [[ -v CFZF_KEY ]]; then
        printf '%s' "$CFZF_KEY"
        return 0
    fi
    # shellcheck disable=SC2153 # the user sets CFZF_KEYS, it is not a typo of CFZF_KEY
    [[ "${CFZF_KEYS@a}" == *A* ]] || return 0 # CFZF_KEYS must be an associative array
    first=${line%%[[:space:]]*}
    key_cmd="${CFZF_KEYS[$first]:-}"
    if [[ -n "$key_cmd" ]]; then
        eval "$key_cmd" 2>/dev/null </dev/null || true
    fi
}

# Print the stamp path for KEY and the command line LINE.
_cb_stamp() {
    local key="$1" line="$2" name hash
    name=${line%%[[:space:]]*}
    name=$(printf '%s' "${name##*/}" | tr -c 'A-Za-z0-9._-' '_')
    hash=$(printf '%s\0%s' "$key" "$line" | sha256sum)
    printf '%s/%s-%s.ok\n' "$CFZF_CACHE_DIR" "$name" "${hash:0:12}"
}

# Print the header text for the stamp STAMP. fzf calls it after a list change.
_cb_header() {
    if [[ -f "$1" ]]; then
        echo "Data from $(TZ=Europe/Amsterdam date -r "$1" '+%H:%M %Z')"
    else
        echo "Fetching data ..."
    fi
}

# Print the stored output of the command line LINE under KEY, without a fetch.
# bkt returns its copy at once. The flags must match _cb_fetch, because bkt uses
# them in its cache key. Without bkt, the output is in the file next to STAMP.
_cb_old() {
    local stamp="$1" key="$2" line="$3"
    if _cb_use_bkt; then
        bkt --cache-dir="$CFZF_CACHE_DIR" --scope="$key" --ttl=1d --discard-failures \
            -- bash -c "$line" </dev/null
    else
        cat "${stamp%.ok}.out"
    fi
}

# Fetch the command line LINE under KEY and record the stamp on success.
# Print the output on stdout, because the fzf reload reads it.
_cb_fetch() {
    local stamp="$1" key="$2" line="$3" out tmp
    mkdir -p "$CFZF_CACHE_DIR"
    if _cb_use_bkt; then
        bkt --cache-dir="$CFZF_CACHE_DIR" --scope="$key" --ttl=1d --force --discard-failures \
            -- bash -c "$line" </dev/null && touch "$stamp"
        return
    fi
    # No bkt. Write to a temp file, so a failed run keeps the old file.
    out="${stamp%.ok}.out"
    # When you quit fzf during a fetch, fzf stops this shell and the temp file stays.
    # Remove temp files older than 10 minutes. A fetch in another terminal keeps its own.
    find "$CFZF_CACHE_DIR" -maxdepth 1 -name '*.out.??????' -mmin +10 -delete 2>/dev/null
    tmp=$(mktemp "$out.XXXXXX")
    if bash -c "$line" </dev/null >"$tmp"; then
        mv "$tmp" "$out"
        touch "$stamp"
        cat "$out"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Choose the action for each load event of the old-list case. FLAG exists until the
# first load. That load runs the fetch. The load after the fetch sets the new header.
_cb_onload() {
    local flag="$1" stamp="$2" key="$3" line="$4"
    if [[ -e "$flag" ]]; then
        rm -f "$flag"
        printf 'reload-sync(_cb_fetch %q %q %q 2>/dev/null)\n' "$stamp" "$key" "$line"
    else
        printf 'transform-header(_cb_header %q)\n' "$stamp"
    fi
}

# Run fzf on the list of the command line LINE under KEY. The rest of "$@" goes to fzf.
_cb_run() {
    local key="$1" line="$2" stamp key_text line_text file_text flag rc=0
    local -a bind=()
    shift 2
    stamp=$(_cb_stamp "$key" "$line")
    key_text=$(printf '%q' "$key")
    line_text=$(printf '%q' "$line")
    file_text=$(printf '%q' "$stamp")
    if [[ -f "$stamp" ]]; then
        # Old data exists. It shows at once, with its age in the header. The first load
        # runs one fetch. The load after the fetch sets the new header (see _cb_onload).
        flag=$(mktemp)
        bind=(--header "$(_cb_header "$stamp") - updating ..."
        --bind "load:transform(_cb_onload $(printf '%q' "$flag") $file_text $key_text $line_text)")
        { _cb_old "$stamp" "$key" "$line" 2>/dev/null || true; } |
            fzf --with-shell 'bash -c' "${bind[@]}" "$@" || rc=$?
        rm -f "$flag"
        return "$rc"
    else
        # No data yet. fzf opens at once. The start event fetches the list.
        bind=(--header 'Fetching data ...'
            --bind "start:reload-sync(_cb_fetch $file_text $key_text $line_text 2>/dev/null)"
            --bind "load:transform-header(_cb_header $file_text)")
        fzf --with-shell 'bash -c' "${bind[@]}" "$@" </dev/null
    fi
}

# Read the command line from stdin and pick from its cached list in fzf.
cfzf() {
    local line
    if [[ -t 0 ]]; then
        echo "cfzf: pipe the command to run into cfzf, for example: echo 'ls -l' | cfzf" >&2
        return 2
    fi
    line=$(cat)
    if [[ -z "$line" ]]; then
        echo "cfzf: the command line on stdin is empty" >&2
        return 2
    fi
    _cb_run "$(_cb_key "$line")" "$line" "$@"
}

export CFZF_CACHE_DIR
export -f _cb_use_bkt _cb_header _cb_old _cb_fetch _cb_onload

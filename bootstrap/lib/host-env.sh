# host-env.sh — load config/host.env WITHOUT executing it.  Sourced by 01..06.
#
# WHY NOT JUST `. host.env`
# `.` executes the file. config/host.env lives in the repo on drvfs (/mnt/d), which WSL mounts
# 0777 by design — any Windows process, any other distro, and any local user can write it. It is
# also gitignored on purpose, so a modification leaves no trace in `git status`. Three of the
# bootstrap scripts run as root. Sourcing it would mean: an untracked, world-writable file
# executes as root on the next bootstrap.
#
# The bootstrap scripts themselves are equally on drvfs, but they are tracked, so tampering shows
# up as a diff. That is the whole distinction this file exists to preserve.
#
# WHAT THIS ACCEPTS
# KEY=value, one per line. Keys must match BIOINFO_*, NXF_* or JAVA_HOME and contain only
# [A-Za-z0-9_]. Values are taken literally: no command substitution, no variable expansion, no
# globbing. A value may be double- or single-quoted to contain spaces; an unquoted value ends at
# the first space or '#', which is what makes the trailing comments in host.env.example work.
# Anything else on the line is ignored rather than guessed at.
#
# CONSEQUENCE, stated plainly: $HOME and friends do NOT expand here. Write absolute paths.
# The generated ~/.config/bioinfo/env.sh is a different mechanism and is authoritative for NXF_*.

load_host_env() {
    _he_file="${1:-}"
    [ -n "$_he_file" ] && [ -f "$_he_file" ] || return 0

    while IFS= read -r _he_line || [ -n "$_he_line" ]; do
        _he_line="${_he_line%$'\r'}"                       # tolerate a CRLF checkout
        case "$_he_line" in
            ''|'#'*)   continue ;;
            *'='*)     ;;
            *)         continue ;;
        esac

        _he_key="${_he_line%%=*}"
        _he_val="${_he_line#*=}"

        # trim whitespace around the key
        _he_key="${_he_key#"${_he_key%%[![:space:]]*}"}"
        _he_key="${_he_key%"${_he_key##*[![:space:]]}"}"
        _he_key="${_he_key#export }"
        _he_key="${_he_key#"${_he_key%%[![:space:]]*}"}"

        # allowlist: name shape, then namespace
        case "$_he_key" in
            *[!A-Za-z0-9_]*|'')      continue ;;
            BIOINFO_*|NXF_*|JAVA_HOME) ;;
            *)                       continue ;;
        esac

        # leading whitespace off the value, then take the literal
        _he_val="${_he_val#"${_he_val%%[![:space:]]*}"}"
        case "$_he_val" in
            '"'*)  _he_val="${_he_val#\"}"; _he_val="${_he_val%%\"*}" ;;
            "'"*)  _he_val="${_he_val#\'}"; _he_val="${_he_val%%\'*}" ;;
            *)     _he_val="${_he_val%%#*}"                    # drop a trailing comment
                   _he_val="${_he_val%"${_he_val##*[![:space:]]}"}"
                   case "$_he_val" in *[[:space:]]*) _he_val="${_he_val%%[[:space:]]*}" ;; esac ;;
        esac

        # nothing that would re-introduce evaluation downstream
        case "$_he_val" in
            *'$('*|*'`'*|*';'*|*'|'*|*'&'*|*'>'*|*'<'*|*$'\n'*) continue ;;
        esac

        # An empty value is a typo, not a setting. Skipping it lets the script's own
        # `${VAR:-default}` win, which is what the author meant. Exporting the empty string
        # instead is safe only for as long as every default uses `:-` rather than `-`, and
        # that is not a property worth depending on: BIOINFO_USER reaches usermod, chown and
        # a sudoers line, and BIOINFO_REFS reaches rm.
        [ -n "$_he_val" ] || continue

        export "$_he_key=$_he_val"
    done < "$_he_file"

    unset _he_file _he_line _he_key _he_val
    return 0
}

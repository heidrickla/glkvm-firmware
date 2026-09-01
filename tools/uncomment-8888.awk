# uncomment-8888.awk - enable the classic PiKVM UI server block GL.iNet ships
# commented out in /etc/kvmd/nginx-kvmd.conf.
#
# Shared by enable_classic_ui.sh (live device) and bake-image.remote.sh
# (firmware tree). One copy, on purpose: this program carries two fixes that
# were each paid for once, and two copies would drift apart.
#
# Handles BOTH marker styles found in shipped configs:
#   1.10.0 / 1.7.0 :  "#        server {"   -- # at column 1
#   1.3.0          :  "        # server {"   -- # indented
# An earlier version anchored # to column 1 and silently did nothing on a
# 1.3.0-era config.
#
# Terminates on BRACE BALANCE of the uncommented text, so an inner
# "location ... {" does not end the block early (an earlier version keyed on
# /^#\s*\}\s*$/ and left the server block unclosed).
#
# Also repairs a GL.iNet typo: 1.3.0 writes "listen [::]:443 ssl;" INSIDE the
# 8888 block. Uncommented verbatim that binds a SECOND server to :443
# alongside the real one. Corrected to 8888, and reported when it fires.

function uncomment(s,   i) {
    i = index(s, "#")
    if (i == 0) return s
    return substr(s, 1, i-1) substr(s, i+1)
}
/^[[:space:]]*#[[:space:]]*server[[:space:]]*\{/ && !inblk {
    inblk=1; n=0; hit=0; depth=0
    L[n++]=$0
    s=uncomment($0); depth += gsub(/\{/,"{",s) - gsub(/\}/,"}",s)
    next
}
inblk {
    L[n++]=$0
    if ($0 ~ /8888/) hit=1
    s=uncomment($0); depth += gsub(/\{/,"{",s) - gsub(/\}/,"}",s)
    if (depth <= 0) {
        for (i=0;i<n;i++) {
            l=L[i]
            if (hit) {
                l=uncomment(l)
                if (l ~ /listen[[:space:]]+\[::\]:443/) { sub(/443/, "8888", l); fixed++ }
            }
            print l
        }
        inblk=0
    }
    next
}
{ print }
END { if (fixed) print "#   note: listen [::]:443 corrected to 8888 by uncomment-8888.awk" }

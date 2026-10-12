#!/bin/sh
# Frame-compare Raptor's title bar and splits with Rex's reference frames.
#
# Opens a session window at 1080x720 pt on a private server with a reference
# theme, screenshots it at 2x, and checks geometry and token colours:
#   dark  (bg #161616, vs v4_4fps_001.jpg): title bar 40 pt, chrome #131313,
#         active pill 220x27 pt, split divider #242424;
#   light (bg #F8F6FB, vs acc_on_crop_tabstrip_light.png): chrome #FDFBFF,
#         separators #CECCD1 between inactive tabs.
# Colours must be within 2/255 per channel, sizes within 1 pt.
#
# usage: test/rex/frame-compare.sh <Raptor.app> <rap> <outdir> [reference-frames-dir]
# Needs ImageMagick (magick), Screen Recording and Accessibility permission for
# the calling terminal, and no other Raptor running. With reference frames, it
# also writes side-by-side images.
set -eu

app=$1
rap=$2
out=$3
refs=${4:-}
mkdir -p "$out"
if pgrep -qf "Raptor.app/Contents/MacOS/raptor"; then
    echo "quit Raptor first" >&2
    exit 1
fi

tmp=$(mktemp -d)
sock=
fail=0
cleanup() {
    pkill -f "$app/Contents/MacOS/raptor" 2>/dev/null || true
    RAP_SERVER=$sock "$rap" server stop >/dev/null 2>&1 || true
    rm -f "$sock.lock"
    rm -rf "$tmp"
}
trap cleanup EXIT

# The window's id and bounds, from the window server.
cat >"$tmp/win.swift" <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowName as String] as? String) == CommandLine.arguments[1] {
    print(w[kCGWindowNumber as String]!)
    break
}
EOF
swiftc -o "$tmp/win" "$tmp/win.swift" 2>/dev/null

# The pixel at x,y of image $1 as RRGGBB.
px() { magick "$1" -format "%[hex:p{$2,$3}]" info: | cut -c1-6; }

# Row $2 of image $1 as lines of "x RRGGBB".
row() { magick "$1" -crop "$(magick identify -format %w "$1")x1+0+$2" +repage txt:- | sed -n 's/^\([0-9]*\),0:.*#\([0-9A-F]\{6\}\).*/\1 \2/p'; }

# Pass if colour $2 (RRGGBB) is within 2/255 per channel of $3.
near() {
    a=$2 b=$3
    for i in 1 3 5; do
        x=$(printf %d "0x$(echo "$a" | cut -c$i-$((i + 1)))")
        y=$(printf %d "0x$(echo "$b" | cut -c$i-$((i + 1)))")
        d=$((x > y ? x - y : y - x))
        if [ $d -gt 2 ]; then
            echo "FAIL $1: #$a, want #$b"
            fail=1
            return
        fi
    done
    echo "ok   $1: #$a (want #$b)"
}

# Pass if $2 is within $3 of $4.
within() {
    d=$(($2 > $4 ? $2 - $4 : $4 - $2))
    if [ $d -le "$3" ]; then echo "ok   $1: $2 (want $4)"; else
        echo "FAIL $1: $2, want $4"
        fail=1
    fi
}

# Run one theme: $1 name, $2 background.
shoot() {
    name=$1
    sock=/tmp/raptor-fc-$$-$name.sock
    printf 'background = %s\nwindow-padding-x = 0\n' "$2" >"$tmp/config"
    export RAP_SERVER=$sock
    "$rap" server start >/dev/null
    "$rap" new "fc-$name" -- /bin/sh >/dev/null
    "$rap" split -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" split --down -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" run -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" run -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" focus -s "fc-$name" -w 1 >/dev/null

    GHOSTTY_CONFIG_PATH=$tmp/config "$app/Contents/MacOS/raptor" >"$tmp/app-$name.log" 2>&1 &
    id=
    for _ in $(seq 1 60); do
        id=$("$tmp/win" "fc-$name")
        [ -n "$id" ] && break
        sleep 0.25
    done
    [ -n "$id" ] || {
        echo "FAIL $name: no window"
        fail=1
        return
    }
    osascript -e 'tell application "System Events" to tell (first application process whose name is "raptor")
        set position of window 1 to {80, 80}
        set size of window 1 to {1080, 720}
    end tell' >/dev/null
    sleep 1.5
    shot=$out/raptor-$name.png
    screencapture -x -o -l"$id" "$shot"
    unset RAP_SERVER
    pkill -f "$app/Contents/MacOS/raptor" || true
    sleep 1
    RAP_SERVER=$sock "$rap" server stop >/dev/null 2>&1 || true
    rm -f "$sock.lock"
}

shoot dark 161616
img=$out/raptor-dark.png
if [ -f "$img" ]; then
    echo "dark: $(magick identify -format '%wx%h' "$img") px"
    near "chrome" "$(px "$img" 2000 8)" 131313
    # The hairline under the title bar, at the right edge clear of tabs.
    for y in $(seq 60 100); do
        [ "$(px "$img" 2100 $y)" != "$(px "$img" 2100 8)" ] && break
    done
    within "title bar height (px at 2x)" "$y" 2 80
    # The active pill: the run of its colour, the second most common after the
    # chrome, across the bar's middle row.
    pill=$(magick "$img" -crop 2160x1+0+40 +repage -format %c histogram:info:- | sort -rn | sed -n 2p | grep -o '#[0-9A-F]\{6\}' | tr -d '#')
    # From its first pixel to the last one before a long run of chrome; the
    # icon and title inside it aren't chrome.
    chrome=$(px "$img" 2000 8)
    read -r x0 w <<EOF
$(row "$img" 40 | awk -v p="$pill" -v c="$chrome" '
        x0 == "" && $2 == p { x0 = $1 }
        x0 != "" { if ($2 == c) { if (++run >= 10) exit } else { run = 0; x1 = $1 } }
        END { print x0, x1 - x0 + 1 }')
EOF
    within "pill width (px at 2x)" "$w" 2 440
    h=$(magick "$img" -crop 1x80+$((x0 + 220))+0 +repage -fill white -fuzz 1% -opaque "#$pill" -fill black +opaque white -trim -format '%h' info:)
    within "pill height (px at 2x)" "$h" 2 54
    # The vertical divider between the left and right panes.
    d=none
    for x in $(seq 1070 1090); do
        c=$(px "$img" $x 1300)
        [ "$c" = "$(px "$img" 1060 1300)" ] || {
            d=$c
            break
        }
    done
    near "split divider" "$d" 242424
fi

shoot light F8F6FB
img=$out/raptor-light.png
if [ -f "$img" ]; then
    echo "light: $(magick identify -format '%wx%h' "$img") px"
    near "chrome" "$(px "$img" 2000 8)" FDFBFF
    # Separators are straight 16 pt vertical lines: count columns of separator
    # colour at three rows spanning them, which text and the pill's rounded
    # ends don't make. Only the gap between the two inactive tabs has one.
    hits() {
        row "$img" "$1" | awk '
            function h(s) { return (index("0123456789ABCDEF", substr(s, 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(s, 2, 1)) - 1 }
            { r = h(substr($2, 1, 2)); g = h(substr($2, 3, 2)); b = h(substr($2, 5, 2))
              if (r >= 204 && r <= 208 && g >= 202 && g <= 206 && b >= 207 && b <= 211) print $1 }'
    }
    hits 27 | sort >"$tmp/a"
    hits 40 | sort >"$tmp/b"
    hits 53 | sort >"$tmp/c"
    cols=$(comm -12 "$tmp/a" "$tmp/b" | comm -12 - "$tmp/c" | wc -l | tr -d ' ')
    # A 1 pt line is 2 px wide at 2x.
    within "separator columns" "$cols" 1 2
fi

if [ -n "$refs" ]; then
    magick "$out/raptor-dark.png" -resize 1200x "$refs/v4_4fps_001.jpg" -resize 1200x -append \
        -quality 85 "$out/side-by-side-dark.jpg"
    magick "$out/raptor-light.png" -crop 2160x120+0+0 -resize 1200x "$refs/acc_on_crop_tabstrip_light.png" -resize 1200x -append \
        -quality 85 "$out/side-by-side-light.jpg"
fi
exit $fail

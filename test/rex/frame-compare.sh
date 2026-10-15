#!/bin/sh
# Frame-compare Raptor's title bar and panes with Rex's reference frames.
#
# Opens a session window at 1080x720 pt on a private server with a reference
# theme, screenshots it at 2x, and checks geometry and token colours:
#   dark  (bg #161616, vs v4_4fps_001.jpg; Solid, compact, no headers):
#         title bar 40 pt, chrome #131313, split divider #242424; the tab
#         strip as in the captain's Rex frame (captain-tab-reference.png):
#         one 32 pt track, 7% white over the chrome (#242424), holding
#         208 pt tabs; the active one a 208x29 pt capsule 5% whiter (#2E2E2E);
#         a 1x17 pt divider, 20% white (#4F4F4F), between inactive tabs;
#   light (bg #F8F6FB, vs acc_on_crop_tabstrip_light.png; same): chrome
#         #FDFBFF, separators #CECCD1 between inactive tabs;
#   islands (bg #131313, vs v1_4fps_001.jpg; Solid, islands, headers): cards
#         inset 8 pt (6 pt under the title bar), 9 pt gutter, 10 pt radius,
#         border #262626, chrome #111111 between them, card #131313;
#   compact (bg #0F1518, vs v2_4fps_049.jpg; Solid, compact, headers):
#         divider #1E2226, 34 pt headers, #0B1212 when unfocused, the pane
#         background when focused;
#   fresh (default theme; Blended, islands, headers pinned to the default
#         values so saved Settings can't leak in): islands with headers, their
#         bodies the chrome's colour and their rims a 15% white sheen over it;
#   translucent (bg #0A0C10 dark and #F8F6FB light; Blended and Glass,
#         islands, headers), each over a flat black and a flat white window:
#         a pane body lets through as much of what's behind the window as the
#         chrome does (within 2%), and at least 20%, so the desktop shows
#         through it as in the captain's Rex frame (captain-rex-reference.png);
#         the island rim lifts the body toward white by 15% on dark themes and
#         toward black by 10% on light ones, as Rex's lifts what shows through;
#   opaque (Blended with Translucent panes off): the body lets nothing through;
#   palette (bg #232831, accent #8060B5, vs v3_4fps_006.jpg): the command
#         palette 330 pt wide, centred, 76 pt below the window top, 16 rows
#         of 28 pt, #30343F, with shortcut glyphs at the rows' trailing edge;
#   filtered (same, the query "spl", vs v3_crop_palette_filtered_t2.0.jpg):
#         the first row filled with the accent, 26 pt tall;
#   sessions (same): the session switcher under the session item.
# Colours must be within 2/255 per channel, sizes within 1 pt.
#
# usage: test/rex/frame-compare.sh <Raptor.app> <rap> <outdir> [reference-frames-dir]
# Needs ImageMagick (magick), Screen Recording permission for the calling
# terminal, and no other Raptor running. With reference frames, it also writes
# side-by-side images.
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

# A flat-coloured window to put behind Raptor: backdrop x y w h RRGGBB.
cat >"$tmp/backdrop.swift" <<'EOF'
import AppKit
let a = CommandLine.arguments
let v = Int(a[5], radix: 16)!
let window = NSWindow(contentRect: NSRect(x: Double(a[1])!, y: Double(a[2])!, width: Double(a[3])!, height: Double(a[4])!),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.backgroundColor = NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255,
                                 blue: CGFloat(v & 255) / 255, alpha: 1)
NSApplication.shared.setActivationPolicy(.accessory)
window.orderFrontRegardless()
NSApplication.shared.run()
EOF
swiftc -o "$tmp/backdrop" "$tmp/backdrop.swift" 2>/dev/null

# The main screen's size in points, for the window frame given to the app.
screen=$(swift -e 'import AppKit; let f = NSScreen.screens[0].frame; print(Int(f.width), Int(f.height))' 2>/dev/null)
sw=${screen% *}
sh=${screen#* }

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

# Run one theme: $1 name, $2 background (empty for the default theme), then
# appearance settings as RAPTOR_*=value. With $backdrop set (RRGGBB), a window of
# that colour sits behind Raptor and the shot is the screen under the window, so
# it holds what the window lets through; otherwise it is the window alone.
shoot() {
    name=$1
    sock=/tmp/raptor-fc-$$-$name.sock
    if [ -n "$2" ]; then
        printf 'background = %s\npalette = 5=#8060B5\nwindow-padding-x = 0\n' "$2" >"$tmp/config"
    else
        : >"$tmp/config"
    fi
    shift 2
    # Debug builds read GHOSTTY_CONFIG_PATH; release builds the XDG config.
    mkdir -p "$tmp/xdg-$name/ghostty"
    cp "$tmp/config" "$tmp/xdg-$name/ghostty/config"
    export RAP_SERVER=$sock
    "$rap" server start >/dev/null
    "$rap" new "fc-$name" -- /bin/sh >/dev/null
    "$rap" split -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" split --down -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" run -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" run -s "fc-$name" -- /bin/sh >/dev/null
    "$rap" focus -s "fc-$name" -w 1 >/dev/null

    # Let the panes' programs start before the app sizes them.
    sleep 1
    # The window takes its frame from its autosave name, set here for this launch
    # only: 1080x720 pt, 80 pt from the screen's top left.
    sid=$("$rap" ls | awk -v n="fc-$name" '$1 == n { print $4 }')
    bp=
    if [ -n "${backdrop:-}" ]; then
        "$tmp/backdrop" 40 $((sh - 840)) 1160 800 "$backdrop" &
        bp=$!
        sleep 0.5
    fi
    # Pretending to run under Xcode keeps the frame arguments out of Ghostty's
    # config, whose error window would otherwise cover a screen shot.
    env "$@" __XCODE_BUILT_PRODUCTS_DIR_PATHS=1 XDG_CONFIG_HOME="$tmp/xdg-$name" GHOSTTY_CONFIG_PATH="$tmp/config" \
        "$app/Contents/MacOS/raptor" "-NSWindow Frame Raptor $sid" "80 $((sh - 800)) 1080 720 0 0 $sw $sh" \
        >"$tmp/app-$name.log" 2>&1 &
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
    sleep 2.5
    shot=$out/raptor-$name.png
    if [ -n "$bp" ]; then
        screencapture -x -R80,80,1080,720 "$shot"
        kill "$bp"
        # sh keeps an assignment made for a function call; the next shot has none.
        backdrop=
    else
        screencapture -x -o -l"$id" "$shot"
    fi
    # The checks are in 2x pixels; a 1x display's shot is doubled, pixel for pixel.
    if [ "$(magick identify -format %w "$shot")" -lt 2000 ]; then
        magick "$shot" -filter point -resize 200% "$shot"
    fi
    unset RAP_SERVER
    pkill -f "$app/Contents/MacOS/raptor" || true
    sleep 1
    RAP_SERVER=$sock "$rap" server stop >/dev/null 2>&1 || true
    rm -f "$sock.lock"
}

# The columns of row $2 whose colour is within 2/255 of $3, as runs "first last".
runs() {
    row "$1" "$2" | awk -v want="$3" '
        function h(s) { return (index("0123456789ABCDEF", substr(s, 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(s, 2, 1)) - 1 }
        function d(a, b) { return a > b ? a - b : b - a }
        { ok = 1; for (i = 1; i <= 5; i += 2) if (d(h(substr($2, i, 2)), h(substr(want, i, 2))) > 2) ok = 0
          if (ok) { if (last == "" || $1 != last + 1) { if (first != "") print first, last; first = $1 } last = $1 } }
        END { if (first != "") print first, last }'
}

# The rows of column $2 whose colour is within 2/255 of $3, as runs.
colruns() {
    magick "$1" -rotate 90 -flop "$tmp/rot.png"
    runs "$tmp/rot.png" "$2" "$3"
}

# T8's chrome: no headers, no islands, opaque.
t8="RAPTOR_INTERFACE_STYLE=solid RAPTOR_PANE_DENSITY=compact RAPTOR_PANE_HEADERS=0"

# shellcheck disable=SC2086
shoot dark 161616 $t8
img=$out/raptor-dark.png
if [ -f "$img" ]; then
    echo "dark: $(magick identify -format '%wx%h' "$img") px"
    near "chrome" "$(px "$img" 2000 8)" 131313
    # The hairline under the title bar, at the right edge clear of tabs.
    for y in $(seq 60 100); do
        [ "$(px "$img" 2100 "$y")" != "$(px "$img" 2100 8)" ] && break
    done
    within "title bar height (px at 2x)" "$y" 2 80
    # The track: from the first to the last pixel of its colour across the bar's
    # middle row; the tabs' contents lie inside it.
    read -r t0 t1 <<EOF
$(runs "$img" 40 242424 | awk 'NR == 1 { a = $1 } { b = $2 } END { print a, b }')
EOF
    within "track width (px at 2x)" $((t1 - t0 + 1)) 2 1260
    # The active pill: from its first pixel to the first long run of track after
    # it; the card and title inside it aren't pill colour.
    x0=$(runs "$img" 40 2E2E2E | head -n 1 | cut -d' ' -f1)
    x1=$(runs "$img" 40 242424 | awk -v a="${x0:-0}" '$1 > a && $2 - $1 >= 10 { print $1 - 1; exit }')
    w=$((${x1:-0} - ${x0:-0} + 1))
    # The track's height just past the pill, before the next tab's card.
    th=$(colruns "$img" $((x1 + 6)) 242424 | awk '{ print $2 - $1 + 1 }' | sort -rn | head -n 1)
    within "track height (px at 2x)" "${th:-0}" 2 64
    within "pill width (px at 2x)" "${w:-0}" 2 416
    near "pill" "$(px "$img" $((x0 + w - 40)) 40)" 2E2E2E
    ph=$(colruns "$img" $((x0 + w - 40)) 2E2E2E | awk '{ print $2 - $1 + 1 }' | sort -rn | head -n 1)
    within "pill height (px at 2x)" "${ph:-0}" 4 56
    # Only the gap between the two inactive tabs shows its divider, one tab past
    # the pill; titles' antialiasing elsewhere can share its colour.
    dv=$(runs "$img" 42 4F4F4F | awk -v at="$((x1 + 418))" '$1 >= at - 6 && $1 <= at + 6' | head -n 1)
    within "divider width (px at 2x)" "$(echo "$dv" | awk '{ print $2 - $1 + 1 }')" 0 2
    dh=$(colruns "$img" "$(echo "$dv" | cut -d' ' -f1)" 4F4F4F | awk '{ print $2 - $1 + 1 }' | sort -rn | head -n 1)
    within "divider height (px at 2x)" "${dh:-0}" 2 34
    # The vertical divider between the left and right panes.
    d=none
    for x in $(seq 1070 1090); do
        c=$(px "$img" "$x" 1300)
        [ "$c" = "$(px "$img" 1060 1300)" ] || {
            d=$c
            break
        }
    done
    near "split divider" "$d" 242424
fi

# shellcheck disable=SC2086
shoot light F8F6FB $t8
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

# Colour $1 (RRGGBB) under the island sheen: 15% white on dark themes ($2 dark),
# 10% black on light ones.
sheen() {
    for i in 1 3 5; do
        c=$(printf %d "0x$(echo "$1" | cut -c$i-$((i + 1)))")
        if [ "$2" = dark ]; then c=$(((c * 85 + 255 * 15 + 50) / 100)); else c=$(((c * 90 + 50) / 100)); fi
        printf %02X "$c"
    done
}

# Islands: cards and the chrome around them.
islands() {
    img=$1 chrome=$2 card=$3 border=$4
    w=$(magick identify -format %w "$img")
    h=$(magick identify -format %h "$img")
    # Mid-height, past the window's rounded corners: left card, right cards.
    runs "$img" 700 "$border" >"$tmp/edges"
    within "left inset (px at 2x)" "$(sed -n 1p "$tmp/edges" | cut -d' ' -f1)" 2 16
    right=$(tail -n 1 "$tmp/edges" | cut -d' ' -f2)
    within "right inset (px at 2x)" $((w - 1 - right)) 2 16
    l_end=$(sed -n 2p "$tmp/edges" | cut -d' ' -f2)
    r_start=$(sed -n 3p "$tmp/edges" | cut -d' ' -f1)
    within "gutter (px at 2x)" $((r_start - l_end - 1)) 2 18
    near "chrome between cards" "$(px "$img" $(((l_end + r_start) / 2)) 700)" "$chrome"
    # Down the left card, clear of its header's text and buttons.
    colruns "$img" 600 "$border" >"$tmp/edges"
    within "card top (px at 2x)" "$(sed -n 1p "$tmp/edges" | cut -d' ' -f1)" 2 92
    bottom=$(tail -n 1 "$tmp/edges" | cut -d' ' -f2)
    within "bottom inset (px at 2x)" $((h - 1 - bottom)) 2 16
    near "card" "$(px "$img" 600 $((bottom - 40)))" "$card"
    near "card border" "$(px "$img" 600 92)" "$border"
    near "chrome above the card" "$(px "$img" 600 86)" "$chrome"
    # A 10 pt radius leaves the corner's first 5 px diagonal outside the card.
    near "rounded corner" "$(px "$img" 20 96)" "$chrome"
    near "header" "$(px "$img" 600 120)" "$card"
}

# shellcheck disable=SC2086
shoot islands 131313 RAPTOR_INTERFACE_STYLE=solid RAPTOR_PANE_DENSITY=islands RAPTOR_PANE_HEADERS=1
img=$out/raptor-islands.png
if [ -f "$img" ]; then
    echo "islands: $(magick identify -format '%wx%h' "$img") px"
    islands "$img" 111111 131313 262626
fi

shoot compact 0F1518 RAPTOR_INTERFACE_STYLE=solid RAPTOR_PANE_DENSITY=compact RAPTOR_PANE_HEADERS=1
img=$out/raptor-compact.png
if [ -f "$img" ]; then
    echo "compact: $(magick identify -format '%wx%h' "$img") px"
    v=$(runs "$img" 900 1E2226 | head -n 1 | cut -d' ' -f1)
    within "vertical divider (px at 2x)" "${v:-0}" 4 1080
    # The left pane is unfocused: its header is chrome down to the pane.
    near "unfocused header" "$(px "$img" 600 116)" 0B1212
    hb=$(colruns "$img" 600 0B1212 | awk '$1 <= 84 && $2 > 100 { print $2 }' | head -n 1)
    within "header bottom (px at 2x)" "${hb:-0}" 2 149
    # The focused pane, bottom right, keeps the pane background.
    hdiv=$(colruns "$img" 1700 1E2226 | awk '$1 > 200 { print $1 }' | head -n 1)
    near "horizontal divider" "$(px "$img" 1700 "${hdiv:-0}")" 1E2226
    near "focused header" "$(px "$img" 1700 $((${hdiv:-0} + 34)))" 0F1518
fi

shoot fresh "" RAPTOR_INTERFACE_STYLE=blended RAPTOR_PANE_DENSITY=islands RAPTOR_PANE_HEADERS=1
img=$out/raptor-fresh.png
if [ -f "$img" ]; then
    echo "fresh: $(magick identify -format '%wx%h' "$img") px"
    # The window alone shows the blur over a plain backdrop: the card body is the
    # chrome's colour, and each card's rim at either edge is the sheen over it.
    near "card body is the chrome" "$(px "$img" 40 700)" "$(px "$img" 8 700)"
    runs "$img" 700 "$(sheen "$(px "$img" 40 700)" dark)" >"$tmp/edges"
    within "fresh install has islands" "$(wc -l <"$tmp/edges" | tr -d ' ')" 0 4
fi

# How much of what's behind the window pixel $3,$4 lets through, in percent:
# its rise from shot $1 (over black) to shot $2 (over white).
through() {
    k=$(px "$1" "$3" "$4")
    w=$(px "$2" "$3" "$4")
    awk -v k="$k" -v w="$w" '
        function h(s) { return (index("0123456789ABCDEF", substr(s, 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(s, 2, 1)) - 1 }
        BEGIN { t = 0; for (i = 1; i <= 5; i += 2) t += h(substr(w, i, 2)) - h(substr(k, i, 2)); printf "%d", t * 100 / 765 + 0.5 }'
}

# Translucent panes: $1 name, $2 background, $3 dark or light, then settings.
translucent() {
    tname=$1 bg=$2 theme=$3
    shift 3
    backdrop=000000 shoot "$tname-k" "$bg" "$@"
    backdrop=FFFFFF shoot "$tname-w" "$bg" "$@"
    k=$out/raptor-$tname-k.png w=$out/raptor-$tname-w.png
    [ -f "$k" ] && [ -f "$w" ] || return 0
    echo "$tname: $(magick identify -format '%wx%h' "$k") px"
    # The left card's body, low down clear of text, and the gutter between cards.
    body=$(through "$k" "$w" 600 1300)
    within "pane body lets through what the chrome does (%)" "$body" 2 "$(through "$k" "$w" 1078 700)"
    if [ "$body" -ge 20 ]; then echo "ok   pane body lets through $body%"; else
        echo "FAIL pane body lets through $body%, want at least 20%"
        fail=1
    fi
    # Over black, the rim at the left card's left edge is the sheen over the body.
    near "island sheen" "$(px "$k" 16 700)" "$(sheen "$(px "$k" 40 700)" "$theme")"
}

panes="RAPTOR_PANE_DENSITY=islands RAPTOR_PANE_HEADERS=1"
# shellcheck disable=SC2086
translucent blended-dark 0A0C10 dark RAPTOR_INTERFACE_STYLE=blended $panes RAPTOR_TRANSLUCENT_PANES=1
# shellcheck disable=SC2086
translucent blended-light F8F6FB light RAPTOR_INTERFACE_STYLE=blended $panes RAPTOR_TRANSLUCENT_PANES=1
# shellcheck disable=SC2086
translucent glass-dark 0A0C10 dark RAPTOR_INTERFACE_STYLE=glass $panes RAPTOR_TRANSLUCENT_PANES=1
# shellcheck disable=SC2086
translucent glass-light F8F6FB light RAPTOR_INTERFACE_STYLE=glass $panes RAPTOR_TRANSLUCENT_PANES=1

# shellcheck disable=SC2086
backdrop=000000 shoot opaque-k 0A0C10 RAPTOR_INTERFACE_STYLE=blended $panes RAPTOR_TRANSLUCENT_PANES=0
# shellcheck disable=SC2086
backdrop=FFFFFF shoot opaque-w 0A0C10 RAPTOR_INTERFACE_STYLE=blended $panes RAPTOR_TRANSLUCENT_PANES=0
k=$out/raptor-opaque-k.png w=$out/raptor-opaque-w.png
if [ -f "$k" ] && [ -f "$w" ]; then
    echo "opaque: $(magick identify -format '%wx%h' "$k") px"
    within "opaque pane body lets through (%)" "$(through "$k" "$w" 600 1300)" 0 0
fi

# The command palette, unfiltered, in the 2x screenshot $1.
palette() {
    img=$1
    # Between the field and the first row the panel is plain popover colour.
    runs "$img" 232 30343F >"$tmp/edges"
    x0=$(head -n 1 "$tmp/edges" | cut -d' ' -f1)
    x1=$(tail -n 1 "$tmp/edges" | cut -d' ' -f2)
    # The run is inside a 1 pt border.
    within "palette width (px at 2x)" $((x1 - x0 + 5)) 4 660
    within "palette centre (px at 2x)" $(((x0 + x1) / 2)) 2 1080
    near "palette" "$(px "$img" 1080 232)" 30343F
    # Down the middle: the margins above the field and below the last row.
    colruns "$img" 1080 30343F >"$tmp/edges"
    y0=$(head -n 1 "$tmp/edges" | cut -d' ' -f1)
    y1=$(tail -n 1 "$tmp/edges" | cut -d' ' -f2)
    within "palette top (px at 2x)" $((y0 - 2)) 2 152
    # 8 + 29 field + 7 + 16 rows of 28 + 6.
    within "palette height (px at 2x)" $((y1 - y0 + 5)) 4 996
    # Shortcut glyphs: ink near the rows' trailing edge.
    ink=$(magick "$img" -crop 60x896+$((x1 - 80))+$((y0 + 86)) +repage -fill black -fuzz 3% -opaque "#30343F" \
        -fill white +opaque black -format '%[fx:int(mean*w*h)]' info:)
    if [ "$ink" -gt 200 ]; then echo "ok   trailing glyphs: $ink px of ink"; else
        echo "FAIL trailing glyphs: $ink px of ink"
        fail=1
    fi
}

palette_env="RAPTOR_INTERFACE_STYLE=solid RAPTOR_PANE_DENSITY=compact RAPTOR_PANE_HEADERS=0"

# shellcheck disable=SC2086
shoot palette 232831 $palette_env RAPTOR_PALETTE_QUERY=
img=$out/raptor-palette.png
if [ -f "$img" ]; then
    echo "palette: $(magick identify -format '%wx%h' "$img") px"
    palette "$img"
fi

# shellcheck disable=SC2086
shoot filtered 232831 $palette_env RAPTOR_PALETTE_QUERY=spl
img=$out/raptor-filtered.png
if [ -f "$img" ]; then
    echo "filtered: $(magick identify -format '%wx%h' "$img") px"
    # The first row, 44 pt into the panel, is filled with the accent, here
    # between its title and its shortcut.
    near "selected row" "$(px "$img" 1250 268)" 8060B5
    a=$(colruns "$img" 1250 8060B5 | head -n 1)
    within "selected row height (px at 2x)" $((${a#* } - ${a% *} + 1)) 2 52
fi

# shellcheck disable=SC2086
shoot sessions 232831 $palette_env RAPTOR_SESSIONS=1
img=$out/raptor-sessions.png
if [ -f "$img" ]; then
    echo "sessions: $(magick identify -format '%wx%h' "$img") px"
    # Below its last row.
    near "switcher" "$(px "$img" 300 318)" 30343F
fi

if [ -n "$refs" ]; then
    magick "$out/raptor-palette.png" -resize 1200x "$refs/v3_4fps_006.jpg" -resize 1200x -append \
        -quality 85 "$out/side-by-side-palette.jpg"
    magick "$out/raptor-filtered.png" -crop 900x400+630+80 +repage "$refs/v3_crop_palette_filtered_t2.0.jpg" -append \
        -quality 85 "$out/side-by-side-filtered.jpg"
    magick "$out/raptor-islands.png" -resize 1200x "$refs/v1_4fps_001.jpg" -resize 1200x -append \
        -quality 85 "$out/side-by-side-islands.jpg"
    magick "$out/raptor-compact.png" -resize 1200x "$refs/v2_4fps_049.jpg" -resize 1200x -append \
        -quality 85 "$out/side-by-side-compact.jpg"
    magick "$out/raptor-dark.png" -resize 1200x "$refs/v4_4fps_001.jpg" -resize 1200x -append \
        -quality 85 "$out/side-by-side-dark.jpg"
    magick "$out/raptor-light.png" -crop 2160x120+0+0 -resize 1200x "$refs/acc_on_crop_tabstrip_light.png" -resize 1200x -append \
        -quality 85 "$out/side-by-side-light.jpg"
fi
exit $fail

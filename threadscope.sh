#!/usr/bin/env bash
# =============================================================================
#  Threadscope — find the fastest local-inference settings for THIS machine
#
#    ./threadscope.sh --build --fetch medium      # set everything up
#    ./threadscope.sh -m model.gguf               # measure
#
#  Produces:  report.json                  -> paste into the Threadscope page
#             tuning_recommendations.sh    -> optional, reversible system tweaks
#
#  NO WARRANTY. Reads settings, measures, writes two files in the current
#  directory. Never deletes anything, stops services, or changes system state.
# =============================================================================

set -uo pipefail
export LC_ALL=C   # numbers must use "." not "," or the JSON breaks

MODEL=""; BIN=""; TOKENS=128; QUICK=0; OUT=""; REC=""
OUTDIR="runs"; TAG=""
FETCH=""; FETCH_URL=""; DO_BUILD=0
PROMPT="Write a detailed technical explanation of how ocean currents regulate global climate."

B=$'\033[1m'; D=$'\033[2m'; A=$'\033[33m'; G=$'\033[32m'; R=$'\033[31m'; X=$'\033[0m'
note(){ printf "%s%s%s\n" "$D" "$1" "$X" >&2; }
err(){  printf "%s%s%s\n" "$R" "$1" "$X" >&2; }
hdr(){ printf "\n%s%s%s\n" "$B" "$1" "$X" >&2; }

usage(){ sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; cat >&2 <<'U'
Options
  -m, --model PATH   GGUF model to test
  -b, --bin PATH     path to llama-cli (auto-detected if omitted)
  -n, --tokens N     tokens per run (default 128)
  -o, --out PATH     exact JSON path (overrides the archive naming)
      --outdir DIR   where runs are archived (default ./runs)
      --tag NAME     label this run, e.g. --tag before-tuning
      --fetch SIZE   download a test model: small | medium | large
      --fetch-url U  download a GGUF from your own URL
      --build        clone and build llama.cpp into ./llama.cpp
      --quick        fewer sample points
U
exit 0; }

while [ $# -gt 0 ]; do case "$1" in
  -m|--model) MODEL="$2"; shift 2 ;;
  -b|--bin)   BIN="$2";   shift 2 ;;
  -n|--tokens)TOKENS="$2";shift 2 ;;
  -o|--out)   OUT="$2";   shift 2 ;;
  --outdir)   OUTDIR="$2"; shift 2 ;;
  --tag)      TAG="$2";   shift 2 ;;
  --fetch)    FETCH="$2"; shift 2 ;;
  --fetch-url)FETCH_URL="$2"; shift 2 ;;
  --build)    DO_BUILD=1; shift ;;
  --quick)    QUICK=1;    shift ;;
  -h|--help)  usage ;;
  *) err "Unknown option: $1"; exit 1 ;;
esac; done

# ------------------------------------------------------------------ host facts
OS="$(uname -s)"; KERNEL="$(uname -r)"
case "$OS" in
  Linux)
    CPU=$(sed -n 's/^model name[ \t]*: //p' /proc/cpuinfo | head -1)
    LOGICAL=$(getconf _NPROCESSORS_ONLN)
    TPC=$(lscpu 2>/dev/null | sed -n 's/^Thread(s) per core: *//p' | head -1); TPC=${TPC:-1}
    PHYSICAL=$(( LOGICAL / TPC )); [ "$PHYSICAL" -lt 1 ] && PHYSICAL=1
    NUMA=$(lscpu 2>/dev/null | sed -n 's/^NUMA node(s): *//p' | head -1); NUMA=${NUMA:-1}
    RAM_GB=$(awk '/MemTotal/{printf "%.0f",$2/1048576}' /proc/meminfo)
    THP=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    VIRT=$(systemd-detect-virt 2>/dev/null); [ -z "$VIRT" ] && VIRT=none
    grep -qi microsoft /proc/version 2>/dev/null && VIRT="wsl"
    CORELIST=$(lscpu -p=CPU,CORE 2>/dev/null | grep -v '^#' | sort -t, -k2 -u -n \
               | cut -d, -f1 | sort -n | paste -sd, -)
    command -v taskset >/dev/null 2>&1 && CAN_PIN=1 || CAN_PIN=0 ;;
  Darwin)
    CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    LOGICAL=$(sysctl -n hw.logicalcpu); PHYSICAL=$(sysctl -n hw.physicalcpu)
    NUMA=1; RAM_GB=$(( $(sysctl -n hw.memsize)/1073741824 ))
    THP="n/a"; GOV="n/a"; VIRT="none"; CORELIST=""; CAN_PIN=0 ;;
  *) err "Unsupported OS: $OS — use WSL on Windows."; exit 1 ;;
esac
: "${CPU:=unknown}"; : "${THP:=n/a}"; : "${GOV:=n/a}"

# Any captured value can contain newlines, quotes or backslashes. Strip and
# escape them, or the JSON we emit will not parse.
jstr(){ printf '%s' "${1-}" | tr -d '\r' | tr '\n\t' '  ' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^ *//' -e 's/ *$//'; }
CPU=$(jstr "$CPU"); OS=$(jstr "$OS"); KERNEL=$(jstr "$KERNEL"); VIRT=$(jstr "$VIRT")
THP=$(jstr "$THP"); GOV=$(jstr "$GOV"); CORELIST=$(jstr "$CORELIST")

# --------------------------------------------------------------- optional setup
if [ "$DO_BUILD" = "1" ]; then
  hdr "Building llama.cpp"
  if [ -x llama.cpp/build/bin/llama-cli ]; then note "Already built."
  else
    command -v cmake >/dev/null || { err "cmake not found. Install build tools first."; exit 1; }
    [ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp || exit 1
    ( cd llama.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null \
      && cmake --build build --config Release -j"$LOGICAL" >/dev/null ) \
      || { err "Build failed."; exit 1; }
    note "Built."
  fi
  BIN="${BIN:-$PWD/llama.cpp/build/bin/llama-cli}"
fi

if [ -n "$FETCH" ] || [ -n "$FETCH_URL" ]; then
  hdr "Downloading model"
  case "$FETCH" in
    small)  U="https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf" ;;
    medium) U="https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf" ;;
    large)  U="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf" ;;
    "")     U="$FETCH_URL" ;;
    *) err "--fetch takes: small | medium | large"; exit 1 ;;
  esac
  mkdir -p models; F="models/$(basename "${U%%\?*}")"
  if [ -s "$F" ]; then note "Already downloaded: $F"
  else
    curl -L --fail --progress-bar -o "$F" "$U" || { rm -f "$F"; err "Download failed. Check the URL or your connection."; exit 1; }
  fi
  MODEL="${MODEL:-$F}"
fi

# ------------------------------------------------------------------- locate bin
if [ -z "$BIN" ]; then
  for c in "$(command -v llama-cli 2>/dev/null)" ./llama.cpp/build/bin/llama-cli \
           "$HOME/os-ai-benchmark/llama.cpp/build/bin/llama-cli" \
           "$HOME/llama.cpp/build/bin/llama-cli"; do
    [ -n "$c" ] && [ -x "$c" ] && BIN="$c" && break
  done
fi
[ -x "${BIN:-}" ] || { err "llama-cli not found. Run with --build, or pass -b /path/to/llama-cli"; exit 1; }
[ -f "${MODEL:-}" ] || { err "No model. Run with --fetch medium, or pass -m /path/to/model.gguf"; exit 1; }
MODEL_GB=$(awk -v b="$(wc -c < "$MODEL")" 'BEGIN{printf "%.2f",b/1073741824}')

# ------------------------------------------------- output paths (never overwrite)
# Every run is archived under $OUTDIR with a timestamp, so repeated runs can be
# compared instead of clobbering each other. Convenience copies of the most
# recent run are also left in the working directory.
uniq_path(){ local p="$1" b e i=2; b="${p%.*}"; e="${p##*.}"
  while [ -e "$p" ]; do p="${b}-${i}.${e}"; i=$((i+1)); done; printf '%s' "$p"; }

STAMP=$(date +%Y%m%d-%H%M%S)
STEM=$(basename "$MODEL"); STEM="${STEM%.gguf}"
STEM=$(printf '%s' "$STEM" | tr -cs 'A-Za-z0-9._-' '-' | cut -c1-42)
SAFETAG=$(printf '%s' "$TAG" | tr -cs 'A-Za-z0-9._-' '-'); SAFETAG="${SAFETAG%-}"
BASE="report-${STAMP}${SAFETAG:+-$SAFETAG}-${STEM}"
mkdir -p "$OUTDIR" 2>/dev/null || { err "Cannot create $OUTDIR"; exit 1; }
[ -n "$OUT" ] || OUT=$(uniq_path "$OUTDIR/$BASE.json")
[ -n "$REC" ] || REC=$(uniq_path "$OUTDIR/$BASE.tuning.sh")

HELP="$("$BIN" --help 2>&1)"; FLAGS=""
if   grep -q -- "--no-conversation" <<< "$HELP"; then FLAGS="--no-conversation"
elif grep -q -- "-no-cnv"           <<< "$HELP"; then FLAGS="-no-cnv"; fi
grep -q -- "--single-turn" <<< "$HELP" && FLAGS="$FLAGS -st"
grep -q -- "--seed"        <<< "$HELP" && FLAGS="$FLAGS --seed 42"

# ------------------------------------------------------------------- measuring
TIMEFORMAT='%R|%U|%S'
measure(){ # <threads> <pin>  ->  wall|user|sys|tps
  local t="$1" pin="$2" pre=() raw w u s tps log; log=$(mktemp)
  [ "$pin" = "1" ] && [ "$CAN_PIN" = "1" ] && pre=(taskset -c "$CORELIST")
  raw=$( { time "${pre[@]}" "$BIN" -m "$MODEL" -p "$PROMPT" -n "$TOKENS" -t "$t" \
           $FLAGS < /dev/null > "$log" 2>&1; } 2>&1 | tail -1 )
  IFS='|' read -r w u s <<< "$raw"
  # llama.cpp has printed this three different ways across versions.
  tps=$(grep -oE '[0-9]+\.[0-9]+ *(tokens per second|tokens/s|t/s)' "$log" | tail -1 | awk '{print $1}')
  # If none of them matched, derive it. Slightly lower than the engine's own
  # figure because it includes load and prompt time, but consistent across runs.
  if [ -z "$tps" ] || [ "$tps" = "0" ]; then
    tps=$(awk -v n="$TOKENS" -v t="${w:-0}" 'BEGIN{printf "%.2f", (t>0)? n/t : 0}')
  fi
  rm -f "$log"; echo "${w:-0}|${u:-0}|${s:-0}|${tps:-0}"
}

LIST=$( { n=1; while [ "$n" -le "$LOGICAL" ]; do echo "$n"; n=$((n*2)); done; \
          echo "$PHYSICAL"; echo "$LOGICAL"; } | sort -n -u | tr '\n' ' ')
[ "$QUICK" = "1" ] && LIST=$(tr ' ' '\n' <<< "$LIST" | awk 'NR%2==1 || $1=='"$PHYSICAL"'' | tr '\n' ' ')

hdr "Threadscope"
note "$CPU"
note "$PHYSICAL physical / $LOGICAL logical cores · $(basename "$MODEL") · $TOKENS tokens"
note "Testing threads:$LIST — keep the machine idle. A few minutes."
printf "\n" >&2
note "Warming cache..."; measure "$PHYSICAL" 0 >/dev/null

printf "  %-8s %-7s %9s %9s %8s\n" threads pinned "wall(s)" "cpu(s)" "tok/s" >&2
SWEEP=""; BEST_T="$PHYSICAL"; BEST_W=""
for t in $LIST; do
  IFS='|' read -r w u s tps <<< "$(measure "$t" 0)"
  c=$(awk -v a="$u" -v b="$s" 'BEGIN{printf "%.2f",a+b}')
  printf "  %-8s %-7s %9s %9s %8s\n" "$t" no "$w" "$c" "$tps" >&2
  SWEEP="$SWEEP{\"threads\":$t,\"pinned\":false,\"wall\":$w,\"cpu\":$c,\"tps\":${tps:-0}},"
  if [ -z "$BEST_W" ] || awk -v a="$w" -v b="$BEST_W" 'BEGIN{exit !(a<b)}'; then BEST_W="$w"; BEST_T="$t"; fi
done

BEST_PIN=false
if [ "$CAN_PIN" = "1" ]; then
  for t in $BEST_T $PHYSICAL; do
    grep -q "\"threads\":$t,\"pinned\":true" <<< "$SWEEP" && continue
    IFS='|' read -r w u s tps <<< "$(measure "$t" 1)"
    c=$(awk -v a="$u" -v b="$s" 'BEGIN{printf "%.2f",a+b}')
    printf "  %-8s %-7s %9s %9s %8s\n" "$t" yes "$w" "$c" "$tps" >&2
    SWEEP="$SWEEP{\"threads\":$t,\"pinned\":true,\"wall\":$w,\"cpu\":$c,\"tps\":${tps:-0}},"
    if awk -v a="$w" -v b="$BEST_W" 'BEGIN{exit !(a<b)}'; then BEST_W="$w"; BEST_T="$t"; BEST_PIN=true; fi
  done
fi
SWEEP="${SWEEP%,}"

SMT=$( [ "$LOGICAL" -gt "$PHYSICAL" ] && echo true || echo false )
PINOK=$( [ "$CAN_PIN" = "1" ] && echo true || echo false )

cat > "$OUT" <<EOF
{
  "schema":"threadscope/2",
  "generated":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host":{"cpu":"$CPU","os":"$OS","kernel":"$KERNEL","virt":"$VIRT",
          "logical":$LOGICAL,"physical":$PHYSICAL,"numa":$NUMA,"ram_gb":$RAM_GB},
  "engine":"llama.cpp",
  "model":{"name":"$(jstr "$(basename "$MODEL")")","size_gb":$MODEL_GB},
  "tokens":$TOKENS,
  "advisories":{"thp":"$THP","governor":"$GOV","smt":$SMT,"can_pin":$PINOK},
  "corelist":"$CORELIST",
  "best":{"threads":$BEST_T,"pinned":$BEST_PIN},
  "sweep":[ $SWEEP ]
}
EOF

# Never hand the user a file that won't parse.
VALID=1
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT" 2>/dev/null || VALID=0
elif command -v node >/dev/null 2>&1; then
  node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$OUT" 2>/dev/null || VALID=0
fi
if [ "$VALID" = "0" ]; then
  err "The generated JSON is malformed — please open an issue and attach $OUT"
  err "Values captured: threads=$BEST_T pinned=$BEST_PIN cpu='$CPU'"
fi

# ------------------------------------------------- generate the tuning script
PINCMD=""; [ "$BEST_PIN" = "true" ] && PINCMD="taskset -c $CORELIST "
cat > "$REC" <<EOF
#!/usr/bin/env bash
# =============================================================================
#  Tuning recommendations for: $CPU
#  Generated by Threadscope on $(date -u +%Y-%m-%d)
#
#  NO WARRANTY OF ANY KIND. These are suggestions based on measurements taken
#  on this machine. You run them at your own risk. The author of Threadscope
#  accepts no liability for anything that happens to your system.
#
#  What this script does NOT do: delete files, stop services, kill processes,
#  install packages, or change anything permanently. Both settings below reset
#  on reboot, and '--revert' restores them immediately.
#
#  If this helped you: do something kind for someone who will never know it
#  was you. That is the whole price.
#
#  Usage:  ./$(basename "$REC")            show what would change
#          ./$(basename "$REC") --apply    apply it (asks for sudo)
#          ./$(basename "$REC") --revert   put everything back
# =============================================================================
set -uo pipefail
STATE="\$HOME/.threadscope-revert"
BEST_THREADS=$BEST_T
CORELIST="$CORELIST"
THP_NOW="$THP"
GOV_NOW="$GOV"

b=\$'\033[1m'; d=\$'\033[2m'; a=\$'\033[33m'; g=\$'\033[32m'; x=\$'\033[0m'

launch(){
  echo ""
  echo "\${b}Run your model like this\${x}   \${d}(no system changes, always safe)\${x}"
  echo ""
  echo "  ${PINCMD}llama-cli -m your-model.gguf -t \$BEST_THREADS -p \"...\" -n 256"
  echo ""
  echo "  \${d}ollama:  OLLAMA_NUM_THREADS=\$BEST_THREADS ollama run your-model\${x}"
  echo ""
}

case "\${1:-}" in
--apply)
  launch
  echo "\${b}System settings\${x}  \${d}(needs sudo, resets on reboot, revert below)\${x}"
  mkdir -p "\$(dirname "\$STATE")"; : > "\$STATE"
  if [ -w /sys/kernel/mm/transparent_hugepage/enabled ] || sudo -n true 2>/dev/null || true; then
    if [ "\$THP_NOW" != "always" ] && [ "\$THP_NOW" != "n/a" ]; then
      echo "thp=\$THP_NOW" >> "\$STATE"
      echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null \\
        && echo "  \${g}✓\${x} huge pages: \$THP_NOW -> always"
    fi
  fi
  if [ "\$GOV_NOW" != "performance" ] && [ "\$GOV_NOW" != "n/a" ] && command -v cpupower >/dev/null 2>&1; then
    echo "gov=\$GOV_NOW" >> "\$STATE"
    sudo cpupower frequency-set -g performance >/dev/null 2>&1 \\
      && echo "  \${g}✓\${x} cpu governor: \$GOV_NOW -> performance"
  fi
  echo ""
  echo "  \${d}Revert any time:  ./\$(basename "\$0") --revert\${x}"
  echo ""
  ;;
--revert)
  [ -f "\$STATE" ] || { echo "Nothing to revert."; exit 0; }
  while IFS='=' read -r k v; do
    case "\$k" in
      thp) echo "\$v" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null \\
             && echo "  \${g}✓\${x} huge pages restored to \$v" ;;
      gov) sudo cpupower frequency-set -g "\$v" >/dev/null 2>&1 \\
             && echo "  \${g}✓\${x} cpu governor restored to \$v" ;;
    esac
  done < "\$STATE"
  rm -f "\$STATE"
  echo ""
  ;;
*)
  launch
  echo "\${b}Optional system settings\${x}"
  [ "\$THP_NOW" != "always" ] && [ "\$THP_NOW" != "n/a" ] \\
    && echo "  huge pages   \$THP_NOW \${a}->\${x} always      \${d}fewer page faults on large models\${x}"
  [ "\$GOV_NOW" != "performance" ] && [ "\$GOV_NOW" != "n/a" ] \\
    && echo "  cpu governor \$GOV_NOW \${a}->\${x} performance \${d}stops clocks dropping mid-run\${x}"
  echo ""
  echo "  \${d}Apply with:  ./\$(basename "\$0") --apply     Undo with: --revert\${x}"
  echo "  \${d}Both reset on reboot regardless.\${x}"
  echo ""
  ;;
esac
EOF
chmod +x "$REC"

# Leave a copy of the newest run where the docs say to look for it.
copy_latest(){ [ "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" = "$PWD/$2" ] || cp -f "$1" "$2"; }
copy_latest "$OUT" report.json
copy_latest "$REC" tuning_recommendations.sh && chmod +x tuning_recommendations.sh 2>/dev/null

RUNS=$(find "$OUTDIR" -maxdepth 1 -name 'report-*.json' 2>/dev/null | wc -l | tr -d ' ')

hdr "Done"
printf "  %s%s%s\n" "$G" "$OUT" "$X" >&2
note "  archived — drop this on the Threadscope page"
printf "  %s%s%s\n" "$G" "$REC" "$X" >&2
note "  archived — run it to see your tuning options"
printf "\n" >&2
note "Latest copies also written to ./report.json and ./tuning_recommendations.sh"
note "$RUNS run$( [ "$RUNS" = "1" ] || echo s ) now archived in $OUTDIR/ — earlier ones are untouched"
printf "\n" >&2
note "Best setting found: -t $BEST_T$( [ "$BEST_PIN" = "true" ] && echo " with pinning" )"
printf "\n" >&2

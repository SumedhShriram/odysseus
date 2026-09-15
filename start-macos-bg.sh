#!/bin/bash
# Odysseus for macOS — run the server in the background with a menu-bar monitor.
#
#   ./start-macos-bg.sh            setup if needed, start server, show menu bar
#   ./start-macos-bg.sh --stop     stop the server
#   ./start-macos-bg.sh --restart  restart the server
#   ./start-macos-bg.sh --status   print status and exit
#   ./start-macos-bg.sh --server-only   start the server, no menu bar
#   ./start-macos-bg.sh --no-setup      skip the venv/deps check (faster)
#
# The server is detached into its own process group, so closing the terminal
# leaves it running and one killpg tears down uvicorn and all its children.
#
# Config precedence, highest first:
#   ODYSSEUS_PORT / ODYSSEUS_HOST   explicit override for this script
#   APP_PORT / APP_BIND             exported in the calling shell
#   APP_PORT / APP_BIND in .env     deployment default
#   7860 / 127.0.0.1                built-in fallback (7000 is held by AirPlay)

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$REPO_DIR/$(basename "${BASH_SOURCE[0]}")"
RUN_DIR="$REPO_DIR/logs"
STATE="$RUN_DIR/odysseus-run.env"
LOG="$RUN_DIR/odysseus-server.log"
AGENT="$REPO_DIR/dist/OdysseusMenuBar.app"

MODE="run"
DO_SETUP=1
for arg in "$@"; do
    case "$arg" in
        --stop)        MODE="stop" ;;
        --restart)     MODE="restart" ;;
        --status)      MODE="status" ;;
        --server-only) MODE="server-only" ;;
        --no-setup)    DO_SETUP=0 ;;
        -h|--help)     sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ── Config ───────────────────────────────────────────────────────────────────

# env_get KEY — last assignment of KEY in .env, or empty. Tolerates an `export`
# prefix, surrounding whitespace, quoted values, trailing `# comments`, CRLF
# line endings, and a leading UTF-8 BOM.
env_get() {
    local key="$1" line val
    [ -f "$REPO_DIR/.env" ] || return 0

    line="$(sed $'1s/^\xef\xbb\xbf//' "$REPO_DIR/.env" \
            | grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" \
            | tail -1)"
    [ -n "$line" ] || return 0

    val="${line#*=}"
    val="$(printf '%s' "$val" | tr -d '\r' | sed -e 's/^[[:space:]]*//')"
    case "$val" in
        # A quoted value may legitimately contain '#', so take what's inside the
        # quotes; an unquoted one ends at the first comment marker.
        \"*) val="${val#\"}"; val="${val%%\"*}" ;;
        \'*) val="${val#\'}"; val="${val%%\'*}" ;;
        *)   val="${val%%#*}" ;;
    esac
    printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

ENV_PORT="$(env_get APP_PORT)"
ENV_BIND="$(env_get APP_BIND)"
# APP_HOST is not an Odysseus variable, but accept it as an alias so a typo in
# .env fails loudly rather than silently binding to loopback.
if [ -z "$ENV_BIND" ]; then
    ENV_BIND="$(env_get APP_HOST)"
    if [ -n "$ENV_BIND" ]; then
        echo "  ⚠ .env sets APP_HOST; the documented name is APP_BIND. Using it anyway."
    fi
fi

PORT="${ODYSSEUS_PORT:-${APP_PORT:-${ENV_PORT:-7860}}}"
HOST="${ODYSSEUS_HOST:-${APP_BIND:-${ENV_BIND:-127.0.0.1}}}"

case "$PORT" in
    ''|*[!0-9]*) echo "✗ Invalid port: '$PORT'" >&2; exit 2 ;;
esac

PROBE_HOST="$HOST"
if [ "$PROBE_HOST" = "0.0.0.0" ] || [ "$PROBE_HOST" = "::" ]; then
    PROBE_HOST="127.0.0.1"
fi
URL="http://$PROBE_HOST:$PORT"
UVICORN="$REPO_DIR/venv/bin/uvicorn"

if [ "$HOST" != "127.0.0.1" ] && [ "$HOST" != "localhost" ]; then
    echo "  ⚠ Binding to $HOST — reachable beyond this Mac."
    echo "    Keep AUTH_ENABLED=true and don't expose this port to the internet."
fi

mkdir -p "$RUN_DIR"

# ── State helpers ────────────────────────────────────────────────────────────
state_pid() {
    [ -f "$STATE" ] || return 1
    local p
    p="$(grep -E '^PID=' "$STATE" | tail -1 | cut -d= -f2-)"
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    echo "$p"
}

is_healthy() { /usr/bin/curl -fsS -o /dev/null --max-time 2 "$URL" 2>/dev/null; }

port_busy() { (exec 3<>"/dev/tcp/$PROBE_HOST/$PORT") 2>/dev/null; }

write_state() {
    cat > "$STATE" <<EOF
PID=$1
PORT=$PORT
HOST=$HOST
URL=$URL
LOG=$LOG
STARTED=$(date +%s)
EOF
}

# ── Setup (idempotent) ───────────────────────────────────────────────────────
find_python() {
    local candidates=(/opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
                      /opt/homebrew/bin/python3 python3.12 python3.11 python3)
    local p
    for p in "${candidates[@]}"; do
        command -v "$p" >/dev/null 2>&1 || continue
        "$p" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,11) else 1)' 2>/dev/null || continue
        # On Apple Silicon insist on an arm64 interpreter — a universal2 or x86
        # build produces a venv whose compiled extensions load under Rosetta.
        if [ "$(uname -m)" = "arm64" ]; then
            [ "$("$p" -c 'import platform;print(platform.machine())' 2>/dev/null)" = "arm64" ] || continue
        fi
        command -v "$p"
        return 0
    done
    return 1
}

ensure_setup() {
    local stamp="$RUN_DIR/.deps-stamp"

    if ! command -v brew >/dev/null 2>&1; then
        echo "  ⚠ Homebrew not found — Cookbook (local model serving) needs it for tmux."
        echo "    https://brew.sh"
    elif ! command -v tmux >/dev/null 2>&1; then
        echo "▶ Installing tmux…"
        brew install tmux >/dev/null 2>&1 || echo "  ⚠ tmux install failed — Cookbook may be limited."
    fi

    if [ -d "$REPO_DIR/venv" ] && [ ! -x "$REPO_DIR/venv/bin/pip" ]; then
        echo "▶ Existing venv is incomplete — rebuilding…"
        rm -rf "$REPO_DIR/venv"
    fi

    if [ ! -x "$UVICORN" ]; then
        local py
        py="$(find_python)" || {
            echo "✗ No suitable Python found. Install one with:  brew install python@3.12"
            exit 1
        }
        echo "▶ Creating venv with $py"
        "$py" -m venv "$REPO_DIR/venv"
        rm -f "$stamp"
    fi

    if [ ! -f "$stamp" ] || [ "$REPO_DIR/requirements.txt" -nt "$stamp" ]; then
        echo "▶ Installing dependencies…"
        "$REPO_DIR/venv/bin/pip" install -q --upgrade pip
        "$REPO_DIR/venv/bin/pip" install -q -r "$REPO_DIR/requirements.txt"
        "$REPO_DIR/venv/bin/python" "$REPO_DIR/setup.py"
        touch "$stamp"
    fi
}

# ── Start / stop ─────────────────────────────────────────────────────────────
start_server() {
    if pid="$(state_pid)"; then
        echo "▶ Already running (pid $pid) — $URL"
        return 0
    fi
    if port_busy; then
        echo "✗ Port $PORT on $PROBE_HOST is in use by something this script didn't start."
        echo "  Free it, or pick another port:  ODYSSEUS_PORT=7900 $SELF"
        exit 1
    fi
    [ -x "$UVICORN" ] || { echo "✗ venv missing — run $SELF without --no-setup."; exit 1; }

    # The app builds its own URLs (internal API base, pairing codes, MCP OAuth
    # callback) from these, so they must match what uvicorn actually binds.
    export APP_PORT="$PORT"
    export APP_BIND="$HOST"
    cd "$REPO_DIR"

    # Job control gives the background job its own process group (pgid == pid),
    # so `kill -TERM -$pid` later reaches uvicorn and every child it spawned.
    # nohup detaches it from the terminal that started it.
    set -m
    if [ "$(uname -m)" = "arm64" ]; then
        nohup arch -arm64 "$UVICORN" app:app --host "$HOST" --port "$PORT" >>"$LOG" 2>&1 &
    else
        nohup "$UVICORN" app:app --host "$HOST" --port "$PORT" >>"$LOG" 2>&1 &
    fi
    local pid=$!
    set +m
    disown "$pid" 2>/dev/null || true
    write_state "$pid"

    # Catch an immediate crash (bad venv, port race) rather than reporting success.
    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "✗ Server exited immediately. Last lines of $LOG:"
        tail -n 15 "$LOG"
        rm -f "$STATE"
        exit 1
    fi
    echo "▶ Server started in the background (pid $pid)"
    echo "  URL: $URL"
    echo "  Log: $LOG"
    echo "  First run downloads an embedding model — it may take a minute to answer."
}

stop_server() {
    local pid stopped=0
    if pid="$(state_pid)"; then
        echo "▶ Stopping server (pid $pid)…"
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 40); do
            kill -0 "$pid" 2>/dev/null || { stopped=1; break; }
            sleep 0.2
        done
        if [ "$stopped" = "0" ]; then
            echo "  Escalating to SIGKILL."
            kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    # Sweep anything still holding the port (an orphan from an earlier session).
    if port_busy; then
        local strays
        strays="$(/usr/sbin/lsof -ti "tcp:$PORT" 2>/dev/null || true)"
        [ -n "$strays" ] && echo "  Clearing port $PORT…" && echo "$strays" | xargs kill 2>/dev/null || true
    fi
    rm -f "$STATE"
    echo "▶ Stopped."
}

print_status() {
    local pid
    if pid="$(state_pid)"; then
        if is_healthy; then echo "running   pid $pid   $URL"
        else                echo "starting  pid $pid   $URL"; fi
    elif is_healthy; then
        echo "running   (started outside this script)   $URL"
    else
        echo "stopped"
    fi
}

# ── Menu bar agent ───────────────────────────────────────────────────────────
build_agent() {
    local src stamp hash
    src="$(mktemp /tmp/odysseus_agent_XXXX.m)"
    cat > "$src" <<'OBJC'
#import <Cocoa/Cocoa.h>
#include <signal.h>

#ifndef ODY_SCRIPT
#define ODY_SCRIPT "/usr/bin/false"
#endif
#ifndef ODY_STATE
#define ODY_STATE "/tmp/odysseus-run.env"
#endif
#ifndef ODY_URL
#define ODY_URL "http://127.0.0.1:7860"
#endif

typedef NS_ENUM(NSInteger, OdyState) {
    OdyStopped = 0, OdyStarting, OdyRunning, OdyExternal, OdyBusy
};

@interface Agent : NSObject <NSApplicationDelegate>
@end

@implementation Agent {
    NSStatusItem *_item;
    NSMenuItem   *_line, *_open, *_logItem, *_start, *_restart, *_stop, *_stopQuit;
    NSTimer      *_timer;
    pid_t         _pid;
    NSString     *_url, *_log, *_busyText;
    OdyState      _state;
    BOOL          _healthy, _busy;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _url = @ODY_URL;
    _state = OdyStopped;
    [self buildMenu];
    [self readState];
    [self refresh];
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES
                                               block:^(NSTimer *t) { [weak tick]; }];
    [_timer fire];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)a { return YES; }

#pragma mark - state

/* The shell script owns the server; this file is the contract between them. */
- (void)readState {
    NSString *s = [NSString stringWithContentsOfFile:@ODY_STATE
                                            encoding:NSUTF8StringEncoding error:NULL];
    _pid = 0;
    if (!s) return;
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"\"' \t\r"];
    for (NSString *raw in [s componentsSeparatedByString:@"\n"]) {
        NSRange eq = [raw rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [raw substringToIndex:eq.location];
        NSString *v = [[raw substringFromIndex:eq.location + 1]
                       stringByTrimmingCharactersInSet:trim];
        if ([k isEqualToString:@"PID"])      _pid = (pid_t)v.intValue;
        else if ([k isEqualToString:@"URL"] && v.length) _url = v;
        else if ([k isEqualToString:@"LOG"] && v.length) _log = v;
    }
}

- (void)tick {
    if (_busy) return;
    [self readState];
    BOOL alive = (_pid > 0 && kill(_pid, 0) == 0);
    __weak typeof(self) weak = self;
    [self probe:^(BOOL ok) {
        typeof(self) me = weak; if (!me || me->_busy) return;
        me->_healthy = ok;
        if (alive && ok)       me->_state = OdyRunning;
        else if (alive)        me->_state = OdyStarting;
        else if (ok)           me->_state = OdyExternal;
        else                   me->_state = OdyStopped;
        [me refresh];
    }];
}

- (void)probe:(void (^)(BOOL))done {
    NSMutableURLRequest *r =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_url]
                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                           timeoutInterval:2.0];
    r.HTTPMethod = @"HEAD";
    [[[NSURLSession sharedSession] dataTaskWithRequest:r
        completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            /* Any HTTP reply counts — a 302 to /login still means it is up. */
            BOOL ok = (resp != nil && e == nil);
            dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
        }] resume];
}

#pragma mark - actions

- (void)runScript:(NSString *)arg saying:(NSString *)text then:(void (^)(void))after {
    if (_busy) return;
    _busy = YES; _busyText = text; _state = OdyBusy;
    [self refresh];

    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/bash";
    t.arguments = @[@ODY_SCRIPT, arg];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    __weak typeof(self) weak = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weak; if (!me) return;
            me->_busy = NO;
            [me tick];
            if (after) after();
        });
    };
    @try { [t launch]; }
    @catch (NSException *e) { _busy = NO; [self refresh]; }
}

- (void)openUI:(id)s      { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:_url]]; }
- (void)openLog:(id)s     { if (_log) [[NSWorkspace sharedWorkspace] openFile:_log withApplication:@"Console"]; }
- (void)startSrv:(id)s    { [self runScript:@"--server-only" saying:@"starting…" then:nil]; }
- (void)restartSrv:(id)s  { [self runScript:@"--restart" saying:@"restarting…" then:nil]; }
- (void)stopSrv:(id)s     { [self runScript:@"--stop" saying:@"stopping…" then:nil]; }

- (void)stopAndQuit:(id)s {
    [self runScript:@"--stop" saying:@"stopping…" then:^{ [NSApp terminate:nil]; }];
}

#pragma mark - menu

- (void)buildMenu {
    _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *m = [[NSMenu alloc] init];

    _line = [[NSMenuItem alloc] initWithTitle:@"Odysseus" action:nil keyEquivalent:@""];
    _line.enabled = NO;
    [m addItem:_line];
    [m addItem:[NSMenuItem separatorItem]];

    _open     = [self add:m title:@"Open Odysseus"   sel:@selector(openUI:)     key:@"o"];
    _logItem  = [self add:m title:@"View Log"        sel:@selector(openLog:)    key:@""];
    [m addItem:[NSMenuItem separatorItem]];
    _start    = [self add:m title:@"Start Server"    sel:@selector(startSrv:)   key:@""];
    _restart  = [self add:m title:@"Restart Server"  sel:@selector(restartSrv:) key:@"r"];
    _stop     = [self add:m title:@"Stop Server"     sel:@selector(stopSrv:)    key:@""];
    [m addItem:[NSMenuItem separatorItem]];
    _stopQuit = [self add:m title:@"Stop Server and Quit" sel:@selector(stopAndQuit:) key:@""];

    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"Quit Menu Bar (leave server running)"
                                               action:@selector(terminate:) keyEquivalent:@"q"];
    q.target = NSApp;
    [m addItem:q];

    _item.menu = m;
}

- (NSMenuItem *)add:(NSMenu *)m title:(NSString *)t sel:(SEL)s key:(NSString *)k {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:s keyEquivalent:k];
    i.target = self;
    [m addItem:i];
    return i;
}

- (void)refresh {
    NSColor *c; NSString *text;
    switch (_state) {
        case OdyRunning:  c = NSColor.systemGreenColor;  text = @"running";  break;
        case OdyStarting: c = NSColor.systemOrangeColor; text = @"starting…"; break;
        case OdyExternal: c = NSColor.systemBlueColor;   text = @"running (started elsewhere)"; break;
        case OdyBusy:     c = NSColor.systemOrangeColor; text = _busyText;   break;
        default:          c = NSColor.systemGrayColor;   text = @"stopped";  break;
    }
    _item.button.attributedTitle =
        [[NSAttributedString alloc] initWithString:@"\u25CF"
            attributes:@{NSForegroundColorAttributeName: c,
                         NSFontAttributeName: [NSFont systemFontOfSize:14]}];
    _line.title = [NSString stringWithFormat:@"Odysseus: %@", text];

    BOOL up = (_state == OdyRunning || _state == OdyStarting || _state == OdyExternal);
    _open.enabled     = up && !_busy;
    _logItem.enabled  = (_log != nil) && !_busy;
    _start.hidden     = up;
    _start.enabled    = !_busy;
    _restart.hidden   = !up;
    _restart.enabled  = !_busy;
    _stop.enabled     = up && !_busy;
    _stopQuit.enabled = up && !_busy;
}

@end

static Agent *gAgent;   /* NSApplication.delegate is weak */

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        gAgent = [Agent new];
        app.delegate = gAgent;
        [app run];
    }
    return 0;
}
OBJC

    hash="$(shasum -a 256 "$src" | cut -c1-16)-$PORT-$HOST"
    stamp="$AGENT/Contents/Resources/.build-hash"
    if [ -x "$AGENT/Contents/MacOS/OdysseusMenuBar" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$hash" ]; then
        rm -f "$src"
        return 0
    fi

    if ! xcrun --find clang >/dev/null 2>&1; then
        rm -f "$src"
        echo "  ⚠ Command Line Tools not installed — skipping the menu bar."
        echo "    Install them with:  xcode-select --install"
        return 1
    fi

    echo "▶ Building the menu bar agent…"
    rm -rf "$AGENT"
    mkdir -p "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources"

    # LSUIElement keeps it out of the Dock and ⌘-Tab; it lives only in the menu
    # bar. NSAllowsLocalNetworking lets the health poll reach 127.0.0.1 under ATS.
    cat > "$AGENT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>       <string>OdysseusMenuBar</string>
  <key>CFBundleIdentifier</key> <string>com.odysseus.menubar</string>
  <key>CFBundleExecutable</key> <string>OdysseusMenuBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key>    <string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key>        <true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

    local flags=(-fobjc-arc -O2 -framework Cocoa
                 "-DODY_SCRIPT=\"$SELF\"" "-DODY_STATE=\"$STATE\"" "-DODY_URL=\"$URL\"")
    if ! xcrun clang -arch arm64 -arch x86_64 "${flags[@]}" \
            -o "$AGENT/Contents/MacOS/OdysseusMenuBar" "$src" 2>/dev/null; then
        if ! xcrun clang -arch "$(uname -m)" "${flags[@]}" \
                -o "$AGENT/Contents/MacOS/OdysseusMenuBar" "$src" 2>/dev/null; then
            rm -f "$src"; rm -rf "$AGENT"
            echo "  ⚠ Agent failed to compile — continuing without the menu bar."
            return 1
        fi
    fi
    rm -f "$src"
    echo "$hash" > "$stamp"
    codesign --force --sign - "$AGENT" >/dev/null 2>&1 || true
    return 0
}

launch_agent() {
    build_agent || return 0
    # LSMultipleInstancesProhibited means this activates an existing agent
    # rather than starting a second one.
    /usr/bin/open "$AGENT"
    echo "▶ Menu bar monitor running (look for the ● near the clock)."
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$MODE" in
    status)
        print_status
        ;;
    stop)
        stop_server
        ;;
    restart)
        stop_server
        if [ "$DO_SETUP" = "1" ]; then ensure_setup; fi
        start_server
        ;;
    server-only)
        if [ "$DO_SETUP" = "1" ]; then ensure_setup; fi
        start_server
        ;;
    run)
        echo "▶ Odysseus for macOS"
        if [ "$DO_SETUP" = "1" ]; then ensure_setup; fi
        start_server
        launch_agent
        echo ""
        echo "The server keeps running after this terminal closes."
        echo "Stop it from the menu bar, or with:  $SELF --stop"
        ;;
esac

import Foundation
import iRecordCore

enum HelpSpec {
    static var capabilities: [String: Any] {
        [
            "ok": true,
            "tool": "irecord",
            "display_name": "iRecord",
            "version": AppInfo.version,
            "description": "Headless screen recorder for macOS. Records the full screen, a single window, or a rectangular region to MP4, MOV, ProRes or animated GIF, with optional system audio and microphone audio, cursor and mouse-click highlights, pause/resume, and background start/stop control.",
            "platform": ["os": "macOS", "minimum": "15.0", "architectures": ["arm64", "x86_64"]],
            "invocation": "irecord <command> [options]",
            "automation": [
                "Always pass --json to receive one machine-readable JSON object per command.",
                "Progress and human-readable messages are written to stderr and never pollute stdout.",
                "Run `irecord doctor --json` first to check permissions and readiness.",
                "Run `irecord targets --json` to discover display and window identifiers.",
                "Prefer `irecord record --duration N` for unattended tasks. A foreground `record` without --duration requires an interactive TTY and is rejected in automation. Use `irecord start` + `irecord stop` when the end time is not known in advance.",
                "Paths in output are absolute. Outputs are created in the configured folder when --output is omitted.",
                "Long recordings and GIF conversion can take time; give `irecord stop` a generous timeout (default 300 seconds).",
                "System audio for window capture is scoped to the captured application. Use screen or region mode to record all system audio.",
                "Microphone capture uses AVAudioEngine independently of ScreenCaptureKit. With --audio both, the file has a microphone audio track followed by a system-audio track.",
                "Use `--audio both` to mix system audio and microphone into one AAC track. GIF output is always silent."
            ],
            "permissions": [
                "screen_recording: required to capture content. Granted to the process that runs irecord (usually Terminal or the automation host).",
                "microphone: required when --audio microphone|both is used. The bundled copy inside iRecord.app carries the required usage description.",
                "No accessibility permission is required."
            ],
            "commands": commands,
            "record_options": options,
            "output_schema": [
                "success: {ok:true, output, format, duration, width, height, fileSize, audio, session?}",
                "failure: {ok:false, error, code, hint?}",
                "targets: {ok:true, displays:[...], windows:[...]}",
                "status: {ok:true, session, state, elapsed, outputPath, result?}"
            ],
            "exit_codes": [
                "0": "success",
                "1": "unexpected failure",
                "2": "invalid arguments",
                "3": "missing screen or microphone permission",
                "4": "capture target not found",
                "5": "output path not writable or already exists",
                "6": "operation timed out",
                "130": "cancelled (SIGINT)"
            ],
            "notes": [
                "Region coordinates are in display-local points with a top-left origin, formatted as x,y,width,height.",
                "Window identifiers are ephemeral. Resolve them immediately before recording, or use --app / --title instead of --window.",
                "GIF has no audio. When --format gif is selected, the video is recorded first and converted on stop.",
                "Pause and resume are supported by both foreground and background sessions.",
                "The GUI app and the CLI share ~/Library/Application Support/iRecord/settings.json.",
                "Screen recordings of windows may be affected by macOS ScreenCaptureKit rules (some protected windows cannot be captured)."
            ],
            "examples": [
                "irecord doctor --json",
                "irecord targets --json",
                "irecord record --mode screen --duration 8 --format mp4-h264 --output demo.mp4 --json",
                "irecord record --mode window --window 12345 --duration 5 --audio system --mouse-clicks --json",
                "irecord record --mode window --app Safari --title 'Example' --duration 10 --json",
                "irecord record --mode region --display 1 --region 100,200,800,600 --duration 6 --format gif --json",
                "irecord start --mode screen --audio both --output session.mp4 --json",
                "irecord pause --session <id> --json",
                "irecord resume --session <id> --json",
                "irecord status --session <id> --json",
                "irecord stop --session <id> --json"
            ]
        ]
    }

    static let options: [[String: Any]] = [
        option("--mode", "string", "screen | window | region. Default: screen.", "screen"),
        option("--display", "string", "Display identifier or `main` for full-screen and region capture.", "main"),
        option("--window", "integer", "Window identifier from `irecord targets`.", nil),
        option("--window-id", "integer", "Alias for --window.", nil),
        option("--app", "string", "Select the frontmost matching window by application name or bundle identifier (alternative to --window).", nil),
        option("--title", "string", "Substring filter for the window title, used with --app or alone.", nil),
        option("--region", "string", "Region as x,y,width,height in display-local points, top-left origin.", nil),
        option("--format", "string", "mp4-h264, mp4-hevc, mov-h264, mov-hevc, mov-prores, gif. Default: current GUI setting (mp4-h264).", "mp4-h264"),
        option("--fps", "integer", "Frame rate from 5 to 120. Default: 30.", "30"),
        option("--quality", "string", "low | medium | high. Default: high.", "high"),
        option("--scale", "number", "Capture scale from 0.25 to 1.0. Default: 1.0.", "1.0"),
        option("--audio", "string", "none | system | microphone | both. Default: system.", "system"),
        option("--no-audio", "flag", "Shortcut for --audio none.", nil),
        option("--cursor", "flag", "Include the mouse cursor (default).", "true"),
        option("--no-cursor", "flag", "Hide the mouse cursor.", nil),
        option("--mouse-clicks", "flag", "Draw a system highlight around mouse clicks and embed it in the video.", "true"),
        option("--no-mouse-clicks", "flag", "Disable mouse-click highlights.", nil),
        option("--gif-width", "integer", "Maximum GIF width in pixels. Default: 720.", "720"),
        option("--gif-fps", "integer", "GIF playback frame rate. Default: 12.", "12"),
        option("--output", "path", "Output file or directory. A missing extension is added automatically.", nil),
        option("--overwrite", "flag", "Replace an existing output file.", nil),
        option("--duration", "number", "Recording length in seconds. 0 or omitted records until SIGINT or `irecord stop`.", "0"),
        option("--session", "string", "Session identifier for pause, resume, stop and status.", nil),
        option("--json", "flag", "Emit a single JSON object on stdout.", nil),
        option("--quiet", "flag", "Suppress stderr progress messages.", nil),
        option("--verbose", "flag", "Print extra diagnostics on stderr.", nil),
        option("--help", "flag", "Show human-readable help for the command.", nil)
    ]

    private static func option(_ name: String, _ type: String, _ description: String, _ defaultValue: String?) -> [String: Any] {
        var result: [String: Any] = ["name": name, "type": type, "description": description]
        if let defaultValue { result["default"] = defaultValue }
        return result
    }

    static let commands: [[String: Any]] = [
        [
            "name": "help",
            "summary": "Print capability documentation. Use --json for the machine-readable contract.",
            "usage": "irecord help [--json] [command]"
        ],
        [
            "name": "doctor",
            "summary": "Check version, permissions, output folder, formats and any active session.",
            "usage": "irecord doctor [--json]"
        ],
        [
            "name": "targets",
            "summary": "List displays and capturable windows with stable-this-moment identifiers and geometry.",
            "usage": "irecord targets [--json] [--all] [--include-system]"
        ],
        [
            "name": "record",
            "summary": "Record synchronously. Returns after the file is written (and GIF conversion finished).",
            "usage": "irecord record [options] [--duration seconds]"
        ],
        [
            "name": "start",
            "summary": "Start a background recording session and return immediately with a session id.",
            "usage": "irecord start [options]"
        ],
        [
            "name": "pause",
            "summary": "Pause a background session. The paused duration is cut out of the final file.",
            "usage": "irecord pause [--session id] [--json]"
        ],
        [
            "name": "resume",
            "summary": "Resume a paused background session.",
            "usage": "irecord resume [--session id] [--json]"
        ],
        [
            "name": "stop",
            "summary": "Stop a background session, wait for finalization/conversion, and return the result.",
            "usage": "irecord stop [--session id] [--json] [--timeout seconds]"
        ],
        [
            "name": "status",
            "summary": "Report the state, elapsed time and output path of a session.",
            "usage": "irecord status [--session id] [--json]"
        ],
        [
            "name": "config",
            "summary": "Print the shared GUI/CLI settings and available output formats.",
            "usage": "irecord config [--json]"
        ],
        [
            "name": "version",
            "summary": "Print the version.",
            "usage": "irecord version [--json]"
        ]
    ]

    static func humanHelp(command: String? = nil) -> String {
        if let command {
            switch command {
            case "record", "start":
                return recordHelp(command: command)
            case "stop", "pause", "resume", "status":
                return """
                USAGE
                  irecord \(command) [--session <id>] [--json]

                Stops/pauses/resumes/reports a background session started with `irecord start`.
                If --session is omitted, the most recent active session is used.
                """
            default:
                break
            }
        }
        return """
        iRecord \(AppInfo.version) — headless screen recorder for macOS

        USAGE
          irecord <command> [options]

        COMMANDS
          help [--json] [command]      Capability documentation (JSON contract for LLMs)
          doctor [--json]              Check permissions, paths and readiness
          targets [--json]             List displays and windows
          record [options]             Record in the foreground
          start [options]              Start a background session
          pause | resume | stop        Control a background session
          status [--json]              Show session state
          config [--json]              Show shared settings
          version                      Print version

        QUICK START
          irecord doctor --json
          irecord targets --json
          irecord record --mode screen --duration 10 --output demo.mp4 --json
          irecord record --mode window --app Safari --duration 5 --audio both --json
          irecord record --mode region --display 1 --region 100,200,800,600 --format gif --json

        BACKGROUND CONTROL
          irecord start --mode screen --output demo.mp4 --json
          irecord pause --session <id> --json
          irecord resume --session <id> --json
          irecord stop --session <id> --json

        FOR LLM AGENTS
          Run `irecord help --json` and read the `commands`, `record_options`,
          `output_schema` and `exit_codes` keys. Always pass --json; stdout then
          contains exactly one JSON object and all progress goes to stderr.

        PERMISSIONS
          Screen Recording must be enabled for the invoking process (Terminal,
          IDE, or automation host) in System Settings → Privacy & Security.
          Microphone permission is only needed for --audio microphone|both.

        FORMATS
          mp4-h264, mp4-hevc, mov-h264, mov-hevc, mov-prores, gif
        """
    }

    static func recordHelp(command: String) -> String {
        """
        USAGE
          irecord \(command) [options]

        TARGET
          --mode screen|window|region     Default: screen
          --display <id|main>             Display for screen/region capture
          --window <id>                   Window id from `irecord targets`
          --app <name|bundle-id>          Match a window by application
          --title <substring>             Match a window by title
          --region x,y,w,h                Display-local points, top-left origin

        OUTPUT
          --format mp4-h264|mp4-hevc|mov-h264|mov-hevc|mov-prores|gif
          --fps <5-120>                   Default: 30
          --quality low|medium|high       Default: high
          --scale <0.25-1.0>              Default: 1.0
          --output <file|dir>             Default: configured recordings folder
          --overwrite                     Replace an existing file
          --gif-width <px>                Default: 720
          --gif-fps <fps>                 Default: 12

        AUDIO & MOUSE
          --audio none|system|microphone|both   Default: system
          --no-audio
          --cursor | --no-cursor
          --mouse-clicks | --no-mouse-clicks

        AUTOMATION
          --duration <seconds>            \(command == "start" ? "Optional; empty means until `irecord stop`" : "0 or omitted records until SIGINT")
          --json                          Single JSON object on stdout
          --quiet
          --verbose

        EXAMPLES
          irecord \(command) --mode screen --duration 8 --output demo.mp4 --json
          irecord \(command) --mode window --app Safari --duration 5 --audio both --json
          irecord \(command) --mode region --display 1 --region 100,200,800,600 --format gif --json
        """
    }
}

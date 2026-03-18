// bash-split: parse a bash command string and emit one permission key per
// simple command, in the format Bash(argv0 argv1:*) or Bash(argv0:*).
//
// Interface:
//   echo 'cmd' | bash-split        → one key per line, exit 0
//   bash-split --test              → run self-tests, exit 0/1
//
// The output replaces the two bash functions in ralph-permission-prompt.sh:
//   split_compound_command        (splitting)
//   permission_key_for_single_command  (key formatting)
//
// Build: go build -o bash-split .
// Requires: go get mvdan.cc/sh/v3

package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// ---------------------------------------------------------------------------
// Key formatting — mirrors the bash hook's permission_key_for_single_command
// ---------------------------------------------------------------------------

// effectiveArgv returns the logical (argv0, argv1) of a simple command,
// unwrapping common transparent prefixes like env, sudo, time, nice, etc.
func effectiveArgv(args []string) (string, string) {
	transparentPrefixes := map[string]bool{
		"env": true, "sudo": true, "time": true, "nice": true,
		"nohup": true, "xargs": true, "exec": true, "builtin": true,
		"command": true, "doas": true,
	}

	// Walk past transparent prefixes and their flags/env-var assignments
	i := 0
	for i < len(args) {
		word := args[i]
		// env VAR=value or any VAR= style assignment
		if strings.Contains(word, "=") {
			i++
			continue
		}
		// flags on transparent commands (e.g. sudo -u root)
		if strings.HasPrefix(word, "-") {
			i++
			// consume the flag's argument if it takes one (heuristic: next word doesn't start with -)
			if i < len(args) && !strings.HasPrefix(args[i], "-") && !strings.Contains(args[i], "=") {
				// could be flag value — peek: if word is a known value-taking flag, skip
				// for simplicity, only skip one token for -u/-E/-H/-n/-P etc.
				i++
			}
			continue
		}
		if transparentPrefixes[word] {
			i++
			continue
		}
		break
	}

	if i >= len(args) {
		if len(args) == 0 {
			return "", ""
		}
		return args[0], ""
	}

	argv0 := args[i]
	argv1 := ""
	if i+1 < len(args) {
		argv1 = args[i+1]
	}

	// Git: skip global flags to find the real subcommand
	// e.g. git -C /path status  →  argv1 = "status"
	// e.g. git --no-pager log   →  argv1 = "log"
	if argv0 == "git" {
		gitValueFlags := map[string]bool{
			"-C": true, "-c": true, "--git-dir": true,
			"--work-tree": true, "--namespace": true,
		}
		j := i + 1
		for j < len(args) {
			w := args[j]
			if gitValueFlags[w] {
				j += 2 // skip flag + its value argument
				continue
			}
			if strings.HasPrefix(w, "-") {
				j++ // bare flag, skip one token
				continue
			}
			break
		}
		if j < len(args) {
			argv1 = args[j]
		} else {
			argv1 = ""
		}
	}

	return argv0, argv1
}

func formatKey(argv0, argv1 string) string {
	argv0 = strings.TrimSpace(argv0)
	argv1 = strings.TrimSpace(argv1)
	if argv0 == "" {
		return ""
	}
	// Strip any leading path components (e.g. /usr/bin/git → git)
	// but only for the key, to match how the bash hook stores permissions.
	// Actually: keep the full token so that ./script and script stay distinct.
	if argv1 != "" {
		return fmt.Sprintf("Bash(%s %s:*)", argv0, argv1)
	}
	return fmt.Sprintf("Bash(%s:*)", argv0)
}

// ---------------------------------------------------------------------------
// AST walking — collect one key per simple command in execution order
// ---------------------------------------------------------------------------

// wordLiteral extracts the best-effort literal string from a syntax.Word.
// For dynamic content (expansions, substitutions) we return the raw source
// text so we always produce something printable.
func wordLiteral(w *syntax.Word) string {
	if w == nil {
		return ""
	}
	var sb strings.Builder
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			sb.WriteString(p.Value)
		case *syntax.SglQuoted:
			sb.WriteString(p.Value)
		case *syntax.DblQuoted:
			// recurse into double-quoted parts
			for _, inner := range p.Parts {
				if lit, ok := inner.(*syntax.Lit); ok {
					sb.WriteString(lit.Value)
				} else {
					// dynamic content inside quotes — use placeholder
					sb.WriteString("*")
				}
			}
		case *syntax.ProcSubst:
			// Process substitution <(...) or >(...) — use the operator as a recognizable token
			sb.WriteString(p.Op.String())
		default:
			// CmdSubst, ParamExp, ArithmExp, etc. — treat as wildcard token
			sb.WriteString("*")
		}
	}
	return sb.String()
}

// collectKeys walks a syntax.Node and appends one permission key per simple
// command found (in syntactic order, depth-first).
func collectKeys(node syntax.Node, keys *[]string) {
	if node == nil {
		return
	}

	var currentStmt *syntax.Stmt
	syntax.Walk(node, func(n syntax.Node) bool {
		if n == nil {
			return false
		}

		// Track the innermost Stmt so we can inspect its redirections
		// when we encounter the associated CallExpr.
		if s, ok := n.(*syntax.Stmt); ok {
			currentStmt = s
			return true
		}

		callExpr, ok := n.(*syntax.CallExpr)
		if !ok {
			return true
		}

		// Collect positional words (skip assignments)
		var args []string
		for _, w := range callExpr.Args {
			args = append(args, wordLiteral(w))
		}

		argv0, argv1 := effectiveArgv(args)

		// If argv1 is still empty, check for a heredoc redirect on the parent
		// Stmt and use its operator as argv1 (e.g. <<EOF).
		if argv1 == "" && currentStmt != nil {
			for _, r := range currentStmt.Redirs {
				op := r.Op.String()
				if strings.HasPrefix(op, "<<") {
					argv1 = op + wordLiteral(r.Word)
					break
				}
			}
		}

		// find -exec/-execdir: surface the executed command instead of find itself
		// find with -delete/-ok/-okdir: keep as find (unsafe)
		// find with no side-effect flags: surface as find__safe (safe, read-only)
		var key string
		if argv0 == "find" {
			unsafeFindFlags := map[string]bool{
				"-exec": true, "-execdir": true,
				"-delete": true, "-ok": true, "-okdir": true,
			}
			foundExec := false
			foundUnsafe := false
			for idx := 0; idx < len(args); idx++ {
				flag := args[idx]
				if flag == "-exec" || flag == "-execdir" {
					foundExec = true
					var execArgs []string
					for k := idx + 1; k < len(args); k++ {
						w := args[k]
						if w == "{}" || w == ";" || w == `\;` || w == "+" {
							break
						}
						execArgs = append(execArgs, w)
					}
					if len(execArgs) > 0 {
						ea0, ea1 := effectiveArgv(execArgs)
						key = formatKey(ea0, ea1)
					}
					break // only handle first -exec
				}
				if unsafeFindFlags[flag] {
					foundUnsafe = true
				}
			}
			if !foundExec && !foundUnsafe {
				// Safe, read-only find — emit find__safe
				key = formatKey("find__safe", argv1)
			}
		}
		if key == "" {
			key = formatKey(argv0, argv1)
		}
		if key != "" {
			*keys = append(*keys, key)
		}

		// Don't recurse into this CallExpr's own args — they're not sub-commands.
		// But do let the walker recurse into child nodes (e.g. command substitutions).
		return true
	})
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

func parseAndEmitKeys(src string, w io.Writer) error {
	r := strings.NewReader(src)
	f, err := syntax.NewParser(syntax.KeepComments(false)).Parse(r, "")
	if err != nil {
		// Parse error — fall back to emitting a single key from the raw first tokens
		return fmt.Errorf("parse error: %w", err)
	}

	var keys []string
	collectKeys(f, &keys)

	// Deduplicate while preserving order
	seen := make(map[string]bool)
	bw := bufio.NewWriter(w)
	for _, k := range keys {
		if !seen[k] {
			seen[k] = true
			fmt.Fprintln(bw, k)
		}
	}
	return bw.Flush()
}

// fallbackKey produces a best-effort key from raw text when parsing fails,
// mirroring the original bash logic so behaviour degrades gracefully.
func fallbackKey(src string) string {
	src = strings.TrimSpace(src)
	// Collapse line continuations
	src = strings.ReplaceAll(src, "\\\n", " ")
	fields := strings.Fields(src)
	if len(fields) == 0 {
		return ""
	}
	if len(fields) == 1 {
		return fmt.Sprintf("Bash(%s:*)", fields[0])
	}
	return fmt.Sprintf("Bash(%s %s:*)", fields[0], fields[1])
}

// ---------------------------------------------------------------------------
// Self-tests
// ---------------------------------------------------------------------------

type testCase struct {
	input    string
	expected []string // all expected keys must appear in output (order-insensitive)
}

var tests = []testCase{
	{
		"echo hello",
		[]string{"Bash(echo hello:*)"},
	},
	{
		"git status",
		[]string{"Bash(git status:*)"},
	},
	{
		"cargo build && cargo test",
		[]string{"Bash(cargo build:*)", "Bash(cargo test:*)"},
	},
	{
		"npm install || npm ci",
		[]string{"Bash(npm install:*)", "Bash(npm ci:*)"},
	},
	{
		"cd /tmp; rm -rf foo",
		[]string{"Bash(cd /tmp:*)", "Bash(rm -rf:*)"},
	},
	{
		"cat file.txt | grep pattern | sort",
		[]string{"Bash(cat file.txt:*)", "Bash(grep pattern:*)", "Bash(sort:*)"},
	},
	{
		"sudo apt-get install -y curl",
		[]string{"Bash(apt-get install:*)"},
	},
	{
		"env NODE_ENV=production node server.js",
		[]string{"Bash(node server.js:*)"},
	},
	{
		`if [ -f foo ]; then echo yes; fi`,
		[]string{"Bash([ -f:*)", "Bash(echo yes:*)"},
	},
	{
		`for f in *.go; do gofmt -w "$f"; done`,
		[]string{"Bash(gofmt -w:*)"},
	},
	{
		"git commit -m \"fix: $(date)\"",
		[]string{"Bash(git commit:*)"},
	},
	{
		// here-doc shouldn't confuse the parser
		"cat <<EOF\nhello\nEOF",
		[]string{"Bash(cat <<EOF:*)"},
	},
	{
		// nested subshell
		"result=$(git rev-parse HEAD)",
		[]string{"Bash(git rev-parse:*)"},
	},
	{
		// process substitution
		"diff <(sort a.txt) <(sort b.txt)",
		[]string{"Bash(diff <(:*)", "Bash(sort a.txt:*)", "Bash(sort b.txt:*)"},
	},
	// git -C <path> flag unwrapping
	{
		"git -C /path status",
		[]string{"Bash(git status:*)"},
	},
	{
		"git -c user.name=foo commit -m 'msg'",
		[]string{"Bash(git commit:*)"},
	},
	{
		"git --no-pager log",
		[]string{"Bash(git log:*)"},
	},
	{
		"git --git-dir /foo --work-tree /bar status",
		[]string{"Bash(git status:*)"},
	},
	// find -exec subcommand surfacing
	{
		`find . -name "*.ts" -exec rm -rf {} \;`,
		[]string{"Bash(rm -rf:*)"},
	},
	{
		`find /tmp -type f -execdir chmod 644 {} +`,
		[]string{"Bash(chmod 644:*)"},
	},
	{
		// no -exec and no unsafe flags: surface as find__safe
		`find . -name "*.log"`,
		[]string{"Bash(find__safe .:*)"},
	},
	{
		// -delete is unsafe: keep as find
		`find . -name "*.tmp" -delete`,
		[]string{"Bash(find .:*)"},
	},
	{
		// -ok is unsafe: keep as find
		`find . -type f -ok rm {} \;`,
		[]string{"Bash(find .:*)"},
	},
}

func runTests() bool {
	passed, failed := 0, 0
	for _, tc := range tests {
		var sb strings.Builder
		err := parseAndEmitKeys(tc.input, &sb)
		output := sb.String()
		lines := strings.Split(strings.TrimSpace(output), "\n")
		lineSet := make(map[string]bool)
		for _, l := range lines {
			lineSet[strings.TrimSpace(l)] = true
		}

		ok := true
		if err != nil {
			fmt.Printf("FAIL [parse error] %q\n  error: %v\n", tc.input, err)
			ok = false
		}
		for _, exp := range tc.expected {
			if !lineSet[exp] {
				if ok {
					fmt.Printf("FAIL %q\n  output: %s\n", tc.input, strings.TrimSpace(output))
				}
				fmt.Printf("  missing: %q\n", exp)
				ok = false
			}
		}
		if ok {
			fmt.Printf("PASS %q\n", tc.input)
			passed++
		} else {
			failed++
		}
	}
	fmt.Printf("\n%d passed, %d failed\n", passed, failed)
	return failed == 0
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--test" {
		if !runTests() {
			os.Exit(1)
		}
		return
	}

	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "bash-split: read error: %v\n", err)
		os.Exit(1)
	}

	command := strings.TrimSpace(string(src))
	if command == "" {
		os.Exit(0)
	}

	if err := parseAndEmitKeys(command, os.Stdout); err != nil {
		// Parse failed — degrade gracefully with the original heuristic
		fmt.Fprintf(os.Stderr, "bash-split: %v (using fallback)\n", err)
		key := fallbackKey(command)
		if key != "" {
			fmt.Println(key)
		}
		// exit 0 so the hook can still function
	}

}

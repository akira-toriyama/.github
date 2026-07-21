// Command bitescan reports the top-level test functions of a Go test file, their
// line spans, and whether they carry a `bite-exempt:` opt-out — the three facts
// go-bite.sh needs and the three that a regex over source cannot get right.
//
// A textual scan ("a top-level func ends at the first `}` in column 0") is wrong
// for a `}` inside a raw string literal or a comment, for generic type-parameter
// lists, and for a file that is not gofmt'd. go/ast is exact, and `go` is already
// on the runner in the Go CI job that calls this. It imports only the standard
// library, so it builds with `go build -o bitescan bitescan.go` from any directory,
// inside a module or not.
//
// Usage:
//
//	bitescan FILE...
//
// Output: one TSV record per test function, in source order, per file:
//
//	FILE \t NAME \t STARTLINE \t ENDLINE \t EXEMPT \t RUNNABLE
//
// EXEMPT is `-` when the function has no opt-out, or the (non-empty) reason text
// following `bite-exempt:` in the function's doc comment. A `bite-exempt:` with no
// reason is a hard error (exit 2): the annotation costs an explanation, otherwise
// it becomes a reflex.
//
// RUNNABLE is `run`, or `norun` for an example with no output comment — `go test`
// compiles those without ever running them, so their PASS means nothing. They are
// still reported: the caller needs their line spans to tell "changed inside a test"
// from "changed inside a helper", and a dropped record would read as the latter.
//
// Exit: 0 ok (including a file with no test functions), 2 parse error or an
// unexplained opt-out.
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"regexp"
	"strings"
)

// exemptMarker opts a test function out of the gate. It is deliberately spelled
// out in full here so `grep -r bite-exempt` finds both ends of the contract.
const exemptMarker = "bite-exempt:"

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: bitescan FILE...")
		os.Exit(2)
	}
	var out strings.Builder
	rc := 0
	for _, path := range os.Args[1:] {
		if err := scan(path, &out); err != nil {
			fmt.Fprintf(os.Stderr, "bitescan: %v\n", err)
			rc = 2
		}
	}
	// Print whatever was scanned even on failure: the caller reports the error and
	// a partial record set is still more informative than none.
	fmt.Print(out.String())
	os.Exit(rc)
}

func scan(path string, out *strings.Builder) error {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
	if err != nil {
		return err
	}
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		// A method cannot be a test: `go test` only ever calls package-level funcs.
		if !ok || fn.Recv != nil || !isTestFunc(fn.Name.Name) {
			continue
		}
		runnable := "run"
		if strings.HasPrefix(fn.Name.Name, "Example") && !hasOutputComment(file, fn) {
			runnable = "norun"
			fmt.Fprintf(os.Stderr, "::notice::go-bite: %s: %s has no output comment, so `go test` compiles it without running it — not judged\n", path, fn.Name.Name)
		}
		exempt, err := exemption(fn, path)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "%s\t%s\t%d\t%d\t%s\t%s\n",
			path, fn.Name.Name,
			fset.Position(fn.Pos()).Line, fset.Position(fn.End()).Line,
			exempt, runnable)
	}
	return nil
}

// isTestFunc reports whether name is a name `go test` treats as a test entry
// point. TestMain is excluded: it is the harness, not an assertion, and selecting
// it would run the whole package. Benchmarks are excluded because they assert
// nothing. Fuzz targets are included — `go test -run` runs their seed corpus,
// which is exactly the regression pin a fuzz fix adds.
func isTestFunc(name string) bool {
	switch {
	case name == "TestMain":
		return false
	case strings.HasPrefix(name, "Test"),
		strings.HasPrefix(name, "Fuzz"),
		strings.HasPrefix(name, "Example"):
		return true
	}
	return false
}

// outputComment is go/doc's rule for a runnable example: the LAST comment in the
// function body, optionally "unordered", introducing the expected output.
var outputComment = regexp.MustCompile(`(?i)^[[:space:]]*(unordered )?output:`)

// hasOutputComment reports whether fn ends in an output comment, i.e. whether
// `go test` will actually run it.
func hasOutputComment(file *ast.File, fn *ast.FuncDecl) bool {
	if fn.Body == nil {
		return false
	}
	var last *ast.CommentGroup
	for _, cg := range file.Comments {
		if cg.Pos() >= fn.Body.Lbrace && cg.End() <= fn.Body.Rbrace {
			last = cg
		}
	}
	return last != nil && outputComment.MatchString(last.Text())
}

// exemption returns the reason text of a `bite-exempt:` opt-out in fn's doc
// comment, or "-" when there is none. Only the doc comment counts: a marker in an
// arbitrary comment inside the body would let an opt-out hide anywhere.
func exemption(fn *ast.FuncDecl, path string) (string, error) {
	if fn.Doc == nil {
		return "-", nil
	}
	for _, c := range fn.Doc.List {
		i := strings.Index(c.Text, exemptMarker)
		if i < 0 {
			continue
		}
		reason := strings.TrimSpace(c.Text[i+len(exemptMarker):])
		// Trim a block comment's terminator so `/* bite-exempt: why */` reads the
		// same as the line form.
		reason = strings.TrimSpace(strings.TrimSuffix(reason, "*/"))
		if reason == "" {
			return "", fmt.Errorf("%s: %s carries `%s` with no reason — state what the test pins instead of a fix", path, fn.Name.Name, exemptMarker)
		}
		// The record is TSV; a tab in the reason would forge a field.
		return strings.Join(strings.Fields(reason), " "), nil
	}
	return "-", nil
}

package main

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"strings"
	"testing"
)

// exports returns "name: signature" for every //export function of a cabi main.go.
func exports(t *testing.T, path string) map[string]string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, d := range f.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Doc == nil || !hasExport(fd) {
			continue
		}
		var b bytes.Buffer
		ft := *fd.Type
		// compare types only, not parameter names
		_ = printer.Fprint(&b, fset, typesOnly(&ft))
		out[fd.Name.Name] = b.String()
	}
	return out
}

func hasExport(fd *ast.FuncDecl) bool {
	for _, c := range fd.Doc.List {
		if strings.HasPrefix(c.Text, "//export "+fd.Name.Name) {
			return true
		}
	}
	return false
}

func typesOnly(ft *ast.FuncType) *ast.FuncType {
	strip := func(fl *ast.FieldList) *ast.FieldList {
		if fl == nil {
			return nil
		}
		n := &ast.FieldList{}
		for _, f := range fl.List {
			count := len(f.Names)
			if count == 0 {
				count = 1
			}
			for i := 0; i < count; i++ {
				n.List = append(n.List, &ast.Field{Type: f.Type})
			}
		}
		return n
	}
	return &ast.FuncType{Params: strip(ft.Params), Results: strip(ft.Results)}
}

// TestSameABIShapeAsXrayBridge keeps the exported C functions of both bridges identical in name and
// signature, so that the Swift side can share one adapter over the C ABI.
func TestSameABIShapeAsXrayBridge(t *testing.T) {
	const xrayABI = "../../Bridge/cabi/main.go"
	if _, err := os.Stat(xrayABI); err != nil {
		t.Skipf("Xray bridge sources not present: %v", err)
	}
	mine, theirs := exports(t, "main.go"), exports(t, xrayABI)
	if len(theirs) == 0 {
		t.Fatal("no exports found in the Xray bridge")
	}
	for name, sig := range theirs {
		if got, ok := mine[name]; !ok {
			t.Errorf("missing export %s%s", name, sig)
		} else if got != sig {
			t.Errorf("%s: signature %s, Xray bridge has %s", name, got, sig)
		}
	}
	for name := range mine {
		if _, ok := theirs[name]; !ok {
			t.Errorf("extra export %s not in the Xray bridge", name)
		}
	}
	t.Logf("%d exported functions match", len(mine))
}

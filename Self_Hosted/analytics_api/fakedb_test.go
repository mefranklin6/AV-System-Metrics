package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
)

// fakeCall records one statement sent through the fake database/sql driver.
type fakeCall struct {
	query      string
	args       []any
	inTx       bool
	txReadOnly bool
}

// fakeResult is what the responder returns for a statement.
type fakeResult struct {
	cols []string
	rows [][]driver.Value
	err  error
}

// fakeDB is an in-memory database/sql driver that records statements and
// answers them through a responder, so SQL flows can be tested without
// PostgreSQL.
type fakeDB struct {
	mu        sync.Mutex
	calls     []fakeCall
	respond   func(fakeCall) fakeResult
	pingErr   error
	beginErr  error
	txOptions []driver.TxOptions
}

func newFakeDB(t *testing.T, respond func(fakeCall) fakeResult) (*sql.DB, *fakeDB) {
	t.Helper()
	f := &fakeDB{respond: respond}
	db := sql.OpenDB(fakeConnector{f})
	t.Cleanup(func() { _ = db.Close() })
	return db, f
}

func (f *fakeDB) record(c fakeCall) fakeResult {
	f.mu.Lock()
	f.calls = append(f.calls, c)
	respond := f.respond
	f.mu.Unlock()
	if respond == nil {
		return fakeResult{}
	}
	return respond(c)
}

func (f *fakeDB) recorded() []fakeCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeCall(nil), f.calls...)
}

type fakeConnector struct{ f *fakeDB }

func (c fakeConnector) Connect(context.Context) (driver.Conn, error) { return &fakeConn{f: c.f}, nil }
func (c fakeConnector) Driver() driver.Driver                        { return fakeDriver{} }

type fakeDriver struct{}

func (fakeDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use the connector") }

type fakeConn struct {
	f          *fakeDB
	inTx       bool
	txReadOnly bool
}

func (c *fakeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("fake driver does not prepare statements")
}
func (c *fakeConn) Close() error { return nil }
func (c *fakeConn) Begin() (driver.Tx, error) {
	return c.BeginTx(context.Background(), driver.TxOptions{})
}

func (c *fakeConn) BeginTx(_ context.Context, opts driver.TxOptions) (driver.Tx, error) {
	c.f.mu.Lock()
	err := c.f.beginErr
	c.f.txOptions = append(c.f.txOptions, opts)
	c.f.mu.Unlock()
	if err != nil {
		return nil, err
	}
	c.inTx, c.txReadOnly = true, opts.ReadOnly
	c.f.record(fakeCall{query: "BEGIN", inTx: true, txReadOnly: opts.ReadOnly})
	return &fakeTx{c: c}, nil
}

func (c *fakeConn) Ping(context.Context) error {
	c.f.mu.Lock()
	defer c.f.mu.Unlock()
	return c.f.pingErr
}

func (c *fakeConn) CheckNamedValue(*driver.NamedValue) error { return nil }

func namedArgs(args []driver.NamedValue) []any {
	out := make([]any, len(args))
	for i, a := range args {
		out[i] = a.Value
	}
	return out
}

func (c *fakeConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	res := c.f.record(fakeCall{query: query, args: namedArgs(args), inTx: c.inTx, txReadOnly: c.txReadOnly})
	if res.err != nil {
		return nil, res.err
	}
	return driver.RowsAffected(0), nil
}

func (c *fakeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	res := c.f.record(fakeCall{query: query, args: namedArgs(args), inTx: c.inTx, txReadOnly: c.txReadOnly})
	if res.err != nil {
		return nil, res.err
	}
	cols := res.cols
	if cols == nil && len(res.rows) > 0 {
		cols = make([]string, len(res.rows[0]))
		for i := range cols {
			cols[i] = "c"
		}
	}
	return &fakeRows{cols: cols, rows: res.rows}, nil
}

type fakeTx struct{ c *fakeConn }

func (t *fakeTx) Commit() error {
	t.c.f.record(fakeCall{query: "COMMIT", inTx: true, txReadOnly: t.c.txReadOnly})
	t.c.inTx = false
	return nil
}

func (t *fakeTx) Rollback() error {
	t.c.f.record(fakeCall{query: "ROLLBACK", inTx: true, txReadOnly: t.c.txReadOnly})
	t.c.inTx = false
	return nil
}

type fakeRows struct {
	cols []string
	rows [][]driver.Value
	pos  int
}

func (r *fakeRows) Columns() []string { return r.cols }
func (r *fakeRows) Close() error      { return nil }
func (r *fakeRows) Next(dest []driver.Value) error {
	if r.pos >= len(r.rows) {
		return io.EOF
	}
	copy(dest, r.rows[r.pos])
	r.pos++
	return nil
}

// one returns a single-row result.
func one(values ...driver.Value) fakeResult {
	cols := make([]string, len(values))
	for i := range cols {
		cols[i] = "c"
	}
	return fakeResult{cols: cols, rows: [][]driver.Value{values}}
}

// noRows returns an empty result with n columns.
func noRows(n int) fakeResult {
	cols := make([]string, n)
	for i := range cols {
		cols[i] = "c"
	}
	return fakeResult{cols: cols}
}

func containsQuery(calls []fakeCall, fragment string) bool {
	for _, c := range calls {
		if strings.Contains(c.query, fragment) {
			return true
		}
	}
	return false
}

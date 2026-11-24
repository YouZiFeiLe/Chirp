// sqlite-fixture is a disposable container-test helper. It is never copied into
// application images and provides no HTTP or production administration route.
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	_ "modernc.org/sqlite"
)

func main() {
	query := flag.Bool("query", false, "print rows from the supplied SQL")
	hold := flag.Duration("hold", 0, "hold a write transaction for a contention test")
	flag.Parse()
	if err := run(*query, *hold); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(query bool, hold time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := sql.Open("sqlite", "file:/data/chirp.db?_pragma=busy_timeout(10000)&_pragma=foreign_keys(ON)&_pragma=synchronous(FULL)&_txlock=immediate")
	if err != nil {
		return err
	}
	defer db.Close()
	if hold > 0 {
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		fmt.Println("locked")
		time.Sleep(hold)
		return nil
	}
	statement, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		return err
	}
	if !query {
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err := tx.ExecContext(ctx, string(statement)); err != nil {
			return err
		}
		return tx.Commit()
	}
	rows, err := db.QueryContext(ctx, string(statement))
	if err != nil {
		return err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return err
	}
	values, targets := make([]any, len(columns)), make([]any, len(columns))
	for i := range values {
		targets[i] = &values[i]
	}
	for rows.Next() {
		if err := rows.Scan(targets...); err != nil {
			return err
		}
		for i, value := range values {
			if i > 0 {
				fmt.Print("\t")
			}
			fmt.Print(value)
		}
		fmt.Println()
	}
	return rows.Err()
}

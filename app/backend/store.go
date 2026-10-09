package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

// checkTimeout bounds every dependency call made on behalf of a probe, so a
// hung database makes the probe fail fast rather than hang with it.
const checkTimeout = 2 * time.Second

type message struct {
	ID        int64     `json:"id"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"created_at"`
}

type store struct {
	pg     *pgxpool.Pool
	mongo  *mongo.Client
	valkey *redis.Client
	// schemaReady flips once the messages table exists.
	schemaReady atomic.Bool
}

// newStore builds the three clients from environment variables. All three
// connect lazily, so the process starts even if a database is down; readiness
// then reports "not ready" instead of the pod crash-looping.
func newStore(ctx context.Context) (*store, error) {
	pg, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return nil, fmt.Errorf("postgres config: %w", err)
	}
	mc, err := mongo.Connect(options.Client().ApplyURI(os.Getenv("MONGODB_URI")))
	if err != nil {
		return nil, fmt.Errorf("mongodb config: %w", err)
	}
	vk := redis.NewClient(&redis.Options{
		Addr:     os.Getenv("VALKEY_ADDR"),
		Password: os.Getenv("VALKEY_PASSWORD"),
	})

	s := &store{pg: pg, mongo: mc, valkey: vk}
	go s.migrate(ctx)
	return s, nil
}

// migrate creates the schema, retrying until PostgreSQL is reachable.
// IF NOT EXISTS makes it safe for several replicas to run at once.
func (s *store) migrate(ctx context.Context) {
	const ddl = `CREATE TABLE IF NOT EXISTS messages (
		id         BIGSERIAL PRIMARY KEY,
		text       TEXT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`
	for {
		if _, err := s.pg.Exec(ctx, ddl); err == nil {
			s.schemaReady.Store(true)
			log.Print("schema ready")
			return
		} else {
			log.Printf("schema not ready, retrying: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
}

// check pings each dependency and returns "ok" or the reason it is not.
func (s *store) check(ctx context.Context) map[string]string {
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()

	result := map[string]string{"postgres": "ok", "mongodb": "ok", "valkey": "ok"}
	if !s.schemaReady.Load() {
		result["postgres"] = "schema not ready"
	} else if err := s.pg.Ping(ctx); err != nil {
		result["postgres"] = "unreachable"
	}
	if err := s.mongo.Ping(ctx, nil); err != nil {
		result["mongodb"] = "unreachable"
	}
	if err := s.valkey.Ping(ctx).Err(); err != nil {
		result["valkey"] = "unreachable"
	}

	for name, state := range result {
		up := 0.0
		if state == "ok" {
			up = 1
		}
		dependencyUp.WithLabelValues(name).Set(up)
	}
	return result
}

// counters reads one number from each database. A failed read is reported as
// -1 so the status page still renders when one dependency is down.
func (s *store) counters(ctx context.Context) map[string]int64 {
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()

	out := map[string]int64{"messages": -1, "audit_events": -1, "visits": -1}
	var n int64
	if err := s.pg.QueryRow(ctx, "SELECT count(*) FROM messages").Scan(&n); err == nil {
		out["messages"] = n
	}
	if n, err := s.events().CountDocuments(ctx, bson.D{}); err == nil {
		out["audit_events"] = n
	}
	// INCR is atomic in Valkey, so concurrent replicas never lose an update.
	if n, err := s.valkey.Incr(ctx, "visits").Result(); err == nil {
		out["visits"] = n
	}
	return out
}

func (s *store) listMessages(ctx context.Context) ([]message, error) {
	rows, err := s.pg.Query(ctx, "SELECT id, text, created_at FROM messages ORDER BY id DESC LIMIT 20")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	msgs := []message{}
	for rows.Next() {
		var m message
		if err := rows.Scan(&m.ID, &m.Text, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

// createMessage writes the message to PostgreSQL, then records an audit event
// in MongoDB. The audit write is best-effort: PostgreSQL is the source of
// truth, and losing an audit entry must not fail the user's request.
func (s *store) createMessage(ctx context.Context, text string) (message, error) {
	m := message{Text: text}
	// The value is passed as a parameter ($1), never concatenated into the
	// SQL string, so user input cannot change the query.
	err := s.pg.QueryRow(ctx,
		"INSERT INTO messages (text) VALUES ($1) RETURNING id, created_at", text,
	).Scan(&m.ID, &m.CreatedAt)
	if err != nil {
		return m, err
	}

	_, err = s.events().InsertOne(ctx, bson.D{
		{Key: "type", Value: "message.created"},
		{Key: "message_id", Value: m.ID},
		{Key: "at", Value: m.CreatedAt},
	})
	if err != nil {
		log.Printf("audit event not recorded for message %d: %v", m.ID, err)
	}
	return m, nil
}

func (s *store) events() *mongo.Collection {
	return s.mongo.Database("app").Collection("audit_events")
}

func (s *store) close() {
	s.pg.Close()
	_ = s.valkey.Close()
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	_ = s.mongo.Disconnect(ctx)
}

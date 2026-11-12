// Package todo — сервер таск-трекера: база и синхронизация, пользователи и веб-клиент в одном процессе.
package todo

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users(
  id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', password_hash TEXT NOT NULL DEFAULT '',
  is_admin INTEGER NOT NULL DEFAULT 0, settings TEXT NOT NULL DEFAULT '{}',
  avatar BLOB, avatar_ver INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS ents(
  kind TEXT NOT NULL, id TEXT NOT NULL, creator_id TEXT NOT NULL, is_private INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0, f TEXT NOT NULL, t TEXT NOT NULL, d TEXT NOT NULL DEFAULT '',
  rev INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  parent_id TEXT NOT NULL DEFAULT '', list_id TEXT NOT NULL DEFAULT '', assignee_id TEXT NOT NULL DEFAULT '',
  done INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, completed_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(kind, id));
CREATE INDEX IF NOT EXISTS ents_rev ON ents(rev);
CREATE INDEX IF NOT EXISTS ents_parent ON ents(parent_id) WHERE parent_id <> '';
CREATE INDEX IF NOT EXISTS ents_list ON ents(list_id) WHERE list_id <> '';
CREATE TABLE IF NOT EXISTS devices(token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL, seen_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS login_fails(ip TEXT PRIMARY KEY, n INTEGER NOT NULL, until INTEGER NOT NULL, at INTEGER NOT NULL);
`

// Типы полей: s — строка, b — флаг, n — число, j — произвольный JSON.
var taskFields = map[string]byte{
	"title": 's', "description": 's', "checklist": 'j', "parent_id": 's', "list_id": 's',
	"assignee_id": 's', "deadline": 's', "reminder_at": 'n', "status": 's',
	"is_important": 'b', "in_today": 'b', "recurrence": 'j', "sort_order": 'n', "deleted": 'b',
}
var listFields = map[string]byte{
	"name": 's', "assignee_id": 's', "sort_order": 'n', "deleted": 'b', "delete_tasks": 'b',
}

func fieldsOf(kind string) map[string]byte {
	if kind == "list" {
		return listFields
	}
	return taskFields
}

var (
	idRe   = regexp.MustCompile(`^[A-Za-z0-9-]{8,64}$`)
	dateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
)

func defaultVal(k string, typ byte) any {
	switch typ {
	case 's':
		if k == "status" {
			return "open"
		}
		return ""
	case 'b':
		return false
	case 'n':
		return float64(0)
	}
	if k == "checklist" {
		return []any{}
	}
	return nil
}

// Проверка и приведение значения поля; ok=false — значение отбрасывается.
func cleanVal(k string, typ byte, v any) (any, bool) {
	switch typ {
	case 's':
		s, ok := v.(string)
		if !ok {
			return nil, false
		}
		max := 500
		if k == "description" {
			max = 20000
		}
		if len([]rune(s)) > max {
			s = string([]rune(s)[:max])
		}
		if k == "status" && s != "open" && s != "done" {
			return nil, false
		}
		if k == "deadline" && s != "" && !dateRe.MatchString(s) {
			return nil, false
		}
		if (k == "parent_id" || k == "list_id" || k == "assignee_id") && s != "" && !idRe.MatchString(s) {
			return nil, false
		}
		return s, true
	case 'b':
		b, ok := v.(bool)
		return b, ok
	case 'n':
		n, ok := v.(float64)
		return n, ok
	}
	if k == "checklist" {
		if v == nil {
			return []any{}, true
		}
		a, ok := v.([]any)
		if !ok || len(a) > 300 {
			return nil, false
		}
		return a, true
	}
	if k == "recurrence" {
		if v == nil {
			return nil, true
		}
		_, ok := v.(map[string]any)
		return v, ok
	}
	return v, true
}

// Ent — задача или список. F — значения полей, T — время последней правки каждого поля (мс),
// D — поля, которые клиент изменил и прислал (на сервере не хранится).
type Ent struct {
	Kind      string           `json:"-"`
	ID        string           `json:"id"`
	CreatorID string           `json:"creator_id"`
	IsPrivate bool             `json:"is_private"`
	CreatedAt int64            `json:"created_at"`
	F         map[string]any   `json:"f"`
	T         map[string]int64 `json:"t"`
	D         []string         `json:"d,omitempty"`
	Rev       int64            `json:"rev"`
	UpdatedAt int64            `json:"updated_at"`
}

func (e *Ent) S(k string) string { s, _ := e.F[k].(string); return s }
func (e *Ent) B(k string) bool   { b, _ := e.F[k].(bool); return b }
func (e *Ent) Done() bool        { return e.S("status") == "done" }
func (e *Ent) clone() *Ent {
	c := *e
	c.F = make(map[string]any, len(e.F))
	for k, v := range e.F {
		c.F[k] = v
	}
	c.T = make(map[string]int64, len(e.T))
	for k, v := range e.T {
		c.T[k] = v
	}
	c.D = append([]string(nil), e.D...)
	return &c
}
func (e *Ent) fillDefaults() {
	if e.F == nil {
		e.F = map[string]any{}
	}
	if e.T == nil {
		e.T = map[string]int64{}
	}
	for k, typ := range fieldsOf(e.Kind) {
		if _, ok := e.F[k]; !ok {
			e.F[k] = defaultVal(k, typ)
		}
	}
}
func sameEnt(a, b *Ent) bool {
	return a.CreatorID == b.CreatorID && a.IsPrivate == b.IsPrivate &&
		reflect.DeepEqual(a.F, b.F) && reflect.DeepEqual(a.T, b.T) && strings.Join(a.D, ",") == strings.Join(b.D, ",")
}

// SV — значение настройки со временем правки.
type SV struct {
	V any   `json:"v"`
	T int64 `json:"t"`
}

type User struct {
	ID           string
	Name         string
	PasswordHash string
	IsAdmin      bool
	Settings     map[string]SV
	AvatarVer    int64
	CreatedAt    int64
	UpdatedAt    int64
}

func (u *User) AdminMode() bool {
	if u == nil || !u.IsAdmin {
		return false
	}
	b, _ := u.Settings["admin_mode"].V.(bool)
	return b
}
func (u *User) Public() map[string]any {
	return map[string]any{"id": u.ID, "name": u.Name, "is_admin": u.IsAdmin, "has_password": u.PasswordHash != "", "avatar_ver": u.AvatarVer}
}

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"
	if path == ":memory:" {
		dsn = "file::memory:?_pragma=busy_timeout(5000)"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // один писатель: вся логика идёт последовательными транзакциями
	if _, err = db.Exec(schema); err != nil {
		return nil, err
	}
	s := &Store{db: db}
	err = s.Tx(func(tx *sql.Tx) error {
		if metaGet(tx, "rev") == "" {
			metaSet(tx, "rev", "0")
		}
		if metaGet(tx, "epoch") == "" {
			metaSet(tx, "epoch", randHex(8))
		}
		return nil
	})
	return s, err
}
func (s *Store) Close() error { return s.db.Close() }

// Backup — согласованная копия базы в файл (можно делать на работающем сервере).
func (s *Store) Backup(path string) error {
	_, err := s.db.Exec(`VACUUM INTO ?`, path)
	return err
}

func (s *Store) Tx(fn func(tx *sql.Tx) error) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	if err = fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
func nowMs() int64 { return time.Now().UnixMilli() }

func metaGet(tx *sql.Tx, k string) string {
	var v string
	tx.QueryRow(`SELECT v FROM meta WHERE k=?`, k).Scan(&v)
	return v
}
func metaSet(tx *sql.Tx, k, v string) {
	tx.Exec(`INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, k, v)
}
func metaInt(tx *sql.Tx, k string) int64 {
	n, _ := strconv.ParseInt(metaGet(tx, k), 10, 64)
	return n
}
func nextRev(tx *sql.Tx) int64 {
	n := metaInt(tx, "rev") + 1
	metaSet(tx, "rev", strconv.FormatInt(n, 10))
	return n
}

// MetaGet / MetaSet — доступ к служебным значениям вне транзакции.
func (s *Store) MetaGet(k string) (v string) {
	s.Tx(func(tx *sql.Tx) error { v = metaGet(tx, k); return nil })
	return
}
func (s *Store) MetaSet(k, v string) {
	s.Tx(func(tx *sql.Tx) error { metaSet(tx, k, v); return nil })
}

// ---- глобальные настройки (срок жизни завершённых, часовой пояс) ----
// Часовой пояс по умолчанию не задан: клиенты считают даты по своему устройству.

func globalGet(tx *sql.Tx) map[string]SV {
	g := map[string]SV{}
	json.Unmarshal([]byte(metaGet(tx, "global")), &g)
	if _, ok := g["retention_days"]; !ok {
		g["retention_days"] = SV{V: float64(30)}
	}
	if _, ok := g["tz"]; !ok {
		g["tz"] = SV{V: ""}
	}
	return g
}

// mergeSV — «последнее изменение побеждает» по каждому ключу. Возвращает true, если что-то поменялось.
func mergeSV(dst map[string]SV, src map[string]SV, offset, now int64) bool {
	ch := false
	for k, v := range src {
		if len(k) > 64 {
			continue
		}
		t := v.T + offset
		if t > now || v.T <= 0 {
			t = now
		}
		if cur, ok := dst[k]; !ok || t > cur.T {
			dst[k] = SV{V: v.V, T: t}
			ch = true
		}
	}
	return ch
}
func globalMerge(tx *sql.Tx, src map[string]SV, offset, now int64) bool {
	g := globalGet(tx)
	clean := map[string]SV{}
	for k, v := range src {
		switch k {
		case "retention_days":
			n, ok := v.V.(float64)
			if !ok || n < 1 || n > 3650 {
				continue
			}
		case "tz":
			z, ok := v.V.(string)
			if !ok {
				continue
			}
			if _, err := time.LoadLocation(z); err != nil || z == "Local" {
				continue
			}
		default:
			continue
		}
		clean[k] = v
	}
	if !mergeSV(g, clean, offset, now) {
		return false
	}
	b, _ := json.Marshal(g)
	metaSet(tx, "global", string(b))
	return true
}
func retentionDays(tx *sql.Tx) int64 {
	n, _ := globalGet(tx)["retention_days"].V.(float64)
	if n < 1 {
		n = 30
	}
	return int64(n)
}

// ---- сущности ----

const entCols = `kind,id,creator_id,is_private,created_at,f,t,d,rev,updated_at`

type rowScanner interface{ Scan(...any) error }

func scanEnt(r rowScanner) (*Ent, error) {
	var e Ent
	var f, t, d string
	var priv int
	if err := r.Scan(&e.Kind, &e.ID, &e.CreatorID, &priv, &e.CreatedAt, &f, &t, &d, &e.Rev, &e.UpdatedAt); err != nil {
		return nil, err
	}
	e.IsPrivate = priv != 0
	json.Unmarshal([]byte(f), &e.F)
	json.Unmarshal([]byte(t), &e.T)
	if d != "" {
		e.D = strings.Split(d, ",")
	}
	e.fillDefaults()
	return &e, nil
}
func loadEnt(tx *sql.Tx, kind, id string) *Ent {
	e, err := scanEnt(tx.QueryRow(`SELECT `+entCols+` FROM ents WHERE kind=? AND id=?`, kind, id))
	if err != nil {
		return nil
	}
	return e
}
func queryEnts(tx *sql.Tx, where string, args ...any) []*Ent {
	rows, err := tx.Query(`SELECT `+entCols+` FROM ents WHERE `+where, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*Ent
	for rows.Next() {
		if e, err := scanEnt(rows); err == nil {
			out = append(out, e)
		}
	}
	return out
}
func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
func (s *Store) saveEnt(tx *sql.Tx, e *Ent, now int64) error {
	e.Rev = nextRev(tx)
	e.UpdatedAt = now
	f, _ := json.Marshal(e.F)
	t, _ := json.Marshal(e.T)
	e.D = nil
	var completed int64
	if e.Kind == "task" && e.Done() {
		completed = e.T["status"]
	}
	_, err := tx.Exec(`INSERT INTO ents(kind,id,creator_id,is_private,created_at,f,t,d,rev,updated_at,parent_id,list_id,assignee_id,done,deleted,completed_at)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(kind,id) DO UPDATE SET creator_id=excluded.creator_id,is_private=excluded.is_private,f=excluded.f,t=excluded.t,d=excluded.d,
rev=excluded.rev,updated_at=excluded.updated_at,parent_id=excluded.parent_id,list_id=excluded.list_id,assignee_id=excluded.assignee_id,
done=excluded.done,deleted=excluded.deleted,completed_at=excluded.completed_at`,
		e.Kind, e.ID, e.CreatorID, b2i(e.IsPrivate), e.CreatedAt, string(f), string(t), "", e.Rev, now,
		e.S("parent_id"), e.S("list_id"), e.S("assignee_id"), b2i(e.Kind == "task" && e.Done()), b2i(e.B("deleted")), completed)
	return err
}

// ---- пользователи ----

const userCols = `id,name,password_hash,is_admin,settings,avatar_ver,created_at,updated_at`

func scanUser(r rowScanner) (*User, error) {
	var u User
	var adm int
	var se string
	if err := r.Scan(&u.ID, &u.Name, &u.PasswordHash, &adm, &se, &u.AvatarVer, &u.CreatedAt, &u.UpdatedAt); err != nil {
		return nil, err
	}
	u.IsAdmin = adm != 0
	u.Settings = map[string]SV{}
	json.Unmarshal([]byte(se), &u.Settings)
	return &u, nil
}
func loadUser(tx *sql.Tx, id string) *User {
	u, err := scanUser(tx.QueryRow(`SELECT `+userCols+` FROM users WHERE id=?`, id))
	if err != nil {
		return nil
	}
	return u
}
func loadUsers(tx *sql.Tx) []*User {
	rows, err := tx.Query(`SELECT ` + userCols + ` FROM users ORDER BY created_at, rowid`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*User
	for rows.Next() {
		if u, err := scanUser(rows); err == nil {
			out = append(out, u)
		}
	}
	return out
}
func saveSettings(tx *sql.Tx, u *User) {
	b, _ := json.Marshal(u.Settings)
	tx.Exec(`UPDATE users SET settings=? WHERE id=?`, string(b), u.ID)
}

// adminID — кому переходят задачи удалённых пользователей: первый (самый ранний) администратор.
func adminID(tx *sql.Tx, except string) string {
	var id string
	tx.QueryRow(`SELECT id FROM users WHERE id<>? ORDER BY is_admin DESC, created_at, rowid LIMIT 1`, except).Scan(&id)
	return id
}

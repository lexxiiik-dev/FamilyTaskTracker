package todo

import (
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

type Config struct {
	Listen    string `json:"listen"`     // адрес и порт, например ":8443" или "127.0.0.1:8080"
	DB        string `json:"db"`         // файл базы SQLite
	AccessKey string `json:"access_key"` // ключ доступа: без него сервер не отвечает на запросы API
	// HTTPS с собственным сертификатом (самоподписанным): приложения проверяют отпечаток его ключа.
	// Пустые cert и key — обычный HTTP (сервер стоит за обратным прокси с настоящим сертификатом).
	Cert string `json:"cert"`
	Key  string `json:"key"`
	// Адрес, по которому сервер видят пользователи (показывается администратору для подключения).
	PublicURL string `json:"public_url"`
	// Сервер стоит за обратным прокси: адрес клиента брать из X-Forwarded-For.
	TrustProxy bool `json:"trust_proxy"`
}

func (c Config) TLS() bool { return c.Cert != "" && c.Key != "" }

type Server struct {
	S   *Store
	Cfg Config
	Pin string       // отпечаток ключа сертификата (только для HTTPS со своим сертификатом)
	Web http.Handler // веб-клиент

	mu       sync.Mutex
	OnChange func() // вызывается после изменений (для тестов)
}

// ConnectKey — ключ доступа, который вводят в приложении: `<ключ>.<отпечаток>` или просто `<ключ>`.
func (sv *Server) ConnectKey() string {
	if sv.Pin == "" {
		return sv.Cfg.AccessKey
	}
	return sv.Cfg.AccessKey + "." + sv.Pin
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"error": msg})
}
func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		fail(w, 400, "bad_request")
		return false
	}
	return true
}
func eq(a, b string) bool { return a != "" && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

func (sv *Server) clientIP(r *http.Request) string {
	if sv.Cfg.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			p := strings.Split(xff, ",")
			return strings.TrimSpace(p[len(p)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return strings.TrimPrefix(host, "::ffff:")
}

const (
	lvKey   = iota // достаточно ключа доступа
	lvUser         // вошедший пользователь
	lvAdmin        // администратор
)

type handler func(w http.ResponseWriter, r *http.Request, a Actor, u *User)

// drop рвёт соединение без ответа: без ключа доступа API сервера «молчит».
func drop(w http.ResponseWriter) {
	if hj, ok := w.(http.Hijacker); ok {
		if c, _, err := hj.Hijack(); err == nil {
			c.Close()
			return
		}
	}
	panic(http.ErrAbortHandler)
}

func (sv *Server) wrap(level int, fn handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !eq(sv.Cfg.AccessKey, r.Header.Get("X-Access-Key")) {
			drop(w)
			return
		}
		var a Actor
		var u *User
		if level != lvKey {
			tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			known := false
			sv.S.Tx(func(tx *sql.Tx) error {
				if tok != "" {
					u, known = deviceUser(tx, tok)
					if u != nil {
						tx.Exec(`UPDATE devices SET seen_at=? WHERE token_hash=?`, nowMs(), tokenHash(tok))
					}
				}
				return nil
			})
			if u == nil {
				code := "bad_token"
				if known {
					code = "user_deleted"
				}
				fail(w, 401, code)
				return
			}
			a.UserID, a.Admin = u.ID, u.AdminMode()
			if level == lvAdmin && !u.IsAdmin {
				fail(w, 403, "Нужны права администратора")
				return
			}
		}
		fn(w, r, a, u)
	}
}

func (sv *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/hello", sv.wrap(lvKey, sv.hHello))
	mux.HandleFunc("POST /v1/setup", sv.wrap(lvKey, sv.hSetup))
	mux.HandleFunc("POST /v1/login", sv.wrap(lvKey, sv.hLogin))
	mux.HandleFunc("GET /v1/avatar/{id}", sv.wrap(lvKey, sv.hAvatar))
	mux.HandleFunc("GET /v1/changes", sv.wrap(lvUser, sv.hPull))
	mux.HandleFunc("POST /v1/changes", sv.wrap(lvUser, sv.hPush))
	mux.HandleFunc("POST /v1/avatar", sv.wrap(lvUser, sv.hAvatarUpload))
	mux.HandleFunc("POST /v1/me/password", sv.wrap(lvUser, sv.hMyPassword))
	mux.HandleFunc("GET /v1/admin/settings", sv.wrap(lvAdmin, sv.hAdminGet))
	mux.HandleFunc("PUT /v1/admin/settings", sv.wrap(lvAdmin, sv.hAdminSet))
	mux.HandleFunc("GET /v1/admin/connect-info", sv.wrap(lvAdmin, sv.hConnectInfo))
	mux.HandleFunc("POST /v1/admin/users", sv.wrap(lvAdmin, sv.hUserCreate))
	mux.HandleFunc("PATCH /v1/admin/users/{id}", sv.wrap(lvAdmin, sv.hUserUpdate))
	mux.HandleFunc("DELETE /v1/admin/users/{id}", sv.wrap(lvAdmin, sv.hUserDelete))
	mux.HandleFunc("/v1/", func(w http.ResponseWriter, r *http.Request) {
		if !eq(sv.Cfg.AccessKey, r.Header.Get("X-Access-Key")) {
			drop(w)
			return
		}
		fail(w, 404, "not_found")
	})
	if sv.Web != nil {
		mux.Handle("/", sv.Web)
	}
	return mux
}

func publicUsers(tx *sql.Tx) []map[string]any {
	out := []map[string]any{}
	for _, u := range loadUsers(tx) {
		out = append(out, u.Public())
	}
	return out
}

func (sv *Server) changed() {
	if sv.OnChange != nil {
		sv.OnChange()
	}
}

func (sv *Server) hHello(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	res := map[string]any{"time": nowMs()}
	sv.S.Tx(func(tx *sql.Tx) error {
		res["users"] = publicUsers(tx)
		res["epoch"] = metaGet(tx, "epoch")
		n, _ := countUsers(tx)
		res["setup"] = n == 0 // пользователей ещё нет: первый станет администратором
		return nil
	})
	writeJSON(w, 200, res)
}

type authReq struct {
	UserID   string `json:"user_id"`
	Name     string `json:"name"`
	Password string `json:"password"`
	Device   string `json:"device"`
}

// hSetup — первый запуск: первый пользователь становится администратором и сразу входит.
func (sv *Server) hSetup(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	var b authReq
	if !readJSON(w, r, &b) {
		return
	}
	var u *User
	var tok string
	err := sv.S.Tx(func(tx *sql.Tx) (err error) {
		if u, err = sv.S.Setup(tx, b.Name, b.Password); err != nil {
			return err
		}
		tok = newDevice(tx, u.ID, b.Device)
		return nil
	})
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	log.Printf("создан первый пользователь (администратор): %s", u.Name)
	writeJSON(w, 200, map[string]any{"ok": true, "token": tok, "user_id": u.ID})
	sv.changed()
}

func (sv *Server) hLogin(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	var b authReq
	if !readJSON(w, r, &b) {
		return
	}
	var tok string
	var lerr error
	found := false
	sv.S.Tx(func(tx *sql.Tx) error {
		u := loadUser(tx, b.UserID)
		if u == nil {
			return nil
		}
		found = true
		if lerr = sv.S.CheckPassword(tx, u, b.Password, sv.clientIP(r)); lerr == nil {
			tok = newDevice(tx, u.ID, b.Device)
		}
		return nil
	})
	if !found {
		fail(w, 404, "Пользователь не найден")
		return
	}
	if lerr != nil {
		writeJSON(w, 403, map[string]any{"error": lerr.Error(), "need_password": true})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "token": tok, "user_id": b.UserID})
}

func (sv *Server) hPull(w http.ResponseWriter, r *http.Request, a Actor, u *User) {
	cursor, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	res := map[string]any{"time": nowMs()}
	sv.S.Tx(func(tx *sql.Tx) error {
		ch := pull(tx, a, cursor)
		res["tasks"], res["lists"], res["cursor"], res["more"] = ch.Tasks, ch.Lists, ch.Cursor, ch.More
		res["epoch"] = metaGet(tx, "epoch")
		res["global"] = globalGet(tx)
		res["users"] = publicUsers(tx)
		res["settings"] = u.Settings
		res["me"] = u.ID
		return nil
	})
	writeJSON(w, 200, res)
}

type pushReq struct {
	Now      int64         `json:"now"`
	Tasks    []*Ent        `json:"tasks"`
	Lists    []*Ent        `json:"lists"`
	Settings map[string]SV `json:"settings"`
}

func (sv *Server) hPush(w http.ResponseWriter, r *http.Request, a Actor, u *User) {
	var b pushReq
	if !readJSON(w, r, &b) {
		return
	}
	res := map[string]any{}
	err := sv.S.Tx(func(tx *sql.Tx) error {
		ap := sv.S.NewApplier(tx, a, b.Now)
		// сначала списки: задачи ссылаются на них; среди задач — сначала основные
		for _, l := range b.Lists {
			if err := ap.Apply("list", l); err != nil {
				return err
			}
		}
		for pass := 0; pass < 2; pass++ {
			for _, t := range b.Tasks {
				if t == nil {
					continue
				}
				pid, _ := t.F["parent_id"].(string)
				if (pid == "") == (pass == 0) {
					if err := ap.Apply("task", t); err != nil {
						return err
					}
				}
			}
		}
		if err := ap.Finish(); err != nil {
			return err
		}
		if len(b.Settings) > 0 && mergeSV(u.Settings, b.Settings, ap.offset, ap.now) {
			saveSettings(tx, u)
		}
		res["tasks"], res["lists"] = ap.touchedFor()
		rej := []string{}
		for id := range ap.Rejected {
			rej = append(rej, id)
		}
		res["rejected"] = rej
		res["time"] = ap.now
		res["settings"] = u.Settings
		return nil
	})
	if err != nil {
		log.Printf("push: %v", err)
		fail(w, 500, "internal")
		return
	}
	writeJSON(w, 200, res)
	sv.changed()
}

func (sv *Server) hAvatar(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	var data []byte
	sv.S.Tx(func(tx *sql.Tx) error {
		tx.QueryRow(`SELECT avatar FROM users WHERE id=?`, r.PathValue("id")).Scan(&data)
		return nil
	})
	if len(data) == 0 {
		http.Error(w, "", 404)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Write(data)
}

const maxAvatar = 4 << 20

func (sv *Server) hAvatarUpload(w http.ResponseWriter, r *http.Request, a Actor, u *User) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAvatar+1))
	if err != nil || len(data) > maxAvatar {
		fail(w, 413, "Картинка слишком большая (макс 4 МБ)")
		return
	}
	prev, err := MakePreview(data, 128)
	if err != nil {
		fail(w, 400, "Это не картинка")
		return
	}
	var ver int64
	sv.S.Tx(func(tx *sql.Tx) error {
		setAvatar(tx, u.ID, prev)
		tx.QueryRow(`SELECT avatar_ver FROM users WHERE id=?`, u.ID).Scan(&ver)
		return nil
	})
	writeJSON(w, 200, map[string]any{"ok": true, "avatar_ver": ver})
	sv.changed()
}

// hMyPassword — пользователь меняет свой пароль (нужен текущий, если он есть).
func (sv *Server) hMyPassword(w http.ResponseWriter, r *http.Request, a Actor, u *User) {
	var b struct {
		Old string `json:"old"`
		New string `json:"new"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	err := sv.S.Tx(func(tx *sql.Tx) error {
		if err := sv.S.CheckPassword(tx, u, b.Old, sv.clientIP(r)); err != nil {
			return errors.New("Неверный текущий пароль")
		}
		_, err := sv.S.UpdateUser(tx, u.ID, UserPatch{Password: &b.New})
		if err == nil {
			// это устройство остаётся в системе: выдаём ему новый токен
			tok := newDevice(tx, u.ID, "")
			tx.Exec(`DELETE FROM devices WHERE user_id=? AND token_hash<>?`, u.ID, tokenHash(tok))
			w.Header().Set("X-New-Token", tok)
		}
		return err
	})
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "token": w.Header().Get("X-New-Token")})
	sv.changed()
}

func (sv *Server) adminSettings(tx *sql.Tx) map[string]any {
	g := globalGet(tx)
	return map[string]any{"retention_days": g["retention_days"].V, "tz": g["tz"].V}
}

func (sv *Server) hAdminGet(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	sv.S.Tx(func(tx *sql.Tx) error {
		writeJSON(w, 200, sv.adminSettings(tx))
		return nil
	})
}
func (sv *Server) hAdminSet(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	var b map[string]any
	if !readJSON(w, r, &b) {
		return
	}
	src := map[string]SV{}
	now := nowMs()
	for k, v := range b {
		src[k] = SV{V: v, T: now}
	}
	sv.S.Tx(func(tx *sql.Tx) error {
		globalMerge(tx, src, 0, now)
		writeJSON(w, 200, sv.adminSettings(tx))
		return nil
	})
	sv.changed()
}

func (sv *Server) hConnectInfo(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	writeJSON(w, 200, map[string]any{"url": sv.Cfg.PublicURL, "key": sv.ConnectKey()})
}

// ---- управление пользователями (администратор) ----

func (sv *Server) userResult(w http.ResponseWriter, u *User, err error) {
	if err != nil {
		code := 400
		if errors.Is(err, errNoUser) {
			code = 404
		}
		fail(w, code, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "user": u.Public()})
	sv.changed()
}

func (sv *Server) hUserCreate(w http.ResponseWriter, r *http.Request, a Actor, _ *User) {
	var b struct {
		Name     string `json:"name"`
		Password string `json:"password"`
		IsAdmin  bool   `json:"is_admin"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	var u *User
	err := sv.S.Tx(func(tx *sql.Tx) (err error) {
		u, err = sv.S.CreateUser(tx, b.Name, b.Password, b.IsAdmin)
		return
	})
	sv.userResult(w, u, err)
}

func (sv *Server) hUserUpdate(w http.ResponseWriter, r *http.Request, a Actor, me *User) {
	var p UserPatch
	if !readJSON(w, r, &p) {
		return
	}
	var u *User
	err := sv.S.Tx(func(tx *sql.Tx) (err error) {
		u, err = sv.S.UpdateUser(tx, r.PathValue("id"), p)
		return
	})
	sv.userResult(w, u, err)
}

func (sv *Server) hUserDelete(w http.ResponseWriter, r *http.Request, a Actor, me *User) {
	id := r.PathValue("id")
	if id == me.ID {
		fail(w, 400, "Себя удалить нельзя")
		return
	}
	if err := sv.S.Tx(func(tx *sql.Tx) error { return sv.S.DeleteUser(tx, id) }); err != nil {
		code := 400
		if errors.Is(err, errNoUser) {
			code = 404
		}
		fail(w, code, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
	sv.changed()
}

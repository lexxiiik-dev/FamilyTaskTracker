package todo

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"strings"

	"golang.org/x/crypto/bcrypt"
	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// ---- пользователи: заводит и меняет администратор (первого — мастер первого запуска) ----

var (
	errNoName    = errors.New("Введите имя")
	errNameTaken = errors.New("Пользователь с таким именем уже есть")
	errShortPw   = errors.New("Пароль — не короче 4 символов")
	errLastAdmin = errors.New("Должен остаться хотя бы один администратор")
	errNoUser    = errors.New("Пользователь не найден")
	errSetupDone = errors.New("Сервер уже настроен")
	errNeedPwAdm = errors.New("У администратора должен быть пароль")
)

func cleanName(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40])
	}
	return s
}

func hashPassword(pw string) (string, error) {
	if pw == "" {
		return "", nil
	}
	if len([]rune(pw)) < 4 {
		return "", errShortPw
	}
	h, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(h), err
}

// userByName ищет пользователя по имени без учёта регистра (lower() в SQLite не знает кириллицы).
func userByName(tx *sql.Tx, name string) *User {
	for _, u := range loadUsers(tx) {
		if strings.EqualFold(u.Name, name) {
			return u
		}
	}
	return nil
}

func nameTaken(tx *sql.Tx, name, except string) bool {
	u := userByName(tx, name)
	return u != nil && u.ID != except
}

func countUsers(tx *sql.Tx) (all, admins int) {
	tx.QueryRow(`SELECT COUNT(*), COALESCE(SUM(is_admin),0) FROM users`).Scan(&all, &admins)
	return
}

// CreateUser заводит пользователя. Пароль может быть пустым (вход без пароля), кроме администратора.
func (s *Store) CreateUser(tx *sql.Tx, name, password string, admin bool) (*User, error) {
	name = cleanName(name)
	if name == "" {
		return nil, errNoName
	}
	if nameTaken(tx, name, "") {
		return nil, errNameTaken
	}
	if admin && password == "" {
		return nil, errNeedPwAdm
	}
	h, err := hashPassword(password)
	if err != nil {
		return nil, err
	}
	id := newID()
	now := nowMs()
	if _, err := tx.Exec(`INSERT INTO users(id,name,password_hash,is_admin,created_at,updated_at) VALUES(?,?,?,?,?,?)`, id, name, h, b2i(admin), now, now); err != nil {
		return nil, err
	}
	return loadUser(tx, id), nil
}

// Setup — первый пользователь сервера, он становится администратором. Работает, только пока пользователей нет.
func (s *Store) Setup(tx *sql.Tx, name, password string) (*User, error) {
	if n, _ := countUsers(tx); n > 0 {
		return nil, errSetupDone
	}
	return s.CreateUser(tx, name, password, true)
}

// UserPatch — что меняет администратор (nil — не менять). Пароль "" снимает пароль.
type UserPatch struct {
	Name     *string `json:"name"`
	Password *string `json:"password"`
	IsAdmin  *bool   `json:"is_admin"`
}

func (s *Store) UpdateUser(tx *sql.Tx, id string, p UserPatch) (*User, error) {
	u := loadUser(tx, id)
	if u == nil {
		return nil, errNoUser
	}
	if p.Name != nil {
		n := cleanName(*p.Name)
		if n == "" {
			return nil, errNoName
		}
		if nameTaken(tx, n, id) {
			return nil, errNameTaken
		}
		u.Name = n
	}
	if p.IsAdmin != nil && *p.IsAdmin != u.IsAdmin {
		if !*p.IsAdmin {
			if _, admins := countUsers(tx); admins <= 1 {
				return nil, errLastAdmin
			}
		}
		u.IsAdmin = *p.IsAdmin
	}
	if p.Password != nil {
		h, err := hashPassword(*p.Password)
		if err != nil {
			return nil, err
		}
		u.PasswordHash = h
	}
	if u.IsAdmin && u.PasswordHash == "" {
		return nil, errNeedPwAdm
	}
	_, err := tx.Exec(`UPDATE users SET name=?,password_hash=?,is_admin=?,updated_at=? WHERE id=?`, u.Name, u.PasswordHash, b2i(u.IsAdmin), nowMs(), id)
	if err == nil && p.Password != nil {
		// после смены пароля остальные устройства пользователя входят заново
		tx.Exec(`DELETE FROM devices WHERE user_id=?`, id)
	}
	return u, err
}

// DeleteUser удаляет пользователя: его приватные задачи удаляются, общие задачи и списки
// переходят к первому администратору.
func (s *Store) DeleteUser(tx *sql.Tx, id string) error {
	u := loadUser(tx, id)
	if u == nil {
		return errNoUser
	}
	if u.IsAdmin {
		if _, admins := countUsers(tx); admins <= 1 {
			return errLastAdmin
		}
	}
	if _, err := tx.Exec(`DELETE FROM users WHERE id=?`, id); err != nil {
		return err
	}
	return s.forgetUser(tx, id, nowMs())
}

// forgetUser — последствия удаления пользователя.
func (s *Store) forgetUser(tx *sql.Tx, uid string, now int64) error {
	admin := adminID(tx, uid)
	// устройства не удаляем: по токену сервер отвечает «пользователь удалён», и устройство
	// перестаёт синхронизироваться, сохраняя локальные данные
	// приватные задачи удаляются совсем
	if _, err := tx.Exec(`DELETE FROM ents WHERE kind='task' AND is_private=1 AND creator_id=?`, uid); err != nil {
		return err
	}
	ap := s.NewApplier(tx, Actor{Service: true}, 0)
	for _, e := range queryEnts(tx, `creator_id=? OR assignee_id=?`, uid, uid) {
		if e.CreatorID == uid {
			e.CreatorID = admin // общие задачи и списки переходят к админу как к автору
		}
		if e.S("assignee_id") == uid {
			if e.Kind == "task" {
				ap.force(e, "assignee_id", admin) // исполнителем становится админ
			} else {
				ap.force(e, "assignee_id", "") // у списка поле очищается
			}
		}
		if err := s.saveEnt(tx, e, now); err != nil {
			return err
		}
	}
	return nil
}

// SetPasswordByName — смена пароля из командной строки сервера (если администратор забыл пароль).
func (s *Store) SetPasswordByName(tx *sql.Tx, name, password string) error {
	u := userByName(tx, cleanName(name))
	if u == nil {
		return errNoUser
	}
	_, err := s.UpdateUser(tx, u.ID, UserPatch{Password: &password})
	return err
}

func newID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// ---- вход и устройства ----

const (
	failMax  = 5
	failLock = 60
)

var errLocked = errors.New("Слишком много попыток, подождите минуту")
var errBadPassword = errors.New("Неверный пароль")

// CheckPassword — проверка пароля: bcrypt, 5 ошибок с одного адреса — пауза 60 с.
func (s *Store) CheckPassword(tx *sql.Tx, u *User, password, ip string) error {
	now := nowMs() / 1000
	var n, until int64
	tx.QueryRow(`SELECT n, until FROM login_fails WHERE ip=?`, ip).Scan(&n, &until)
	if until > now {
		return errLocked
	}
	if u.PasswordHash == "" || bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)) == nil {
		tx.Exec(`DELETE FROM login_fails WHERE ip=?`, ip)
		return nil
	}
	n++
	until = 0
	if n >= failMax {
		n, until = 0, now+failLock
	}
	tx.Exec(`INSERT INTO login_fails(ip,n,until,at) VALUES(?,?,?,?) ON CONFLICT(ip) DO UPDATE SET n=excluded.n, until=excluded.until, at=excluded.at`, ip, n, until, now)
	return errBadPassword
}

func tokenHash(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(h[:])
}
func newDevice(tx *sql.Tx, uid, name string) string {
	tok := randHex(32)
	if len(name) > 80 {
		name = name[:80]
	}
	tx.Exec(`INSERT INTO devices(token_hash,user_id,name,created_at) VALUES(?,?,?,?)`, tokenHash(tok), uid, name, nowMs())
	return tok
}

// deviceUser: пользователь по токену устройства. known=false — токен неизвестен;
// known=true и u=nil — пользователь удалён.
func deviceUser(tx *sql.Tx, tok string) (u *User, known bool) {
	var uid string
	if tx.QueryRow(`SELECT user_id FROM devices WHERE token_hash=?`, tokenHash(tok)).Scan(&uid) != nil {
		return nil, false
	}
	return loadUser(tx, uid), true
}

// ---- аватарки ----

// MakePreview — квадратное JPEG-превью со стороной size (обрезка по центру).
func MakePreview(data []byte, size int) ([]byte, error) {
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	b := src.Bounds()
	side := b.Dx()
	if b.Dy() < side {
		side = b.Dy()
	}
	x0 := b.Min.X + (b.Dx()-side)/2
	y0 := b.Min.Y + (b.Dy()-side)/2
	dst := image.NewRGBA(image.Rect(0, 0, size, size))
	draw.Draw(dst, dst.Bounds(), image.White, image.Point{}, draw.Src)
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, image.Rect(x0, y0, x0+side, y0+side), draw.Over, nil)
	var out bytes.Buffer
	if err = jpeg.Encode(&out, dst, &jpeg.Options{Quality: 85}); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func setAvatar(tx *sql.Tx, uid string, preview []byte) error {
	now := nowMs()
	_, err := tx.Exec(`UPDATE users SET avatar=?, avatar_ver=?, updated_at=? WHERE id=?`, preview, now, now, uid)
	return err
}

package todo

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"
)

// ID пользователей выдаёт сервер; заполняются в newVPS
var uA, uB, uC string

type vps struct {
	sv *Server
	ts *httptest.Server
	t  *testing.T
	// токен администратора
	admin string
}

// newVPS — сервер с тремя пользователями: администратор «Админ» (пароль secret), Боб и Клара (без паролей).
func newVPS(t *testing.T) *vps {
	st, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	sv := &Server{S: st, Cfg: Config{AccessKey: "key"}, Web: WebHandler()}
	ts := httptest.NewTLSServer(sv.Handler())
	sv.Pin = SPKIPin(ts.Certificate())
	t.Cleanup(func() { ts.Close(); st.Close() })
	v := &vps{sv: sv, ts: ts, t: t}
	code, r := v.req("", "POST", "/v1/setup", map[string]any{"name": "Админ", "password": "secret", "device": "test"})
	if code != 200 {
		t.Fatalf("setup: %d %v", code, r)
	}
	v.admin, uA = r["token"].(string), r["user_id"].(string)
	uB = v.addUser("Боб", "", false)
	uC = v.addUser("Клара", "", false)
	return v
}
func (v *vps) addUser(name, pw string, admin bool) string {
	code, r := v.req(v.admin, "POST", "/v1/admin/users", map[string]any{"name": name, "password": pw, "is_admin": admin})
	if code != 200 {
		v.t.Fatalf("создание %s: %d %v", name, code, r)
	}
	return r["user"].(map[string]any)["id"].(string)
}

func (v *vps) req(token, method, path string, body any) (int, map[string]any) {
	var rd io.Reader
	if body != nil {
		j, _ := json.Marshal(body)
		rd = bytes.NewReader(j)
	}
	r, _ := http.NewRequest(method, v.ts.URL+path, rd)
	r.Header.Set("X-Access-Key", "key")
	r.Header.Set("Authorization", "Bearer "+token)
	resp, err := v.ts.Client().Do(r)
	if err != nil {
		v.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}
func (v *vps) login(uid, pw string) string {
	code, r := v.req("", "POST", "/v1/login", map[string]any{"user_id": uid, "password": pw, "device": "test"})
	if code != 200 {
		v.t.Fatalf("login %s: %d %v", uid, code, r)
	}
	return r["token"].(string)
}

// ent собирает запись «как от клиента»: все переданные поля изменены в момент ts.
func ent(id, creator string, private bool, ts int64, f map[string]any) *Ent {
	e := &Ent{ID: id, CreatorID: creator, IsPrivate: private, CreatedAt: ts, F: f, T: map[string]int64{}}
	for k := range f {
		e.T[k] = ts
		e.D = append(e.D, k)
	}
	return e
}
func (v *vps) push(token string, clientNow int64, tasks []*Ent, lists []*Ent) map[string]any {
	code, r := v.req(token, "POST", "/v1/changes", map[string]any{"now": clientNow, "tasks": tasks, "lists": lists})
	if code != 200 {
		v.t.Fatalf("push: %d %v", code, r)
	}
	return r
}
func (v *vps) get(kind, id string) *Ent {
	var e *Ent
	v.sv.S.Tx(func(tx *sql.Tx) error { e = loadEnt(tx, kind, id); return nil })
	return e
}
func (v *vps) pullIDs(token string, cursor int64) (ids []string, next int64) {
	code, r := v.req(token, "GET", fmt.Sprintf("/v1/changes?cursor=%d", cursor), nil)
	if code != 200 {
		v.t.Fatalf("pull: %d %v", code, r)
	}
	for _, x := range r["tasks"].([]any) {
		ids = append(ids, x.(map[string]any)["id"].(string))
	}
	sort.Strings(ids)
	return ids, int64(r["cursor"].(float64))
}
func has(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// Офлайн-правки одной задачи на двух устройствах: по каждому полю побеждает более поздняя правка,
// а не то устройство, которое позже вышло в сеть; сбитые часы устройства не мешают.
func TestLWWPerFieldWithClockSkew(t *testing.T) {
	v := newVPS(t)
	d1, d2 := v.login(uB, ""), v.login(uB, "")
	base := nowMs()
	v.push(d1, base, []*Ent{ent("task-0001", uB, false, base-60000, map[string]any{"title": "исходная", "description": "исходное"})}, nil)

	// устройство 1 (часы верные): название в -5 с, описание в -20 с; выходит в сеть первым
	e1 := ent("task-0001", uB, false, 0, map[string]any{"title": "от первого", "description": "от первого"})
	e1.T["title"], e1.T["description"] = base-5000, base-20000
	v.push(d1, base, []*Ent{e1}, nil)

	// устройство 2 (часы спешат на час): название в -8 с, описание в -10 с по настоящему времени; выходит в сеть позже
	skew := int64(3600000)
	e2 := ent("task-0001", uB, false, 0, map[string]any{"title": "от второго", "description": "от второго"})
	e2.T["title"], e2.T["description"] = base-8000+skew, base-10000+skew
	v.push(d2, nowMs()+skew, []*Ent{e2}, nil)

	got := v.get("task", "task-0001")
	if got.S("title") != "от первого" {
		t.Errorf("название: победила более ранняя правка: %q", got.S("title"))
	}
	if got.S("description") != "от второго" {
		t.Errorf("описание: должна победить более поздняя правка, а стало %q", got.S("description"))
	}
}

// Удаление пользователем рассылается; очистка по сроку жизни — нет; правка очищенной задачи создаёт её заново.
func TestDeleteVsPurge(t *testing.T) {
	v := newVPS(t)
	d1, d2 := v.login(uB, ""), v.login(uB, "")
	base := nowMs()
	old := base - 40*86400000
	v.push(d1, base, []*Ent{
		ent("task-del1", uB, false, base-1000, map[string]any{"title": "удалю"}),
		ent("task-old1", uB, false, old, map[string]any{"title": "давно закрыта", "status": "done"}),
	}, nil)
	_, cur := v.pullIDs(d2, 0)

	v.push(d1, nowMs(), []*Ent{ent("task-del1", uB, false, nowMs(), map[string]any{"deleted": true})}, nil)
	if n, _ := v.sv.S.Purge(); n != 1 {
		t.Fatalf("очистка должна убрать одну задачу, убрала %d", n)
	}
	ids, _ := v.pullIDs(d2, cur)
	if !has(ids, "task-del1") {
		t.Error("пометка удаления не пришла второму устройству")
	}
	if has(ids, "task-old1") {
		t.Error("очистка по сроку жизни не должна рассылаться")
	}
	if v.get("task", "task-old1") != nil {
		t.Error("очищенная задача осталась на сервере")
	}
	if !v.get("task", "task-del1").B("deleted") {
		t.Error("пометка удаления должна храниться")
	}
	// устройство прислало правку очищенной задачи — сервер создаёт её заново
	e := ent("task-old1", uB, false, old, map[string]any{"title": "давно закрыта", "status": "done"})
	e.F["title"], e.T["title"], e.D = "исправлено", nowMs(), []string{"title"}
	v.push(d2, nowMs(), []*Ent{e}, nil)
	if got := v.get("task", "task-old1"); got == nil || got.S("title") != "исправлено" || !got.Done() {
		t.Errorf("очищенная задача не восстановлена: %+v", got)
	}
}

func TestPermissionsAndPrivacy(t *testing.T) {
	v := newVPS(t)
	a, b, c := v.login(uA, "secret"), v.login(uB, ""), v.login(uC, "")
	now := nowMs()
	v.push(b, now, []*Ent{
		ent("task-shared", uB, false, now-5000, map[string]any{"title": "общая", "assignee_id": uC}),
		ent("task-priv01", uB, true, now-5000, map[string]any{"title": "секрет"}),
	}, nil)

	// приватную задачу не получает никто, даже админ в режиме администратора
	v.req(a, "POST", "/v1/changes", map[string]any{"now": nowMs(), "settings": map[string]SV{"admin_mode": {V: true, T: nowMs()}}})
	for name, tok := range map[string]string{"админ": a, "другой": c} {
		if ids, _ := v.pullIDs(tok, 0); has(ids, "task-priv01") || !has(ids, "task-shared") {
			t.Errorf("%s: видимость нарушена: %v", name, ids)
		}
	}
	if ids, _ := v.pullIDs(b, 0); !has(ids, "task-priv01") {
		t.Error("автор не видит свою приватную задачу")
	}
	// ...и править её чужой не может, даже зная ID
	r := v.push(a, nowMs(), []*Ent{ent("task-priv01", uB, true, nowMs(), map[string]any{"title": "взлом"})}, nil)
	if v.get("task", "task-priv01").S("title") != "секрет" || len(r["tasks"].([]any)) != 0 {
		t.Error("чужая приватная задача изменена или показана")
	}
	// исполнитель: закрыть может, переименовать — нет
	v.push(b, nowMs(), []*Ent{ent("task-shared", uB, false, nowMs(), map[string]any{"deadline": "2030-01-01", "recurrence": map[string]any{"type": "daily"}})}, nil)
	v.push(c, nowMs(), []*Ent{ent("task-shared", uB, false, nowMs(), map[string]any{"title": "чужое имя", "status": "done"})}, nil)
	if g := v.get("task", "task-shared"); g.S("title") != "общая" || !g.Done() {
		t.Errorf("исполнитель: %q %q", g.S("title"), g.S("status"))
	}
	// при закрытии срок и повторение снимает сервер (исполнитель сам их менять не вправе)
	if g := v.get("task", "task-shared"); g.S("deadline") != "" || g.F["recurrence"] != nil {
		t.Errorf("у закрытой задачи остались срок %q и повторение %v", g.S("deadline"), g.F["recurrence"])
	}
	// посторонний (не автор и не исполнитель) — ничего
	d := v.login(v.addUser("Дина", "", false), "")
	r = v.push(d, nowMs(), []*Ent{ent("task-shared", uB, false, nowMs(), map[string]any{"status": "open", "deleted": true})}, nil)
	if g := v.get("task", "task-shared"); !g.Done() || g.B("deleted") || len(r["rejected"].([]any)) != 1 {
		t.Error("посторонний смог изменить задачу")
	}
	// админ в режиме администратора — что угодно с общими
	v.push(a, nowMs(), []*Ent{ent("task-shared", uB, false, nowMs(), map[string]any{"title": "поправил админ"})}, nil)
	if v.get("task", "task-shared").S("title") != "поправил админ" {
		t.Error("режим администратора не сработал")
	}
	// без режима администратора админ — обычный пользователь
	v.req(a, "POST", "/v1/changes", map[string]any{"now": nowMs(), "settings": map[string]SV{"admin_mode": {V: false, T: nowMs()}}})
	v.push(a, nowMs(), []*Ent{ent("task-shared", uB, false, nowMs(), map[string]any{"title": "без режима"})}, nil)
	if v.get("task", "task-shared").S("title") != "поправил админ" {
		t.Error("админ без режима администратора изменил чужую задачу")
	}
	// у приватной задачи исполнитель всегда автор
	v.push(b, nowMs(), []*Ent{ent("task-priv01", uB, true, nowMs(), map[string]any{"assignee_id": uC})}, nil)
	if v.get("task", "task-priv01").S("assignee_id") != uB {
		t.Error("у приватной задачи сменился исполнитель")
	}
	// без ключа доступа сервер не отвечает вовсе
	req, _ := http.NewRequest("GET", v.ts.URL+"/v1/hello", nil)
	if resp, err := v.ts.Client().Do(req); err == nil {
		resp.Body.Close()
		t.Error("сервер ответил без ключа доступа")
	}
	// неверный пароль
	if code, _ := v.req("", "POST", "/v1/login", map[string]any{"user_id": uA, "password": "нет"}); code != 403 {
		t.Errorf("вход с неверным паролем: %d", code)
	}
}

func TestUserDeletion(t *testing.T) {
	v := newVPS(t)
	b, c := v.login(uB, ""), v.login(uC, "")
	now := nowMs()
	v.push(b, now, []*Ent{
		ent("task-bpriv1", uB, true, now, map[string]any{"title": "приватная Боба"}),
		ent("task-bshare", uB, false, now, map[string]any{"title": "общая Боба", "assignee_id": uC}),
	}, []*Ent{ent("list-forbob", uB, false, now, map[string]any{"name": "список Боба", "assignee_id": uB})})
	v.push(c, now, []*Ent{ent("task-cforb1", uC, false, now, map[string]any{"title": "Клара поручила Бобу", "assignee_id": uB})},
		[]*Ent{ent("list-cforb1", uC, false, now, map[string]any{"name": "список Клары для Боба", "assignee_id": uB})})
	_, cur := v.pullIDs(c, 0)

	if code, r := v.req(v.admin, "DELETE", "/v1/admin/users/"+uB, nil); code != 200 {
		t.Fatalf("удаление: %d %v", code, r)
	}

	if v.get("task", "task-bpriv1") != nil {
		t.Error("приватные задачи удалённого пользователя должны удаляться")
	}
	if g := v.get("task", "task-bshare"); g.CreatorID != uA || g.S("assignee_id") != uC {
		t.Errorf("общая задача должна перейти к админу как к автору: %s / %s", g.CreatorID, g.S("assignee_id"))
	}
	if g := v.get("task", "task-cforb1"); g.S("assignee_id") != uA || g.CreatorID != uC {
		t.Errorf("исполнителем должен стать админ: %s", g.S("assignee_id"))
	}
	if g := v.get("list", "list-cforb1"); g.S("assignee_id") != "" || g.CreatorID != uC {
		t.Error("у списка поле исполнителя должно очиститься")
	}
	if g := v.get("list", "list-forbob"); g.CreatorID != uA || g.S("assignee_id") != "" {
		t.Error("список удалённого пользователя должен перейти к админу")
	}
	if ids, _ := v.pullIDs(c, cur); !has(ids, "task-bshare") || !has(ids, "task-cforb1") {
		t.Errorf("клиенты должны получить изменения: %v", ids)
	}
	// устройство удалённого пользователя перестаёт синхронизироваться
	if code, r := v.req(b, "GET", "/v1/changes?cursor=0", nil); code != 401 {
		t.Errorf("устройство удалённого пользователя: %d %v", code, r)
	}
}

func TestListsWithAssignee(t *testing.T) {
	v := newVPS(t)
	b, c := v.login(uB, ""), v.login(uC, "")
	now := nowMs()
	v.push(b, now, []*Ent{
		ent("task-move01", uB, false, now-9000, map[string]any{"title": "перенесу"}),
		ent("task-priv02", uB, true, now-9000, map[string]any{"title": "приватная"}),
	}, []*Ent{ent("list-clara1", uB, false, now-9000, map[string]any{"name": "для Клары", "assignee_id": uC})})

	// перенос в список с исполнителем: исполнитель задачи = исполнитель списка
	v.push(b, nowMs(), []*Ent{ent("task-move01", uB, false, nowMs()-100, map[string]any{"list_id": "list-clara1"})}, nil)
	if g := v.get("task", "task-move01"); g.S("assignee_id") != uC {
		t.Errorf("перенос в список: исполнитель %s", g.S("assignee_id"))
	}
	// быстрое добавление в такой список чужим пользователем
	v.push(c, nowMs(), []*Ent{ent("task-quick1", uC, false, nowMs()-100, map[string]any{"title": "быстрая", "list_id": "list-clara1", "assignee_id": uB})}, nil)
	if v.get("task", "task-quick1").S("assignee_id") != uC {
		t.Error("задача в списке с исполнителем должна ставиться на исполнителя списка")
	}
	// приватную задачу в список чужого исполнителя положить нельзя
	v.push(b, nowMs(), []*Ent{ent("task-priv02", uB, true, nowMs()-100, map[string]any{"list_id": "list-clara1"})}, nil)
	if v.get("task", "task-priv02").S("list_id") != "" {
		t.Error("приватная задача попала в список чужого исполнителя")
	}
	// смена исполнителя списка: все задачи переходят новому исполнителю
	v.push(b, nowMs(), nil, []*Ent{ent("list-clara1", uB, false, nowMs()-50, map[string]any{"assignee_id": uA})})
	for _, id := range []string{"task-move01", "task-quick1"} {
		if v.get("task", id).S("assignee_id") != uA {
			t.Errorf("%s: исполнитель не сменился вместе со списком", id)
		}
	}
	// менять список может только создатель
	v.push(c, nowMs(), nil, []*Ent{ent("list-clara1", uB, false, nowMs(), map[string]any{"name": "чужое имя"})})
	if v.get("list", "list-clara1").S("name") != "для Клары" {
		t.Error("список переименовал не создатель")
	}
	// удаление списка с переносом задач в общий раздел
	v.push(b, nowMs(), nil, []*Ent{ent("list-clara1", uB, false, nowMs(), map[string]any{"deleted": true, "delete_tasks": false})})
	if g := v.get("task", "task-move01"); g.S("list_id") != "" || g.B("deleted") {
		t.Error("задачи удалённого списка должны перейти в общий раздел")
	}
	// удаление списка вместе с задачами
	now = nowMs()
	v.push(b, now, []*Ent{ent("task-inlst2", uB, false, now-10, map[string]any{"title": "в списке", "list_id": "list-second"}),
		ent("task-sublst", uB, false, now-10, map[string]any{"title": "подзадача", "parent_id": "task-inlst2"})},
		[]*Ent{ent("list-second", uB, false, now-20, map[string]any{"name": "второй"})})
	if v.get("task", "task-sublst").S("list_id") != "list-second" {
		t.Error("подзадача должна наследовать список основной задачи")
	}
	v.push(b, nowMs(), nil, []*Ent{ent("list-second", uB, false, nowMs(), map[string]any{"deleted": true, "delete_tasks": true})})
	if !v.get("task", "task-inlst2").B("deleted") || !v.get("task", "task-sublst").B("deleted") {
		t.Error("задачи должны удалиться вместе со списком")
	}
}

func TestSubtasks(t *testing.T) {
	v := newVPS(t)
	b := v.login(uB, "")
	now := nowMs()
	v.push(b, now, []*Ent{
		ent("task-sub001", uB, false, now-5000, map[string]any{"title": "подзадача", "parent_id": "task-parent"}), // порядок в пачке не важен
		ent("task-parent", uB, false, now-5000, map[string]any{"title": "основная"}),
		ent("task-sub002", uB, false, now-5000, map[string]any{"title": "вложенная во вложенную", "parent_id": "task-sub001"}),
	}, nil)
	if v.get("task", "task-sub001").S("parent_id") != "task-parent" {
		t.Fatal("подзадача не привязалась")
	}
	if v.get("task", "task-sub002").S("parent_id") != "" {
		t.Error("допускается только один уровень вложенности")
	}
	// основную задачу нельзя закрыть, пока открыта подзадача
	r := v.push(b, nowMs(), []*Ent{ent("task-parent", uB, false, nowMs()-100, map[string]any{"status": "done"})}, nil)
	if v.get("task", "task-parent").Done() || len(r["rejected"].([]any)) != 1 {
		t.Error("основная задача закрылась при открытой подзадаче")
	}
	// закрытие подзадачи и основной одной пачкой проходит
	time.Sleep(30 * time.Millisecond)
	ts := nowMs()
	v.push(b, ts, []*Ent{ent("task-parent", uB, false, ts, map[string]any{"status": "done"}), ent("task-sub001", uB, false, ts-20, map[string]any{"status": "done"})}, nil)
	if !v.get("task", "task-parent").Done() {
		t.Error("основная задача не закрылась вместе с подзадачей")
	}
	// удаление основной удаляет подзадачи
	v.push(b, nowMs(), []*Ent{ent("task-parent", uB, false, nowMs(), map[string]any{"deleted": true})}, nil)
	if !v.get("task", "task-sub001").B("deleted") {
		t.Error("подзадача не удалилась вместе с основной")
	}
}

// Переезд: данные переливаются на новый сервер, старый начинает отдавать его адрес, токены устройств продолжают работать.
// Первый запуск: первый пользователь — администратор, повторно «первого» не создать.
func TestSetup(t *testing.T) {
	st, _ := Open(":memory:")
	sv := &Server{S: st, Cfg: Config{AccessKey: "key"}}
	ts := httptest.NewTLSServer(sv.Handler())
	t.Cleanup(func() { ts.Close(); st.Close() })
	v := &vps{sv: sv, ts: ts, t: t}
	if _, r := v.req("", "GET", "/v1/hello", nil); r["setup"] != true {
		t.Fatalf("пустой сервер должен предлагать настройку: %v", r)
	}
	if code, _ := v.req("", "POST", "/v1/setup", map[string]any{"name": "Аня", "password": ""}); code != 400 {
		t.Error("администратор без пароля создан")
	}
	code, r := v.req("", "POST", "/v1/setup", map[string]any{"name": "Аня", "password": "1234", "device": "test"})
	if code != 200 || r["token"] == "" {
		t.Fatalf("setup: %d %v", code, r)
	}
	if _, h := v.req("", "GET", "/v1/hello", nil); h["setup"] != false || len(h["users"].([]any)) != 1 || !h["users"].([]any)[0].(map[string]any)["is_admin"].(bool) {
		t.Errorf("после настройки: %v", h)
	}
	if code, _ := v.req("", "POST", "/v1/setup", map[string]any{"name": "Захватчик", "password": "1234"}); code != 400 {
		t.Error("второй «первый» пользователь создан")
	}
}

// Управление пользователями: только администратор; последний администратор остаётся; смена пароля.
func TestUserManagement(t *testing.T) {
	v := newVPS(t)
	b := v.login(uB, "")
	if code, _ := v.req(b, "POST", "/v1/admin/users", map[string]any{"name": "Взлом"}); code != 403 {
		t.Error("не администратор создал пользователя")
	}
	if code, _ := v.req(v.admin, "POST", "/v1/admin/users", map[string]any{"name": "боб"}); code != 400 {
		t.Error("создан пользователь с занятым именем")
	}
	if code, _ := v.req(v.admin, "POST", "/v1/admin/users", map[string]any{"name": "Короткий", "password": "12"}); code != 400 {
		t.Error("принят слишком короткий пароль")
	}
	// пароль Бобу: его устройства входят заново, вход без пароля больше не проходит
	if code, r := v.req(v.admin, "PATCH", "/v1/admin/users/"+uB, map[string]any{"password": "bob-pass", "name": "Борис"}); code != 200 {
		t.Fatalf("правка: %d %v", code, r)
	}
	if code, _ := v.req(b, "GET", "/v1/changes", nil); code != 401 {
		t.Error("после смены пароля старый токен устройства действует")
	}
	if code, _ := v.req("", "POST", "/v1/login", map[string]any{"user_id": uB, "password": ""}); code != 403 {
		t.Error("вход без пароля после установки пароля")
	}
	b = v.login(uB, "bob-pass")
	// сам Боб меняет пароль (нужен текущий)
	if code, _ := v.req(b, "POST", "/v1/me/password", map[string]any{"old": "нет", "new": "новый-пароль"}); code != 400 {
		t.Error("пароль сменён без верного текущего")
	}
	code, r := v.req(b, "POST", "/v1/me/password", map[string]any{"old": "bob-pass", "new": "новый-пароль"})
	if code != 200 || r["token"] == "" {
		t.Fatalf("смена своего пароля: %d %v", code, r)
	}
	if code, _ := v.req(r["token"].(string), "GET", "/v1/changes", nil); code != 200 {
		t.Error("после смены своего пароля новое устройство не работает")
	}
	// последнего администратора не разжаловать и не удалить, себя не удалить
	if code, _ := v.req(v.admin, "PATCH", "/v1/admin/users/"+uA, map[string]any{"is_admin": false}); code != 400 {
		t.Error("разжалован последний администратор")
	}
	if code, _ := v.req(v.admin, "DELETE", "/v1/admin/users/"+uA, nil); code != 400 {
		t.Error("администратор удалил сам себя")
	}
	// второй администратор: теперь первого можно разжаловать
	if code, _ := v.req(v.admin, "PATCH", "/v1/admin/users/"+uC, map[string]any{"is_admin": true}); code != 400 {
		t.Error("администратор без пароля назначен")
	}
	v.req(v.admin, "PATCH", "/v1/admin/users/"+uC, map[string]any{"is_admin": true, "password": "clara"})
	if code, _ := v.req(v.admin, "PATCH", "/v1/admin/users/"+uA, map[string]any{"is_admin": false}); code != 200 {
		t.Error("при втором администраторе первого разжаловать можно")
	}
	// имя и флаги видны всем в списке пользователей
	_, h := v.req("", "GET", "/v1/hello", nil)
	names := []string{}
	for _, x := range h["users"].([]any) {
		u := x.(map[string]any)
		names = append(names, fmt.Sprintf("%s:%v:%v", u["name"], u["is_admin"], u["has_password"]))
	}
	if strings.Join(names, " ") != "Админ:false:true Борис:false:true Клара:true:true" {
		t.Errorf("пользователи: %v", names)
	}
}

// Без ключа доступа API молчит; веб-клиент отдаётся без ключа.
func TestAccessKeyAndWeb(t *testing.T) {
	v := newVPS(t)
	req, _ := http.NewRequest("GET", v.ts.URL+"/v1/hello", nil)
	if resp, err := v.ts.Client().Do(req); err == nil {
		resp.Body.Close()
		t.Error("API ответил без ключа доступа")
	}
	req, _ = http.NewRequest("GET", v.ts.URL+"/v1/hello", nil)
	req.Header.Set("X-Access-Key", "wrong")
	if resp, err := v.ts.Client().Do(req); err == nil {
		resp.Body.Close()
		t.Error("API ответил с неверным ключом")
	}
	for _, p := range []string{"/", "/some/deep/link"} {
		resp, err := v.ts.Client().Get(v.ts.URL + p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 || !strings.Contains(string(body), "<") {
			t.Errorf("веб-клиент %s: %d", p, resp.StatusCode)
		}
	}
	if code, _ := v.req("", "GET", "/v1/changes", nil); code != 401 {
		t.Error("данные без входа")
	}
	if code, r := v.req(v.admin, "GET", "/v1/admin/connect-info", nil); code != 200 || r["key"] != "key."+v.sv.Pin {
		t.Errorf("данные подключения: %v", r)
	}
}

// Закрытие задачи снимает срок и повторение (у исполнителя — тоже, хотя сам он срок менять не вправе).
func TestCloseClearsDeadline(t *testing.T) {
	v := newVPS(t)
	b, c := v.login(uB, ""), v.login(uC, "")
	now := nowMs()
	v.push(b, now, []*Ent{ent("task-close1", uB, false, now-100, map[string]any{"title": "x", "assignee_id": uC, "deadline": "2030-01-01", "recurrence": map[string]any{"type": "daily"}})}, nil)
	v.push(c, nowMs(), []*Ent{ent("task-close1", uB, false, nowMs(), map[string]any{"status": "done"})}, nil)
	if g := v.get("task", "task-close1"); !g.Done() || g.S("deadline") != "" || g.F["recurrence"] != nil {
		t.Errorf("закрыта %v, срок %q, повторение %v", g.Done(), g.S("deadline"), g.F["recurrence"])
	}
}

// Пункты планирования ставит и исполнитель; неправильные пункты отбрасываются, закрытие убирает будущие.
func TestPlans(t *testing.T) {
	v := newVPS(t)
	b, c := v.login(uB, ""), v.login(uC, "")
	now := nowMs()
	v.push(b, now, []*Ent{ent("task-plan01", uB, false, now-100, map[string]any{"title": "x", "assignee_id": uC})}, nil)
	today := time.Now().Format("2006-01-02")
	future := time.Now().Add(72 * time.Hour).Format("2006-01-02")
	time.Sleep(3 * time.Millisecond)
	v.push(c, nowMs(), []*Ent{ent("task-plan01", uB, false, nowMs(), map[string]any{"plans": []any{
		map[string]any{"id": "a1", "date": today, "from": float64(540), "to": float64(600), "notify": true, "before": float64(60)},
		map[string]any{"id": "a2", "date": future},
		map[string]any{"id": "a3", "date": "вчера"},
		map[string]any{"id": "a4", "date": future, "from": float64(600), "to": float64(500)},
	}})}, nil)
	g := v.get("task", "task-plan01")
	items, _ := g.F["plans"].([]any)
	if len(items) != 3 {
		t.Fatalf("пункты планирования: %v", g.F["plans"])
	}
	if _, has := items[2].(map[string]any)["from"]; has {
		t.Errorf("пункт с концом раньше начала должен стать пунктом без времени: %v", items[2])
	}
	time.Sleep(3 * time.Millisecond)
	v.push(c, nowMs(), []*Ent{ent("task-plan01", uB, false, nowMs(), map[string]any{"status": "done"})}, nil)
	g = v.get("task", "task-plan01")
	if items, _ := g.F["plans"].([]any); len(items) != 1 || items[0].(map[string]any)["id"] != "a1" {
		t.Errorf("у закрытой задачи остались пункты на следующие дни: %v", g.F["plans"])
	}
}

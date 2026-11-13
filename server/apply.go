package todo

import (
	"database/sql"
	"reflect"
	"sort"
	"time"
)

// Actor — от чьего имени применяется правка.
type Actor struct {
	Service bool   // внутренние правки сервера (удаление пользователя): можно всё, видно всё
	UserID  string // обычный пользователь
	Admin   bool   // у пользователя включён «режим администратора»
}

func (a Actor) visible(e *Ent) bool {
	return a.Service || !e.IsPrivate || e.CreatorID == a.UserID
}
func (a Actor) allowed(e *Ent, k string) bool {
	if a.Service || a.Admin || e.CreatorID == a.UserID {
		return true
	}
	// исполнитель может закрыть/переоткрыть задачу и добавить её в «Сегодня»
	if e.Kind == "task" && e.S("assignee_id") == a.UserID {
		return k == "status" || k == "in_today" || k == "plans"
	}
	return false
}

// Applier применяет пачку правок в одной транзакции.
type Applier struct {
	s        *Store
	tx       *sql.Tx
	a        Actor
	now      int64
	offset   int64 // поправка часов отправителя: время сервера минус время клиента
	Touched  map[string]*Ent
	Rejected map[string]bool
	newDone  []string
	users    map[string]bool
}

func (s *Store) NewApplier(tx *sql.Tx, a Actor, clientNow int64) *Applier {
	now := nowMs()
	ap := &Applier{s: s, tx: tx, a: a, now: now, Touched: map[string]*Ent{}, Rejected: map[string]bool{}, users: map[string]bool{}}
	if clientNow > 0 {
		ap.offset = now - clientNow
	}
	rows, _ := tx.Query(`SELECT id FROM users`)
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ap.users[id] = true
	}
	rows.Close()
	return ap
}

// adj переводит время правки в часы сервера; время из будущего обрезается.
func (ap *Applier) adj(t int64) int64 {
	if t <= 0 {
		return ap.now
	}
	t += ap.offset
	if t > ap.now {
		t = ap.now
	}
	return t
}
func (ap *Applier) set(e *Ent, k string, v any, ts int64) bool {
	if reflect.DeepEqual(e.F[k], v) && e.T[k] == ts {
		return false
	}
	e.F[k], e.T[k] = v, ts
	return true
}

// force — значение, навязанное правилами сервера (время правки = сейчас).
func (ap *Applier) force(e *Ent, k string, v any) bool {
	if reflect.DeepEqual(e.F[k], v) {
		return false
	}
	return ap.set(e, k, v, ap.now)
}
func (ap *Applier) save(e *Ent) error {
	if err := ap.s.saveEnt(ap.tx, e, ap.now); err != nil {
		return err
	}
	ap.Touched[e.Kind+":"+e.ID] = e
	return nil
}

func (ap *Applier) canCreate(kind string, in *Ent) bool {
	if ap.a.Service {
		return true
	}
	if !ap.users[in.CreatorID] {
		return false
	}
	if in.CreatorID == ap.a.UserID {
		return true
	}
	if kind == "task" && in.IsPrivate {
		return false
	}
	// задачу чужого авторства может прислать её исполнитель (следующий экземпляр регулярной
	// задачи, восстановление очищенной) или администратор в режиме администратора
	if ap.a.Admin {
		return true
	}
	as, _ := in.F["assignee_id"].(string)
	return kind == "task" && as == ap.a.UserID
}

// Apply — одна задача или список от клиента.
func (ap *Applier) Apply(kind string, in *Ent) error {
	if in == nil || !idRe.MatchString(in.ID) {
		return nil
	}
	in.Kind = kind
	fields := fieldsOf(kind)
	cur := loadEnt(ap.tx, kind, in.ID)
	var before *Ent
	if cur == nil {
		if !ap.canCreate(kind, in) {
			ap.Rejected[in.ID] = true
			return nil
		}
		cur = &Ent{Kind: kind, ID: in.ID, CreatorID: in.CreatorID, IsPrivate: kind == "task" && in.IsPrivate, CreatedAt: ap.adj(in.CreatedAt)}
		if !ap.users[cur.CreatorID] {
			cur.CreatorID = adminID(ap.tx, "")
		}
		cur.fillDefaults()
		for k, typ := range fields {
			if v, ok := in.F[k]; ok {
				if cv, ok := cleanVal(k, typ, v); ok {
					cur.F[k] = cv
					if in.T[k] > 0 { // поле без времени правки — значение по умолчанию, его перекроет любая правка
						cur.T[k] = ap.adj(in.T[k])
					}
				}
			}
		}
	} else {
		if !ap.a.visible(cur) {
			ap.Rejected[in.ID] = true
			return nil
		}
		before = cur.clone()
		for _, k := range in.D {
			typ, ok := fields[k]
			if !ok {
				continue
			}
			v, has := in.F[k]
			if !has {
				continue
			}
			cv, ok := cleanVal(k, typ, v)
			if !ok {
				continue
			}
			if !ap.a.allowed(cur, k) {
				ap.Rejected[in.ID] = true
				continue
			}
			if ts := ap.adj(in.T[k]); ts > cur.T[k] {
				ap.set(cur, k, cv, ts)
			}
		}
	}
	if kind == "task" {
		ap.normalizeTask(cur, before)
	} else {
		ap.normalizeList(cur)
	}
	if before == nil || !sameEnt(before, cur) {
		if err := ap.save(cur); err != nil {
			return err
		}
	} else {
		ap.Touched[kind+":"+cur.ID] = cur
	}
	if kind == "task" {
		return ap.cascadeTask(cur, before)
	}
	return ap.cascadeList(cur, before)
}

func (ap *Applier) openChildren(id string) int {
	var n int
	ap.tx.QueryRow(`SELECT COUNT(*) FROM ents WHERE kind='task' AND parent_id=? AND deleted=0 AND done=0`, id).Scan(&n)
	return n
}
func (ap *Applier) hasChildren(id string) bool {
	var n int
	ap.tx.QueryRow(`SELECT COUNT(*) FROM ents WHERE kind='task' AND parent_id=? AND deleted=0`, id).Scan(&n)
	return n > 0
}

// normalizeTask приводит задачу в соответствие с правилами раздела 6 ТЗ.
func (ap *Applier) normalizeTask(e *Ent, before *Ent) {
	// подзадача: один уровень, та же приватность и тот же список, что у основной
	if pid := e.S("parent_id"); pid != "" {
		p := loadEnt(ap.tx, "task", pid)
		switch {
		case p == nil, pid == e.ID, p.S("parent_id") != "", p.IsPrivate != e.IsPrivate,
			p.IsPrivate && p.CreatorID != e.CreatorID, ap.hasChildren(e.ID):
			ap.force(e, "parent_id", "")
		default:
			ap.force(e, "list_id", p.S("list_id"))
		}
	}
	// список: должен существовать; список с исполнителем назначает исполнителя задаче
	if lid := e.S("list_id"); lid != "" {
		l := loadEnt(ap.tx, "list", lid)
		if l == nil || l.B("deleted") {
			ap.force(e, "list_id", "")
		} else if la := l.S("assignee_id"); la != "" {
			if e.IsPrivate && la != e.CreatorID {
				// приватную задачу нельзя держать в списке чужого исполнителя
				old := ""
				if before != nil && before.S("list_id") != lid {
					old = before.S("list_id")
				}
				ap.force(e, "list_id", old)
			} else {
				ap.force(e, "assignee_id", la)
			}
		}
	}
	if e.IsPrivate {
		ap.force(e, "assignee_id", e.CreatorID)
	}
	if !ap.users[e.S("assignee_id")] {
		ap.force(e, "assignee_id", e.CreatorID)
	}

	if e.Done() && (before == nil || !before.Done()) {
		ap.newDone = append(ap.newDone, e.ID)
	}
}

func (ap *Applier) normalizeList(l *Ent) {
	if as := l.S("assignee_id"); as != "" && !ap.users[as] {
		ap.force(l, "assignee_id", "")
	}
}

// renorm повторно применяет правила к задаче после изменения её списка или основной задачи.
func (ap *Applier) renorm(t *Ent, mutate func(*Ent)) error {
	before := t.clone()
	if mutate != nil {
		mutate(t)
	}
	ap.normalizeTask(t, before)
	if sameEnt(before, t) {
		return nil
	}
	if err := ap.save(t); err != nil {
		return err
	}
	return ap.cascadeTask(t, before)
}

func (ap *Applier) cascadeTask(e *Ent, before *Ent) error {
	delNow := e.B("deleted") && (before == nil || !before.B("deleted"))
	listCh := before != nil && before.S("list_id") != e.S("list_id")
	if !delNow && !listCh {
		return nil
	}
	for _, c := range queryEnts(ap.tx, `kind='task' AND parent_id=? AND deleted=0`, e.ID) {
		if err := ap.renorm(c, func(c *Ent) {
			if delNow {
				ap.force(c, "deleted", true) // подзадачи удаляются вместе с основной
			}
		}); err != nil {
			return err
		}
	}
	return nil
}

func (ap *Applier) cascadeList(l *Ent, before *Ent) error {
	delNow := l.B("deleted") && (before == nil || !before.B("deleted"))
	asCh := before != nil && before.S("assignee_id") != l.S("assignee_id")
	if !delNow && !asCh {
		return nil
	}
	tasks := queryEnts(ap.tx, `kind='task' AND list_id=? AND deleted=0`, l.ID)
	// сначала основные задачи: подзадачи подтянутся каскадом
	sort.SliceStable(tasks, func(i, j int) bool { return tasks[i].S("parent_id") == "" && tasks[j].S("parent_id") != "" })
	for _, t := range tasks {
		t = loadEnt(ap.tx, "task", t.ID) // могла измениться каскадом от основной
		if t == nil || t.B("deleted") || t.S("list_id") != l.ID {
			continue
		}
		if err := ap.renorm(t, func(t *Ent) {
			if delNow {
				// «удалить задачи»: чужие приватные задачи не трогаем, а переносим в общий раздел
				if l.B("delete_tasks") && (!t.IsPrivate || t.CreatorID == l.CreatorID) {
					ap.force(t, "deleted", true)
				} else if t.S("parent_id") == "" {
					ap.force(t, "list_id", "")
				}
			}
		}); err != nil {
			return err
		}
	}
	return nil
}

// Finish — проверки, которым нужна вся пачка целиком: основную задачу нельзя закрыть,
// пока открыты подзадачи (подзадачи могли прийти в той же пачке).
func (ap *Applier) Finish() error {
	for _, id := range ap.newDone {
		e := loadEnt(ap.tx, "task", id)
		if e == nil || !e.Done() || e.B("deleted") {
			continue
		}
		if ap.openChildren(id) > 0 {
			ap.force(e, "status", "open")
			ap.Rejected[id] = true
		} else {
			// закрытая задача теряет срок (и повторение, которому срок нужен): переоткрытая,
			// она ведёт себя как новая. Делается здесь, потому что исполнитель сам менять срок не вправе.
			a := e.S("deadline") != "" && ap.force(e, "deadline", "")
			b := e.F["recurrence"] != nil && ap.force(e, "recurrence", nil)
			// пункты планирования на следующие дни у закрытой задачи больше не нужны
			c := false
			if items, ok := e.F["plans"].([]any); ok {
				today := time.Now().In(location(ap.tx)).Format("2006-01-02")
				keep := []any{}
				for _, x := range items {
					if m, ok := x.(map[string]any); ok {
						if d, _ := m["date"].(string); d > today {
							continue
						}
					}
					keep = append(keep, x)
				}
				c = len(keep) != len(items) && ap.force(e, "plans", keep)
			}
			if !a && !b && !c {
				continue
			}
		}
		if err := ap.save(e); err != nil {
			return err
		}
	}
	ap.newDone = nil
	return nil
}

// ---- выдача изменений ----

type Changes struct {
	Tasks  []*Ent `json:"tasks"`
	Lists  []*Ent `json:"lists"`
	Cursor int64  `json:"cursor"`
	More   bool   `json:"more"`
}

const pullLimit = 500

func pull(tx *sql.Tx, a Actor, cursor int64) *Changes {
	where, args := `rev>?`, []any{cursor}
	if !a.Service {
		where += ` AND (is_private=0 OR creator_id=?)`
		args = append(args, a.UserID)
	}
	ents := queryEnts(tx, where+` ORDER BY rev LIMIT `+itoa(pullLimit+1), args...)
	ch := &Changes{Tasks: []*Ent{}, Lists: []*Ent{}}
	if len(ents) > pullLimit {
		ents = ents[:pullLimit]
		ch.More = true
		ch.Cursor = ents[len(ents)-1].Rev
	} else {
		ch.Cursor = metaInt(tx, "rev")
	}
	for _, e := range ents {
		e.D = nil
		if e.Kind == "list" {
			ch.Lists = append(ch.Lists, e)
		} else {
			ch.Tasks = append(ch.Tasks, e)
		}
	}
	return ch
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	return s
}

// touchedFor — итоговые версии затронутых записей, видимые отправителю.
func (ap *Applier) touchedFor() (tasks, lists []*Ent) {
	tasks, lists = []*Ent{}, []*Ent{}
	keys := make([]string, 0, len(ap.Touched))
	for k := range ap.Touched {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		e := ap.Touched[k]
		if !ap.a.visible(e) {
			continue
		}
		c := e.clone()
		c.D = nil
		if e.Kind == "list" {
			lists = append(lists, c)
		} else {
			tasks = append(tasks, c)
		}
	}
	return
}

// ---- очистка ----

// Purge удаляет завершённые задачи старше срока жизни (без пометок удаления: клиенты
// об этом не узнают и держат задачу в своём архиве) и старые пометки удаления.
func (s *Store) Purge() (purged int64, err error) {
	err = s.Tx(func(tx *sql.Tx) error {
		now := nowMs()
		r, e := tx.Exec(`DELETE FROM ents WHERE kind='task' AND done=1 AND completed_at>0 AND completed_at<?`, now-retentionDays(tx)*86400000)
		if e != nil {
			return e
		}
		purged, _ = r.RowsAffected()
		_, e = tx.Exec(`DELETE FROM ents WHERE deleted=1 AND updated_at<?`, now-tombstoneDays*86400000)
		tx.Exec(`DELETE FROM login_fails WHERE until<? AND at<?`, now/1000, now/1000-600)
		return e
	})
	return
}

const tombstoneDays = 180

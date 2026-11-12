// todod — сервер таск-трекера: база, синхронизация, пользователи и веб-клиент в одном файле.
//
//	todod init [-dir каталог] [-port 8443] [-proxy] [-public-url адрес]   первая настройка
//	todod -config <каталог>/config.json                                  запуск
//	todod info -config ...                       адрес и ключ доступа для подключения
//	todod passwd <имя> <новый пароль> -config ...   сменить пароль пользователя (если забыт)
//	todod backup <файл> -config ...              согласованная копия базы (сервер можно не останавливать)
//	todod new-epoch -config ...                  после восстановления из копии: клиенты заберут всё заново
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	_ "time/tzdata"

	"todo"
)

func pinOf(certFile string) (string, error) {
	raw, err := os.ReadFile(certFile)
	if err != nil {
		return "", err
	}
	blk, _ := pem.Decode(raw)
	if blk == nil {
		return "", fmt.Errorf("%s: не PEM", certFile)
	}
	cert, err := x509.ParseCertificate(blk.Bytes)
	if err != nil {
		return "", err
	}
	return todo.SPKIPin(cert), nil
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func usage() {
	fmt.Fprint(os.Stderr, `todod — сервер таск-трекера

  todod init [-dir /etc/todod] [-data /var/lib/todod] [-port 8443] [-proxy] [-public-url https://адрес]
        создать настройки, ключ доступа и сертификат; напечатать данные для подключения
  todod -config /etc/todod/config.json
        запустить сервер
  todod info -config ...                   данные для подключения
  todod passwd <имя> <пароль> -config ...  сменить пароль пользователя
  todod backup <файл> -config ...          копия базы
  todod new-epoch -config ...              после восстановления базы из копии
`)
}

func loadConfig(path string) (todo.Config, error) {
	var cfg todo.Config
	raw, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, fmt.Errorf("%s: %v", path, err)
	}
	// относительные пути — от каталога с настройками
	dir := filepath.Dir(path)
	for _, p := range []*string{&cfg.DB, &cfg.Cert, &cfg.Key} {
		if *p != "" && !filepath.IsAbs(*p) {
			*p = filepath.Join(dir, *p)
		}
	}
	if cfg.AccessKey == "" {
		return cfg, fmt.Errorf("%s: не задан access_key", path)
	}
	if cfg.Listen == "" {
		cfg.Listen = ":8443"
	}
	return cfg, nil
}

func main() {
	log.SetFlags(log.LstdFlags)
	cmd := ""
	var args []string
	if len(os.Args) >= 2 && !strings.HasPrefix(os.Args[1], "-") {
		cmd = os.Args[1]
		rest := os.Args[2:]
		// позиционные аргументы команды идут до флагов
		for len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
			args = append(args, rest[0])
			rest = rest[1:]
		}
		os.Args = append(os.Args[:1], rest...)
	}
	switch cmd {
	case "init":
		cmdInit()
		return
	case "pin":
		if len(args) < 1 {
			usage()
			os.Exit(2)
		}
		p, err := pinOf(args[0])
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println(p)
		return
	case "", "info", "passwd", "backup", "new-epoch":
	case "help", "-h", "--help":
		usage()
		return
	default:
		usage()
		os.Exit(2)
	}

	cfgPath := flag.String("config", "/etc/todod/config.json", "файл настроек")
	flag.Usage = usage
	flag.Parse()
	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatal(err)
	}
	sv := &todo.Server{Cfg: cfg, Web: todo.WebHandler()}
	if cfg.TLS() {
		if sv.Pin, err = pinOf(cfg.Cert); err != nil {
			log.Fatal(err)
		}
	}
	if cmd == "info" {
		printInfo(sv)
		return
	}
	st, err := todo.Open(cfg.DB)
	if err != nil {
		log.Fatal(err)
	}
	sv.S = st
	switch cmd {
	case "backup":
		if len(args) < 1 {
			log.Fatal("укажите файл: todod backup <файл>")
		}
		if err := st.Backup(args[0]); err != nil {
			log.Fatal(err)
		}
		fmt.Println("ok")
		return
	case "new-epoch":
		st.MetaSet("epoch", fmt.Sprintf("%x", time.Now().UnixNano()))
		fmt.Println("ok")
		return
	case "passwd":
		if len(args) < 2 {
			log.Fatal("укажите имя и пароль: todod passwd <имя> <пароль>")
		}
		if err := st.Tx(func(tx *sql.Tx) error { return st.SetPasswordByName(tx, args[0], args[1]) }); err != nil {
			log.Fatal(err)
		}
		fmt.Println("пароль изменён")
		return
	}

	go func() {
		for {
			if n, err := st.Purge(); err != nil {
				log.Printf("очистка: %v", err)
			} else if n > 0 {
				log.Printf("очистка: удалено завершённых задач: %d", n)
			}
			time.Sleep(time.Hour)
		}
	}()
	srv := &http.Server{Addr: cfg.Listen, Handler: sv.Handler(), ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout: 60 * time.Second, WriteTimeout: 120 * time.Second, IdleTimeout: 60 * time.Second,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}, ErrorLog: log.New(discard{}, "", 0)}
	if cfg.TLS() {
		log.Printf("todod: HTTPS, слушает %s", cfg.Listen)
		log.Fatal(srv.ListenAndServeTLS(cfg.Cert, cfg.Key))
	}
	log.Printf("todod: HTTP (за обратным прокси), слушает %s", cfg.Listen)
	log.Fatal(srv.ListenAndServe())
}

func printInfo(sv *todo.Server) {
	url := sv.Cfg.PublicURL
	if url == "" {
		url = "https://<адрес сервера>" + portSuffix(sv.Cfg.Listen)
	}
	fmt.Printf(`
Сервер готов. Данные для подключения:

  Адрес сервера:  %s
  Ключ доступа:   %s

Откройте приложение, введите адрес и ключ — первый вошедший станет администратором.
Веб-версия открывается по тому же адресу в браузере.
`, url, sv.ConnectKey())
	if sv.Pin != "" {
		fmt.Println("Сертификат самоподписанный: браузер при первом входе покажет предупреждение — это ожидаемо.")
	}
}

func portSuffix(listen string) string {
	_, port, err := net.SplitHostPort(listen)
	if err != nil || port == "443" || port == "" {
		return ""
	}
	return ":" + port
}

// cmdInit создаёт каталог настроек: config.json, ключ доступа и (без -proxy) самоподписанный сертификат.
// Существующие файлы не перезаписываются: повторный запуск просто печатает данные для подключения.
func cmdInit() {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	dir := fs.String("dir", "/etc/todod", "каталог для настроек и ключей")
	data := fs.String("data", "/var/lib/todod", "каталог для базы")
	port := fs.Int("port", 8443, "порт (для HTTPS со своим сертификатом)")
	proxy := fs.Bool("proxy", false, "сервер за обратным прокси (Caddy, nginx): слушать HTTP на 127.0.0.1:8080")
	public := fs.String("public-url", "", "адрес, по которому сервер видят пользователи (https://...)")
	fs.Parse(os.Args[1:])

	if err := os.MkdirAll(*dir, 0o750); err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(*data, 0o750); err != nil {
		log.Fatal(err)
	}
	cfgPath := filepath.Join(*dir, "config.json")
	if _, err := os.Stat(cfgPath); err != nil {
		cfg := todo.Config{DB: filepath.Join(*data, "todo.sqlite"), AccessKey: randHex(16), PublicURL: strings.TrimRight(*public, "/")}
		if *proxy {
			cfg.Listen, cfg.TrustProxy = "127.0.0.1:8080", true
		} else {
			cfg.Listen = fmt.Sprintf(":%d", *port)
			cfg.Cert, cfg.Key = filepath.Join(*dir, "cert.pem"), filepath.Join(*dir, "key.pem")
			if err := genCert(*dir); err != nil {
				log.Fatal(err)
			}
		}
		raw, _ := json.MarshalIndent(cfg, "", "  ")
		if err := os.WriteFile(cfgPath, append(raw, '\n'), 0o600); err != nil {
			log.Fatal(err)
		}
		fmt.Println("Настройки созданы:", cfgPath)
	} else {
		fmt.Println("Настройки уже есть:", cfgPath)
	}
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		log.Fatal(err)
	}
	sv := &todo.Server{Cfg: cfg}
	if cfg.TLS() {
		if sv.Pin, err = pinOf(cfg.Cert); err != nil {
			log.Fatal(err)
		}
	}
	printInfo(sv)
}

// genCert создаёт в каталоге key.pem и cert.pem (ECDSA P-256, самоподписанный, на 30 лет), если их ещё нет.
func genCert(dir string) error {
	if _, err := os.Stat(filepath.Join(dir, "cert.pem")); err == nil {
		return nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: "todo-server"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(30, 0, 0),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return err
	}
	kb, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "key.pem"), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "cert.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
}

// журнал ошибок TLS-рукопожатий от сканеров интернета не нужен
type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

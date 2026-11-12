package todo

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
)

// SPKIPin — отпечаток открытого ключа сертификата: base64url(SHA-256(SubjectPublicKeyInfo)).
// Приложения проверяют именно его, а не имя хоста: самоподписанный сертификат работает
// по любому адресу, а при смене адреса с той же ключевой парой ничего менять не нужно.
func SPKIPin(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

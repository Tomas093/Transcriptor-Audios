package main

import "strings"

func isDigit(b byte) bool { return b >= '0' && b <= '9' }

func splitDigits(s string) (digits, rest string) {
	i := 0
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	return s[:i], s[i:]
}

// naturalLess ordena nombres como "audio2" < "audio10" y, por tanto, los audios de
// WhatsApp (PTT-20261002-WA0001.opus, ...) por su fecha/numeración.
func naturalLess(a, b string) bool {
	a, b = strings.ToLower(a), strings.ToLower(b)
	for a != "" && b != "" {
		if isDigit(a[0]) && isDigit(b[0]) {
			da, ra := splitDigits(a)
			db, rb := splitDigits(b)
			da, db = strings.TrimLeft(da, "0"), strings.TrimLeft(db, "0")
			if len(da) != len(db) {
				return len(da) < len(db)
			}
			if da != db {
				return da < db
			}
			a, b = ra, rb
			continue
		}
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		a, b = a[1:], b[1:]
	}
	return len(a) < len(b)
}

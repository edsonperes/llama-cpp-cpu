// Command llamagw is a tiny auth gateway that sits in front of llama-server.
//
// It listens on the public port (8080), authenticates browsers via a
// username/password login + session cookie, authenticates API clients via a
// per-user Bearer token, and reverse-proxies everything to an internal
// keyless llama-server (127.0.0.1:8081).
//
// Goals:
//   - The chat WebUI works after login with NO API key configured (the cookie
//     authorizes its /v1 calls), so the user never pastes a token in settings.
//   - Each user created by the admin gets their own token to use elsewhere
//     (n8n, Open WebUI, etc.) on the SAME base URL http://HOST:8080/v1.
//
// Pure standard library only (no external modules) -> fully static binary,
// no module downloads at build time.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

type User struct {
	Username string `json:"username"`
	PassHash string `json:"pass_hash"`
	Role     string `json:"role"` // "admin" or "user"
	Token    string `json:"token"`
	Created  string `json:"created"`
}

type Store struct {
	Users      []User      `json:"users"`
	SSHServers []SSHServer `json:"ssh_servers"`
}

// SSHServer is a named, saved SSH target so the AI can act on it by name
// (e.g. "server x") without credentials being repeated in the chat.
// Each server belongs to one user (Owner); users only see/use their own.
type SSHServer struct {
	Owner    string `json:"owner"`
	Name     string `json:"name"`
	Host     string `json:"host"`
	Port     string `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type session struct {
	Username string
	Role     string
	Expires  time.Time
}

type App struct {
	mu         sync.Mutex
	store      Store
	sessions   map[string]session
	authFile   string
	cookieName string
	sessionTTL time.Duration
	proxy      *httputil.ReverseProxy
	backend    *url.URL
	nowFn      func() time.Time // injectable for tests
}

// ---------------------------------------------------------------------------
// Password hashing (PBKDF2-HMAC-SHA256, implemented with stdlib only)
// ---------------------------------------------------------------------------

const pbkdf2Iter = 200000
const pbkdf2KeyLen = 32

func pbkdf2(password, salt []byte, iter, keyLen int) []byte {
	prf := hmac.New(sha256.New, password)
	hLen := prf.Size()
	numBlocks := (keyLen + hLen - 1) / hLen
	var dk []byte
	buf := make([]byte, 4)
	for block := 1; block <= numBlocks; block++ {
		prf.Reset()
		prf.Write(salt)
		buf[0] = byte(block >> 24)
		buf[1] = byte(block >> 16)
		buf[2] = byte(block >> 8)
		buf[3] = byte(block)
		prf.Write(buf)
		u := prf.Sum(nil)
		t := make([]byte, len(u))
		copy(t, u)
		for n := 2; n <= iter; n++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(nil)
			for x := range t {
				t[x] ^= u[x]
			}
		}
		dk = append(dk, t...)
	}
	return dk[:keyLen]
}

func hashPassword(password string) string {
	salt := randomBytes(16)
	dk := pbkdf2([]byte(password), salt, pbkdf2Iter, pbkdf2KeyLen)
	return fmt.Sprintf("pbkdf2_sha256$%d$%s$%s", pbkdf2Iter, hex.EncodeToString(salt), hex.EncodeToString(dk))
}

func verifyPassword(password, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2_sha256" {
		return false
	}
	var iter int
	if _, err := fmt.Sscanf(parts[1], "%d", &iter); err != nil || iter <= 0 {
		return false
	}
	salt, err := hex.DecodeString(parts[2])
	if err != nil {
		return false
	}
	want, err := hex.DecodeString(parts[3])
	if err != nil {
		return false
	}
	got := pbkdf2([]byte(password), salt, iter, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// ---------------------------------------------------------------------------
// Random helpers
// ---------------------------------------------------------------------------

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		log.Fatalf("crypto/rand failed: %v", err)
	}
	return b
}

func newToken() string   { return "sk-" + hex.EncodeToString(randomBytes(24)) }
func newSession() string { return hex.EncodeToString(randomBytes(32)) }

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

func NewApp(authFile string, backend *url.URL, adminUser, adminPass string, ttl time.Duration) (*App, error) {
	a := &App{
		sessions:   map[string]session{},
		authFile:   authFile,
		cookieName: "llamagw_session",
		sessionTTL: ttl,
		backend:    backend,
		nowFn:      time.Now,
	}
	if err := a.load(); err != nil {
		return nil, err
	}
	if err := a.ensureAdmin(adminUser, adminPass); err != nil {
		return nil, err
	}

	proxy := httputil.NewSingleHostReverseProxy(backend)
	proxy.FlushInterval = -1 // flush immediately -> SSE token streaming works
	orig := proxy.Director
	proxy.Director = func(r *http.Request) {
		orig(r)
		// Never leak the browser's credentials to the keyless backend.
		r.Header.Del("Authorization")
		r.Header.Del("Cookie")
		r.Host = backend.Host
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		io.WriteString(w, `{"error":{"message":"backend unavailable","type":"upstream_error"}}`)
	}
	a.proxy = proxy
	return a, nil
}

func (a *App) now() time.Time { return a.nowFn() }

// ---------------------------------------------------------------------------
// Store persistence
// ---------------------------------------------------------------------------

func (a *App) load() error {
	data, err := os.ReadFile(a.authFile)
	if err != nil {
		if os.IsNotExist(err) {
			a.store = Store{}
			return nil
		}
		return err
	}
	if len(data) == 0 {
		a.store = Store{}
		return nil
	}
	return json.Unmarshal(data, &a.store)
}

// save must be called with a.mu held.
func (a *App) save() error {
	if err := os.MkdirAll(filepath.Dir(a.authFile), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(&a.store, "", "  ")
	if err != nil {
		return err
	}
	tmp := a.authFile + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.authFile)
}

func (a *App) ensureAdmin(adminUser, adminPass string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, u := range a.store.Users {
		if u.Role == "admin" {
			return nil // an admin already exists; respect the stored file
		}
	}
	if adminUser == "" {
		adminUser = "admin"
	}
	if adminPass == "" {
		adminPass = "admin"
		log.Printf("WARNING: no admin password set, using 'admin'. Set GATEWAY_ADMIN_PASSWORD.")
	}
	a.store.Users = append(a.store.Users, User{
		Username: adminUser,
		PassHash: hashPassword(adminPass),
		Role:     "admin",
		Token:    newToken(),
		Created:  a.now().UTC().Format(time.RFC3339),
	})
	log.Printf("created initial admin user %q", adminUser)
	return a.save()
}

// ---------------------------------------------------------------------------
// Lookups (caller must hold a.mu unless noted)
// ---------------------------------------------------------------------------

func (a *App) userByName(name string) *User {
	for i := range a.store.Users {
		if a.store.Users[i].Username == name {
			return &a.store.Users[i]
		}
	}
	return nil
}

// serverForUser finds a saved server owned by a specific user (names are
// per-user, so two users can each have a "web1").
func (a *App) serverForUser(owner, name string) *SSHServer {
	for i := range a.store.SSHServers {
		if a.store.SSHServers[i].Owner == owner && strings.EqualFold(a.store.SSHServers[i].Name, name) {
			return &a.store.SSHServers[i]
		}
	}
	return nil
}

// currentUser returns the username behind a request, via Bearer token or
// session cookie (empty if neither identifies a user).
func (a *App) currentUser(r *http.Request) string {
	if tok := bearerToken(r); tok != "" {
		a.mu.Lock()
		u := a.userByToken(tok)
		a.mu.Unlock()
		if u != nil {
			return u.Username
		}
	}
	if s := a.sessionFromReq(r); s != nil {
		return s.Username
	}
	return ""
}

func (a *App) userByToken(token string) *User {
	if token == "" {
		return nil
	}
	for i := range a.store.Users {
		if subtle.ConstantTimeCompare([]byte(a.store.Users[i].Token), []byte(token)) == 1 {
			return &a.store.Users[i]
		}
	}
	return nil
}

func (a *App) countAdmins() int {
	n := 0
	for _, u := range a.store.Users {
		if u.Role == "admin" {
			n++
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

func (a *App) newSessionFor(u *User) string {
	sid := newSession()
	a.mu.Lock()
	a.sessions[sid] = session{Username: u.Username, Role: u.Role, Expires: a.now().Add(a.sessionTTL)}
	a.mu.Unlock()
	return sid
}

func (a *App) sessionFromReq(r *http.Request) *session {
	c, err := r.Cookie(a.cookieName)
	if err != nil {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[c.Value]
	if !ok {
		return nil
	}
	if a.now().After(s.Expires) {
		delete(a.sessions, c.Value)
		return nil
	}
	cp := s
	return &cp
}

func (a *App) dropSessionsFor(username string) {
	for sid, s := range a.sessions {
		if s.Username == username {
			delete(a.sessions, sid)
		}
	}
}

// ---------------------------------------------------------------------------
// HTTP dispatch
// ---------------------------------------------------------------------------

func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	switch {
	case p == "/health":
		// Public: reflects real backend health (502 while backend is down).
		a.proxy.ServeHTTP(w, r)
	case p == "/login":
		a.handleLogin(w, r)
	case p == "/logout":
		a.handleLogout(w, r)
	case strings.HasPrefix(p, "/gw/"):
		a.handleGW(w, r)
	case p == "/tools":
		a.handleTools(w, r)
	case p == "/v1" || strings.HasPrefix(p, "/v1/"):
		if a.apiAuthorized(r) {
			a.proxy.ServeHTTP(w, r)
		} else {
			a.writeJSON(w, http.StatusUnauthorized, map[string]any{
				"error": map[string]any{"message": "missing or invalid API key", "type": "auth_error"},
			})
		}
	default:
		// The WebUI and its supporting endpoints: require a browser session.
		if a.sessionFromReq(r) != nil {
			a.proxy.ServeHTTP(w, r)
			return
		}
		if r.Method == http.MethodGet && strings.Contains(r.Header.Get("Accept"), "text/html") {
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		a.writeJSON(w, http.StatusUnauthorized, map[string]any{
			"error": map[string]any{"message": "authentication required", "type": "auth_error"},
		})
	}
}

// apiAuthorized allows a request to /v1/* if it carries either a valid
// per-user Bearer token (API clients) or a valid session cookie (the WebUI).
func (a *App) apiAuthorized(r *http.Request) bool {
	if tok := bearerToken(r); tok != "" {
		a.mu.Lock()
		u := a.userByToken(tok)
		a.mu.Unlock()
		if u != nil {
			return true
		}
	}
	return a.sessionFromReq(r) != nil
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if h == "" {
		h = r.Header.Get("X-Api-Key")
		return strings.TrimSpace(h)
	}
	const pfx = "Bearer "
	if strings.HasPrefix(h, pfx) {
		return strings.TrimSpace(h[len(pfx):])
	}
	return strings.TrimSpace(h)
}

// ---------------------------------------------------------------------------
// Login / logout
// ---------------------------------------------------------------------------

func (a *App) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		// Already logged in? go to the app.
		if a.sessionFromReq(r) != nil {
			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
		a.renderLogin(w, http.StatusOK, "")
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		a.renderLogin(w, http.StatusBadRequest, "Requisição inválida.")
		return
	}
	username := strings.TrimSpace(r.FormValue("username"))
	password := r.FormValue("password")

	a.mu.Lock()
	u := a.userByName(username)
	var ok bool
	if u != nil {
		ok = verifyPassword(password, u.PassHash)
	}
	a.mu.Unlock()

	if !ok {
		a.renderLogin(w, http.StatusUnauthorized, "Usuário ou senha inválidos.")
		return
	}

	sid := a.newSessionFor(u)
	http.SetCookie(w, &http.Cookie{
		Name:     a.cookieName,
		Value:    sid,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(a.sessionTTL.Seconds()),
	})
	http.Redirect(w, r, "/", http.StatusFound)
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(a.cookieName); err == nil {
		a.mu.Lock()
		delete(a.sessions, c.Value)
		a.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{
		Name:     a.cookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
	http.Redirect(w, r, "/login", http.StatusFound)
}

// ---------------------------------------------------------------------------
// Gateway API (/gw/*)
// ---------------------------------------------------------------------------

func (a *App) handleGW(w http.ResponseWriter, r *http.Request) {
	sess := a.sessionFromReq(r)
	if sess == nil {
		a.writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "not logged in"})
		return
	}
	p := r.URL.Path

	switch {
	case p == "/gw/me" && r.Method == http.MethodGet:
		a.mu.Lock()
		token := ""
		if u := a.userByName(sess.Username); u != nil {
			token = u.Token
		}
		a.mu.Unlock()
		a.writeJSON(w, http.StatusOK, map[string]any{
			"username": sess.Username,
			"role":     sess.Role,
			"token":    token,
		})

	case p == "/gw/users":
		if sess.Role != "admin" {
			a.writeJSON(w, http.StatusForbidden, map[string]any{"error": "admin only"})
			return
		}
		switch r.Method {
		case http.MethodGet:
			a.listUsers(w)
		case http.MethodPost:
			if !sameSite(r) {
				a.writeJSON(w, http.StatusForbidden, map[string]any{"error": "cross-site request blocked"})
				return
			}
			a.createUser(w, r)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}

	case strings.HasPrefix(p, "/gw/users/"):
		if sess.Role != "admin" {
			a.writeJSON(w, http.StatusForbidden, map[string]any{"error": "admin only"})
			return
		}
		if !sameSite(r) {
			a.writeJSON(w, http.StatusForbidden, map[string]any{"error": "cross-site request blocked"})
			return
		}
		rest := strings.TrimPrefix(p, "/gw/users/")
		if strings.HasSuffix(rest, "/rotate") && r.Method == http.MethodPost {
			a.rotateToken(w, strings.TrimSuffix(rest, "/rotate"), sess)
			return
		}
		if r.Method == http.MethodDelete {
			a.deleteUser(w, rest, sess)
			return
		}
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)

	case p == "/gw/ssh-servers":
		// Any logged-in user manages their OWN servers (scoped by sess.Username).
		switch r.Method {
		case http.MethodGet:
			a.listSSHServers(w, sess.Username)
		case http.MethodPost:
			if !sameSite(r) {
				a.writeJSON(w, http.StatusForbidden, map[string]any{"error": "cross-site request blocked"})
				return
			}
			a.createSSHServer(w, r, sess.Username)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}

	case strings.HasPrefix(p, "/gw/ssh-servers/"):
		if !sameSite(r) {
			a.writeJSON(w, http.StatusForbidden, map[string]any{"error": "cross-site request blocked"})
			return
		}
		if r.Method == http.MethodDelete {
			a.deleteSSHServer(w, sess.Username, strings.TrimPrefix(p, "/gw/ssh-servers/"))
			return
		}
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)

	default:
		http.NotFound(w, r)
	}
}

type publicUser struct {
	Username string `json:"username"`
	Role     string `json:"role"`
	Token    string `json:"token"`
	Created  string `json:"created"`
}

func (a *App) listUsers(w http.ResponseWriter) {
	a.mu.Lock()
	out := make([]publicUser, 0, len(a.store.Users))
	for _, u := range a.store.Users {
		out = append(out, publicUser{u.Username, u.Role, u.Token, u.Created})
	}
	a.mu.Unlock()
	a.writeJSON(w, http.StatusOK, map[string]any{"users": out})
}

func (a *App) createUser(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Role     string `json:"role"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&body); err != nil {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "JSON inválido"})
		return
	}
	body.Username = strings.TrimSpace(body.Username)
	if !validUsername(body.Username) {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "usuário inválido (use 3-32 chars: letras, números, . _ -)"})
		return
	}
	if len(body.Password) < 4 {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "senha muito curta (mínimo 4 caracteres)"})
		return
	}
	role := body.Role
	if role != "admin" {
		role = "user"
	}

	a.mu.Lock()
	if a.userByName(body.Username) != nil {
		a.mu.Unlock()
		a.writeJSON(w, http.StatusConflict, map[string]any{"error": "usuário já existe"})
		return
	}
	u := User{
		Username: body.Username,
		PassHash: hashPassword(body.Password),
		Role:     role,
		Token:    newToken(),
		Created:  a.now().UTC().Format(time.RFC3339),
	}
	a.store.Users = append(a.store.Users, u)
	err := a.save()
	a.mu.Unlock()
	if err != nil {
		a.writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "falha ao salvar"})
		return
	}
	a.writeJSON(w, http.StatusCreated, publicUser{u.Username, u.Role, u.Token, u.Created})
}

func (a *App) deleteUser(w http.ResponseWriter, name string, sess *session) {
	if name == sess.Username {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "você não pode excluir a si mesmo"})
		return
	}
	a.mu.Lock()
	u := a.userByName(name)
	if u == nil {
		a.mu.Unlock()
		a.writeJSON(w, http.StatusNotFound, map[string]any{"error": "usuário não encontrado"})
		return
	}
	if u.Role == "admin" && a.countAdmins() <= 1 {
		a.mu.Unlock()
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "não é possível excluir o último admin"})
		return
	}
	filtered := a.store.Users[:0]
	for _, x := range a.store.Users {
		if x.Username != name {
			filtered = append(filtered, x)
		}
	}
	a.store.Users = filtered
	a.dropSessionsFor(name)
	err := a.save()
	a.mu.Unlock()
	if err != nil {
		a.writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "falha ao salvar"})
		return
	}
	a.writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *App) rotateToken(w http.ResponseWriter, name string, sess *session) {
	a.mu.Lock()
	u := a.userByName(name)
	if u == nil {
		a.mu.Unlock()
		a.writeJSON(w, http.StatusNotFound, map[string]any{"error": "usuário não encontrado"})
		return
	}
	u.Token = newToken()
	tok := u.Token
	err := a.save()
	a.mu.Unlock()
	if err != nil {
		a.writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "falha ao salvar"})
		return
	}
	a.writeJSON(w, http.StatusOK, map[string]any{"ok": true, "token": tok})
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Named SSH servers — each user manages their own; the ssh_exec tool resolves
// them by name, scoped to the calling user (one user never sees another's).
// ---------------------------------------------------------------------------

type publicSSHServer struct {
	Name     string `json:"name"`
	Host     string `json:"host"`
	Port     string `json:"port"`
	Username string `json:"username"`
}

func (a *App) listSSHServers(w http.ResponseWriter, owner string) {
	a.mu.Lock()
	out := make([]publicSSHServer, 0)
	for _, s := range a.store.SSHServers {
		if s.Owner == owner {
			out = append(out, publicSSHServer{s.Name, s.Host, s.Port, s.Username})
		}
	}
	a.mu.Unlock()
	a.writeJSON(w, http.StatusOK, map[string]any{"servers": out})
}

func (a *App) createSSHServer(w http.ResponseWriter, r *http.Request, owner string) {
	var body struct {
		Name     string `json:"name"`
		Host     string `json:"host"`
		Port     string `json:"port"`
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&body); err != nil {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "JSON inválido"})
		return
	}
	body.Name = strings.TrimSpace(body.Name)
	body.Host = strings.TrimSpace(body.Host)
	body.Username = strings.TrimSpace(body.Username)
	body.Port = strings.TrimSpace(body.Port)
	if body.Port == "" {
		body.Port = "22"
	}
	if !validServerName(body.Name) {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "nome inválido (1-40 chars: letras, números, . _ -)"})
		return
	}
	if body.Host == "" || body.Username == "" || body.Password == "" {
		a.writeJSON(w, http.StatusBadRequest, map[string]any{"error": "host, username e password são obrigatórios"})
		return
	}
	a.mu.Lock()
	if a.serverForUser(owner, body.Name) != nil {
		a.mu.Unlock()
		a.writeJSON(w, http.StatusConflict, map[string]any{"error": "você já tem um servidor com esse nome"})
		return
	}
	a.store.SSHServers = append(a.store.SSHServers, SSHServer{
		Owner: owner, Name: body.Name, Host: body.Host, Port: body.Port,
		Username: body.Username, Password: body.Password,
	})
	err := a.save()
	a.mu.Unlock()
	if err != nil {
		a.writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "falha ao salvar"})
		return
	}
	a.writeJSON(w, http.StatusCreated, publicSSHServer{body.Name, body.Host, body.Port, body.Username})
}

func (a *App) deleteSSHServer(w http.ResponseWriter, owner, name string) {
	a.mu.Lock()
	if a.serverForUser(owner, name) == nil {
		a.mu.Unlock()
		a.writeJSON(w, http.StatusNotFound, map[string]any{"error": "servidor não encontrado"})
		return
	}
	filtered := a.store.SSHServers[:0]
	for _, s := range a.store.SSHServers {
		if s.Owner == owner && strings.EqualFold(s.Name, name) {
			continue
		}
		filtered = append(filtered, s)
	}
	a.store.SSHServers = filtered
	err := a.save()
	a.mu.Unlock()
	if err != nil {
		a.writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "falha ao salvar"})
		return
	}
	a.writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func validServerName(s string) bool {
	if len(s) < 1 || len(s) > 40 {
		return false
	}
	for _, c := range s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

func validUsername(s string) bool {
	if len(s) < 3 || len(s) > 32 {
		return false
	}
	for _, c := range s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// sameSite is a light CSRF guard for state-changing /gw requests: the Origin
// (or Referer) host must match the request host.
func sameSite(r *http.Request) bool {
	host := r.Host
	if o := r.Header.Get("Origin"); o != "" {
		if u, err := url.Parse(o); err == nil {
			return u.Host == host
		}
		return false
	}
	if ref := r.Header.Get("Referer"); ref != "" {
		if u, err := url.Parse(ref); err == nil {
			return u.Host == host
		}
	}
	return false
}

func (a *App) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ---------------------------------------------------------------------------
// Built-in tools served to the WebUI (/tools): an SSH executor.
//
// The WebUI fetches built-in tools from GET /tools and executes them via
// POST /tools {tool, params}, expecting {plain_text_response} or {error}.
// We serve a single tool, ssh_exec, executed server-side here (a browser
// cannot open SSH). Available to every logged-in user.
// ---------------------------------------------------------------------------

func (a *App) sshToolInfo(owner string) map[string]any {
	a.mu.Lock()
	names := make([]string, 0)
	for _, s := range a.store.SSHServers {
		if s.Owner == owner {
			names = append(names, s.Name)
		}
	}
	a.mu.Unlock()

	desc := "Executa um comando shell num servidor via SSH e retorna stdout+stderr. "
	if len(names) > 0 {
		desc += "Para um servidor JÁ SALVO, passe APENAS o nome dele em 'server' e o 'command' — as credenciais já estão guardadas, então NÃO preencha host/username/password. Servidores salvos: " + strings.Join(names, ", ") + ". "
	}
	desc += "Para um servidor que NÃO está salvo, deixe 'server' vazio e informe host, username, password e command."

	return map[string]any{
		"display_name": "SSH",
		"tool":         "ssh_exec",
		"type":         "builtin",
		"permissions":  map[string]any{"write": true},
		"definition": map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        "ssh_exec",
				"description": desc,
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"server":   map[string]any{"type": "string", "description": "Nome de um servidor já salvo. Se preenchido, NÃO preencha host/username/password."},
						"host":     map[string]any{"type": "string", "description": "IP ou hostname (somente para servidor NÃO salvo)"},
						"port":     map[string]any{"type": "integer", "description": "Porta SSH (padrão 22)"},
						"username": map[string]any{"type": "string", "description": "Usuário SSH (somente para servidor NÃO salvo)"},
						"password": map[string]any{"type": "string", "description": "Senha SSH (somente para servidor NÃO salvo)"},
						"command":  map[string]any{"type": "string", "description": "Comando shell a executar no servidor"},
					},
					"required": []string{"command"},
				},
			},
		},
	}
}

func (a *App) handleTools(w http.ResponseWriter, r *http.Request) {
	if !a.apiAuthorized(r) {
		a.writeJSON(w, http.StatusUnauthorized, map[string]any{
			"error": map[string]any{"message": "authentication required", "type": "auth_error"},
		})
		return
	}
	user := a.currentUser(r)
	switch r.Method {
	case http.MethodGet:
		a.writeJSON(w, http.StatusOK, []map[string]any{a.sshToolInfo(user)})
	case http.MethodPost:
		var body struct {
			Tool   string         `json:"tool"`
			Params map[string]any `json:"params"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
			a.writeJSON(w, http.StatusOK, map[string]any{"error": "JSON inválido"})
			return
		}
		if body.Tool != "ssh_exec" {
			a.writeJSON(w, http.StatusOK, map[string]any{"error": "ferramenta desconhecida: " + body.Tool})
			return
		}
		// Resolve a saved server. The model sometimes puts the saved-server NAME
		// in `host` instead of `server`, so accept either. If a name was given in
		// `server` but isn't saved, return an actionable error instead of failing
		// later with "missing credentials".
		if body.Params == nil {
			body.Params = map[string]any{}
		}
		explicitServer := strings.TrimSpace(paramString(body.Params, "server"))
		hostVal := strings.TrimSpace(paramString(body.Params, "host"))

		var sHost, sPort, sUser, sPass string
		var resolved bool
		var saved []string
		a.mu.Lock()
		resolveName := explicitServer
		if resolveName == "" && hostVal != "" && a.serverForUser(user, hostVal) != nil {
			resolveName = hostVal // model put the saved name in `host`
		}
		if resolveName != "" {
			if srv := a.serverForUser(user, resolveName); srv != nil {
				sHost, sPort, sUser, sPass = srv.Host, srv.Port, srv.Username, srv.Password
				resolved = true
			} else {
				for _, s := range a.store.SSHServers {
					if s.Owner == user {
						saved = append(saved, s.Name)
					}
				}
			}
		}
		a.mu.Unlock()

		if resolved {
			body.Params["host"] = sHost
			body.Params["port"] = sPort
			body.Params["username"] = sUser
			body.Params["password"] = sPass
		} else if explicitServer != "" {
			msg := "o servidor '" + explicitServer + "' não está salvo na sua conta. "
			if len(saved) > 0 {
				msg += "Servidores salvos: " + strings.Join(saved, ", ") + ". Chame ssh_exec de novo com 'server' igual a um destes nomes (sem host/username/password)."
			} else {
				msg += "Você não tem servidores salvos — informe host, username, password e command."
			}
			a.writeJSON(w, http.StatusOK, map[string]any{"error": msg})
			return
		}
		out, err := sshExec(body.Params)
		if err != nil {
			a.writeJSON(w, http.StatusOK, map[string]any{"error": err.Error()})
			return
		}
		a.writeJSON(w, http.StatusOK, map[string]any{"plain_text_response": out})
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func paramString(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(x)
	default:
		return fmt.Sprintf("%v", x)
	}
}

// sshExec runs a command on a remote host over SSH using password auth, via
// sshpass + the openssh client. Returns combined stdout+stderr.
func sshExec(params map[string]any) (string, error) {
	host := strings.TrimSpace(paramString(params, "host"))
	user := strings.TrimSpace(paramString(params, "username"))
	pass := paramString(params, "password")
	command := paramString(params, "command")
	port := strings.TrimSpace(paramString(params, "port"))
	if port == "" {
		port = "22"
	}
	if host == "" || user == "" || pass == "" || command == "" {
		return "", fmt.Errorf("host, username, password e command são obrigatórios")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// sshpass -e reads the password from $SSHPASS (not argv, so it isn't
	// visible in the process list). Host keys are accepted automatically so
	// the AI can reach new hosts unattended (no MITM protection).
	args := []string{
		"-e", "ssh",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=15",
		"-o", "LogLevel=ERROR",
		"-p", port,
		user + "@" + host,
		command,
	}
	c := exec.CommandContext(ctx, "sshpass", args...)
	c.Env = append(os.Environ(), "SSHPASS="+pass)
	out, err := c.CombinedOutput()

	s := string(out)
	if len(s) > 100000 {
		s = s[:100000] + "\n...[saída truncada]"
	}
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("conexão/comando SSH excedeu o limite de 90s")
	}
	if err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			// ssh connected but ssh/remote command returned non-zero; the
			// combined output already explains why (e.g. "Permission denied").
			if strings.TrimSpace(s) == "" {
				s = "(sem saída) " + err.Error()
			}
			return s, nil
		}
		// Could not even launch sshpass (missing binary, etc.).
		return "", fmt.Errorf("falha ao executar ssh: %v %s", err, strings.TrimSpace(s))
	}
	return s, nil
}

// ---------------------------------------------------------------------------
// Login page
// ---------------------------------------------------------------------------

const loginPage = `<!DOCTYPE html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Entrar — llm</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
    background: radial-gradient(1200px 600px at 50% -10%, #1d2433 0%, #0b0e14 60%, #07090d 100%);
    color: #e6e9ef; padding: 24px;
  }
  .card {
    width: 100%; max-width: 380px; background: rgba(20,24,33,.85);
    border: 1px solid rgba(255,255,255,.08); border-radius: 16px; padding: 32px 28px;
    box-shadow: 0 20px 60px rgba(0,0,0,.5); backdrop-filter: blur(8px);
  }
  .logo { display: flex; align-items: center; justify-content: center; gap: 10px; margin-bottom: 22px; }
  .logo svg { width: 28px; height: 28px; color: #7aa2f7; }
  h1 { font-size: 20px; margin: 0; font-weight: 650; }
  p.sub { margin: 6px 0 22px; font-size: 13px; color: #9aa4b2; }
  label { display: block; font-size: 12px; color: #9aa4b2; margin: 14px 0 6px; }
  input {
    width: 100%; padding: 11px 13px; border-radius: 10px; font-size: 14px;
    background: #0e1219; border: 1px solid rgba(255,255,255,.1); color: #e6e9ef; outline: none;
  }
  input:focus { border-color: #7aa2f7; box-shadow: 0 0 0 3px rgba(122,162,247,.15); }
  button {
    width: 100%; margin-top: 22px; padding: 12px; border: 0; border-radius: 10px; cursor: pointer;
    font-size: 14px; font-weight: 600; color: #fff;
    background: linear-gradient(180deg, #6d8ef0, #4f6fd6);
  }
  button:hover { filter: brightness(1.07); }
  .err {
    margin-top: 16px; padding: 10px 12px; border-radius: 8px; font-size: 13px;
    background: rgba(239,68,68,.12); border: 1px solid rgba(239,68,68,.35); color: #fca5a5;
  }
  .foot { margin-top: 18px; font-size: 11px; color: #6b7280; text-align: center; }
</style>
</head>
<body>
  <form class="card" method="post" action="/login">
    <div class="logo">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
      <h1>Área Restrita</h1>
    </div>
    <label for="u">Usuário</label>
    <input id="u" name="username" autocomplete="username" autofocus required>
    <label for="p">Senha</label>
    <input id="p" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">Entrar</button>
    {{ERROR}}
    <div class="foot">Servidor de IA privado</div>
  </form>
</body>
</html>`

func (a *App) renderLogin(w http.ResponseWriter, status int, errMsg string) {
	block := ""
	if errMsg != "" {
		block = `<div class="err">` + errMsg + `</div>` // errMsg is a fixed internal string
	}
	html := strings.Replace(loginPage, "{{ERROR}}", block, 1)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	io.WriteString(w, html)
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	listen := env("LISTEN_ADDR", ":8080")
	backendStr := env("BACKEND_URL", "http://127.0.0.1:8081")
	authFile := env("AUTH_FILE", "/auth/users.json")
	adminUser := env("GATEWAY_ADMIN_USER", "admin")
	adminPass := env("GATEWAY_ADMIN_PASSWORD", "")
	ttlHours := 720
	if v := os.Getenv("SESSION_TTL_HOURS"); v != "" {
		fmt.Sscanf(v, "%d", &ttlHours)
	}

	backend, err := url.Parse(backendStr)
	if err != nil {
		log.Fatalf("invalid BACKEND_URL %q: %v", backendStr, err)
	}

	app, err := NewApp(authFile, backend, adminUser, adminPass, time.Duration(ttlHours)*time.Hour)
	if err != nil {
		log.Fatalf("init failed: %v", err)
	}

	srv := &http.Server{
		Addr:              listen,
		Handler:           app,
		ReadHeaderTimeout: 15 * time.Second,
	}
	log.Printf("llamagw listening on %s -> %s (auth file %s)", listen, backend, authFile)
	log.Fatal(srv.ListenAndServe())
}

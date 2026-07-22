package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newTestApp(t *testing.T, backendURL string) *App {
	t.Helper()
	bu, _ := url.Parse(backendURL)
	app, err := NewApp(filepath.Join(t.TempDir(), "users.json"), bu, "admin", "secret123", time.Hour)
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	return app
}

func TestPasswordHashing(t *testing.T) {
	h := hashPassword("hunter2")
	if !verifyPassword("hunter2", h) {
		t.Fatal("correct password should verify")
	}
	if verifyPassword("wrong", h) {
		t.Fatal("wrong password should NOT verify")
	}
	if strings.Count(h, "$") != 3 {
		t.Fatalf("unexpected hash format: %s", h)
	}
}

// login performs POST /login and returns the session cookie value.
func login(t *testing.T, app *App, user, pass string) string {
	t.Helper()
	form := url.Values{"username": {user}, "password": {pass}}
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound {
		t.Fatalf("login status = %d, want 302; body=%s", rec.Code, rec.Body.String())
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == app.cookieName {
			return c.Value
		}
	}
	t.Fatal("no session cookie set on login")
	return ""
}

func TestLoginFlow(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")

	// Wrong password -> 401, no cookie.
	form := url.Values{"username": {"admin"}, "password": {"nope"}}
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad login status = %d, want 401", rec.Code)
	}

	// Correct password -> cookie.
	sid := login(t, app, "admin", "secret123")
	if sid == "" {
		t.Fatal("expected session id")
	}
}

func TestUnauthenticatedRedirectAndJSON(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")

	// HTML navigation -> redirect to /login.
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept", "text/html")
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/login" {
		t.Fatalf("expected 302 -> /login, got %d -> %q", rec.Code, rec.Header().Get("Location"))
	}

	// /v1 without auth -> 401 JSON.
	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rec = httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("v1 unauth status = %d, want 401", rec.Code)
	}
}

func TestAdminCreateUserAndTokenAuth(t *testing.T) {
	// Fake backend that echoes a marker so we can confirm proxying happened.
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Backend must never receive the caller's Authorization header.
		if r.Header.Get("Authorization") != "" {
			t.Errorf("backend received Authorization header: %q", r.Header.Get("Authorization"))
		}
		io.WriteString(w, "BACKEND_OK:"+r.URL.Path)
	}))
	defer backend.Close()

	app := newTestApp(t, backend.URL)
	adminSid := login(t, app, "admin", "secret123")

	// Create a user via /gw/users (admin session + same-origin).
	body := `{"username":"alice","password":"alicepass","role":"user"}`
	req := httptest.NewRequest(http.MethodPost, "/gw/users", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "http://"+req.Host)
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: adminSid})
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create user status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	var created publicUser
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode created user: %v", err)
	}
	if !strings.HasPrefix(created.Token, "sk-") {
		t.Fatalf("token should start with sk-, got %q", created.Token)
	}

	// alice's token authorizes /v1 and reaches the backend.
	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+created.Token)
	rec = httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), "BACKEND_OK:") {
		t.Fatalf("token-auth proxy failed: status=%d body=%s", rec.Code, rec.Body.String())
	}

	// A bogus token is rejected.
	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer sk-not-a-real-token")
	rec = httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("bogus token status = %d, want 401", rec.Code)
	}
}

func TestSessionAuthorizesV1(t *testing.T) {
	// The WebUI (logged-in browser) calls /v1/* with only the session cookie,
	// no Bearer token. That must be proxied to the backend.
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "BACKEND_OK:"+r.URL.Path)
	}))
	defer backend.Close()

	app := newTestApp(t, backend.URL)
	sid := login(t, app, "admin", "secret123")

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: sid})
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), "BACKEND_OK:") {
		t.Fatalf("session-auth /v1 failed: status=%d body=%s", rec.Code, rec.Body.String())
	}

	// The catch-all (WebUI assets) also requires a session and proxies through.
	req = httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept", "text/html")
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: sid})
	rec = httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), "BACKEND_OK:") {
		t.Fatalf("session-auth WebUI failed: status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestNonAdminCannotCreateUser(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")
	adminSid := login(t, app, "admin", "secret123")

	// admin creates a normal user
	body := `{"username":"bob","password":"bobpass","role":"user"}`
	req := httptest.NewRequest(http.MethodPost, "/gw/users", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "http://"+req.Host)
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: adminSid})
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("setup create bob failed: %d %s", rec.Code, rec.Body.String())
	}

	bobSid := login(t, app, "bob", "bobpass")

	// bob (role user) tries to create a user -> 403
	req = httptest.NewRequest(http.MethodPost, "/gw/users", strings.NewReader(`{"username":"eve","password":"evepass"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "http://"+req.Host)
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: bobSid})
	rec = httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin create status = %d, want 403", rec.Code)
	}
}

func TestCSRFGuardBlocksCrossSite(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")
	adminSid := login(t, app, "admin", "secret123")

	req := httptest.NewRequest(http.MethodPost, "/gw/users", strings.NewReader(`{"username":"mallory","password":"x12345"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "http://evil.example.com") // different host
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: adminSid})
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-site create status = %d, want 403", rec.Code)
	}
}

func TestGwMe(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")
	adminSid := login(t, app, "admin", "secret123")

	req := httptest.NewRequest(http.MethodGet, "/gw/me", nil)
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: adminSid})
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/gw/me status = %d", rec.Code)
	}
	var me struct {
		Username, Role, Token string
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &me); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if me.Username != "admin" || me.Role != "admin" || !strings.HasPrefix(me.Token, "sk-") {
		t.Fatalf("unexpected /gw/me: %+v", me)
	}
}

func TestToolsListAndAuth(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")

	// Unauthenticated -> 401.
	req := httptest.NewRequest(http.MethodGet, "/tools", nil)
	rec := httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("/tools unauth = %d, want 401", rec.Code)
	}

	// Logged in -> returns the ssh_exec built-in tool.
	sid := login(t, app, "admin", "secret123")
	req = httptest.NewRequest(http.MethodGet, "/tools", nil)
	req.AddCookie(&http.Cookie{Name: app.cookieName, Value: sid})
	rec = httptest.NewRecorder()
	app.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/tools status = %d", rec.Code)
	}
	var infos []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &infos); err != nil {
		t.Fatalf("decode tools list: %v; body=%s", err, rec.Body.String())
	}
	if len(infos) != 1 || infos[0]["tool"] != "ssh_exec" || infos[0]["type"] != "builtin" {
		t.Fatalf("unexpected tools list: %s", rec.Body.String())
	}
}

func TestToolsExecuteValidation(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")
	sid := login(t, app, "admin", "secret123")

	post := func(payload string) map[string]any {
		req := httptest.NewRequest(http.MethodPost, "/tools", strings.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		req.AddCookie(&http.Cookie{Name: app.cookieName, Value: sid})
		rec := httptest.NewRecorder()
		app.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("/tools POST status = %d (must be 200 even on tool error); body=%s", rec.Code, rec.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return out
	}

	// Unknown tool -> error field.
	if out := post(`{"tool":"nope","params":{}}`); out["error"] == nil {
		t.Fatalf("unknown tool should return error field, got %v", out)
	}
	// Missing params -> error field mentioning required fields.
	if out := post(`{"tool":"ssh_exec","params":{"host":"x"}}`); out["error"] == nil {
		t.Fatalf("missing params should return error field, got %v", out)
	}
}

func TestSSHServersPerUserIsolation(t *testing.T) {
	app := newTestApp(t, "http://127.0.0.1:9")
	adminSid := login(t, app, "admin", "secret123")

	req := func(sid, method, path, payload string) *httptest.ResponseRecorder {
		var r *http.Request
		if payload != "" {
			r = httptest.NewRequest(method, path, strings.NewReader(payload))
			r.Header.Set("Content-Type", "application/json")
		} else {
			r = httptest.NewRequest(method, path, nil)
		}
		r.Header.Set("Origin", "http://"+r.Host)
		r.AddCookie(&http.Cookie{Name: app.cookieName, Value: sid})
		rec := httptest.NewRecorder()
		app.ServeHTTP(rec, r)
		return rec
	}
	errStr := func(rec *httptest.ResponseRecorder) string {
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		s, _ := out["error"].(string)
		return s
	}

	// admin saves a server; list must not leak the password.
	if rec := req(adminSid, http.MethodPost, "/gw/ssh-servers",
		`{"name":"adminbox","host":"10.0.0.1","username":"root","password":"secret"}`); rec.Code != http.StatusCreated {
		t.Fatalf("admin create = %d %s", rec.Code, rec.Body.String())
	}
	if l := req(adminSid, http.MethodGet, "/gw/ssh-servers", "").Body.String(); strings.Contains(l, "secret") {
		t.Fatalf("list leaked password: %s", l)
	}
	if !strings.Contains(req(adminSid, http.MethodGet, "/tools", "").Body.String(), "adminbox") {
		t.Fatal("admin /tools should list adminbox")
	}

	// a regular user, bob
	if rec := req(adminSid, http.MethodPost, "/gw/users", `{"username":"bob","password":"bobpass","role":"user"}`); rec.Code != http.StatusCreated {
		t.Fatalf("create bob = %d %s", rec.Code, rec.Body.String())
	}
	bobSid := login(t, app, "bob", "bobpass")

	// bob does NOT see admin's server (UI list nor tool description).
	if strings.Contains(req(bobSid, http.MethodGet, "/gw/ssh-servers", "").Body.String(), "adminbox") {
		t.Fatal("bob must not see admin's server in the list")
	}
	if strings.Contains(req(bobSid, http.MethodGet, "/tools", "").Body.String(), "adminbox") {
		t.Fatal("bob's tool description must not mention admin's server")
	}

	// bob saves his OWN server reusing the same NAME (allowed: names are per-user).
	if rec := req(bobSid, http.MethodPost, "/gw/ssh-servers",
		`{"name":"adminbox","host":"192.168.1.9","username":"bob","password":"x"}`); rec.Code != http.StatusCreated {
		t.Fatalf("bob create = %d %s", rec.Code, rec.Body.String())
	}
	bobList := req(bobSid, http.MethodGet, "/gw/ssh-servers", "").Body.String()
	if !strings.Contains(bobList, "192.168.1.9") || strings.Contains(bobList, "10.0.0.1") {
		t.Fatalf("bob should see only his own server: %s", bobList)
	}

	// Tool resolution is per-user: bob resolves his own "adminbox" (not admin's),
	// and a name he doesn't own is reported as not saved.
	resolved := req(bobSid, http.MethodPost, "/tools", `{"tool":"ssh_exec","params":{"server":"adminbox","command":"id"}}`)
	if strings.Contains(errStr(resolved), "não está salvo") {
		t.Fatalf("bob should resolve his own server, got %s", resolved.Body.String())
	}
	// Host-fallback: the model puts the saved NAME in `host` (no `server`) — it
	// must still resolve to bob's server (not fail with "missing credentials").
	hostFb := req(bobSid, http.MethodPost, "/tools", `{"tool":"ssh_exec","params":{"host":"adminbox","command":"id"}}`)
	if e := errStr(hostFb); strings.Contains(e, "obrigat") || strings.Contains(e, "salvo") {
		t.Fatalf("host-fallback should resolve bob's saved server, got %s", hostFb.Body.String())
	}
	ghost := req(bobSid, http.MethodPost, "/tools", `{"tool":"ssh_exec","params":{"server":"ghost","command":"id"}}`)
	if !strings.Contains(errStr(ghost), "não está salvo") {
		t.Fatalf("unknown server should be 'não está salvo', got %s", ghost.Body.String())
	}

	// admin deleting "adminbox" removes only admin's; bob's survives.
	if rec := req(adminSid, http.MethodDelete, "/gw/ssh-servers/adminbox", ""); rec.Code != http.StatusOK {
		t.Fatalf("admin delete own = %d", rec.Code)
	}
	if !strings.Contains(req(bobSid, http.MethodGet, "/gw/ssh-servers", "").Body.String(), "192.168.1.9") {
		t.Fatal("bob's server must survive admin's delete")
	}
}

func TestPersistenceReload(t *testing.T) {
	dir := t.TempDir()
	authFile := filepath.Join(dir, "users.json")
	bu, _ := url.Parse("http://127.0.0.1:9")

	app1, err := NewApp(authFile, bu, "admin", "secret123", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	adminSid := login(t, app1, "admin", "secret123")
	req := httptest.NewRequest(http.MethodPost, "/gw/users", strings.NewReader(`{"username":"carol","password":"carolpass"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "http://"+req.Host)
	req.AddCookie(&http.Cookie{Name: app1.cookieName, Value: adminSid})
	rec := httptest.NewRecorder()
	app1.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create carol: %d %s", rec.Code, rec.Body.String())
	}

	// New App from the same file: carol must still be able to log in,
	// and a second admin must NOT be created.
	app2, err := NewApp(authFile, bu, "admin", "differentpass", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if got := len(app2.store.Users); got != 2 {
		t.Fatalf("reloaded user count = %d, want 2", got)
	}
	_ = login(t, app2, "carol", "carolpass")
}

# KRT Occupier Engagement Tracker — Production Source Code

Complete, ready-to-deploy source code for hosting on your private cloud.

## Project Structure

```
krt-crm/
├── backend/
│   ├── package.json
│   ├── .env.example
│   ├── server.js
│   ├── db.js
│   ├── auth.js
│   └── routes/
│       ├── auth.js
│       ├── users.js
│       ├── occupiers.js
│       ├── meetings.js
│       └── audit.js
├── frontend/
│   ├── package.json
│   ├── vite.config.js
│   ├── index.html
│   └── src/
│       ├── main.jsx
│       ├── App.jsx
│       └── api.js
├── database/
│   └── schema.sql
└── deploy/
    └── nginx.conf
```

---

## 1. Database Schema

**File: `database/schema.sql`**

```sql
-- Run this once after creating the database
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL UNIQUE,
    email VARCHAR(200) UNIQUE,
    role VARCHAR(50) NOT NULL DEFAULT 'Leasing',
    is_admin BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(200)
);

CREATE TABLE IF NOT EXISTS occupiers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,
    tier VARCHAR(20) NOT NULL,
    depth VARCHAR(20),
    sector VARCHAR(100),
    city VARCHAR(100),
    sqft INTEGER,
    lease_expiry VARCHAR(7),
    risk VARCHAR(20),
    owner VARCHAR(200),
    notes TEXT,
    created_by VARCHAR(200),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_by VARCHAR(200),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS meetings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    occupier_id UUID REFERENCES occupiers(id) ON DELETE CASCADE,
    meeting_date DATE NOT NULL,
    meeting_type VARCHAR(100),
    attendees TEXT,
    notes TEXT NOT NULL,
    actions TEXT,
    outcome VARCHAR(50),
    created_by VARCHAR(200),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_name VARCHAR(200),
    action TEXT,
    target TEXT,
    at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_meetings_occupier ON meetings(occupier_id);
CREATE INDEX IF NOT EXISTS idx_meetings_date ON meetings(meeting_date DESC);
CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log(at DESC);
CREATE INDEX IF NOT EXISTS idx_occupiers_tier ON occupiers(tier);
```

---

## 2. Backend Files

### `backend/package.json`

```json
{
  "name": "krt-crm-backend",
  "version": "1.0.0",
  "type": "module",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "express-rate-limit": "^7.4.0",
    "jsonwebtoken": "^9.0.2",
    "pg": "^8.12.0",
    "helmet": "^7.1.0"
  }
}
```

### `backend/.env.example`

```bash
# Copy this to .env and fill in your actual values
PORT=3000
NODE_ENV=production

# PostgreSQL connection
DATABASE_URL=postgresql://krt_app:your_strong_password@localhost:5432/krt_crm

# JWT secret - use: node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
JWT_SECRET=replace_with_64_character_random_string

# Session config
TOKEN_EXPIRY=8h

# CORS - your frontend URL
FRONTEND_URL=https://crm.knowledgerealtytrust.com
```

### `backend/db.js`

```javascript
import pg from "pg";
import dotenv from "dotenv";
dotenv.config();

const { Pool } = pg;

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

pool.on("error", (err) => {
  console.error("Unexpected PG error:", err);
});

export async function query(text, params) {
  const start = Date.now();
  const res = await pool.query(text, params);
  const duration = Date.now() - start;
  if (duration > 500) console.warn("Slow query:", { text, duration, rows: res.rowCount });
  return res;
}
```

### `backend/auth.js`

```javascript
import jwt from "jsonwebtoken";
import bcrypt from "bcryptjs";

const JWT_SECRET = process.env.JWT_SECRET;
const TOKEN_EXPIRY = process.env.TOKEN_EXPIRY || "8h";

if (!JWT_SECRET || JWT_SECRET.length < 32) {
  throw new Error("JWT_SECRET must be set and at least 32 characters in .env");
}

export async function hashPassword(plain) {
  return bcrypt.hash(plain, 12);
}

export async function verifyPassword(plain, hash) {
  return bcrypt.compare(plain, hash);
}

export function generateToken(user) {
  return jwt.sign(
    { id: user.id, name: user.name, role: user.role, isAdmin: user.is_admin },
    JWT_SECRET,
    { expiresIn: TOKEN_EXPIRY }
  );
}

// Middleware to require authentication
export function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Authentication required" });
  }
  const token = auth.slice(7);
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
}

// Middleware to require admin
export function requireAdmin(req, res, next) {
  if (!req.user || !req.user.isAdmin) {
    return res.status(403).json({ error: "Admin access required" });
  }
  next();
}

// Middleware to block read-only users from write operations
export function requireWriter(req, res, next) {
  if (!req.user) return res.status(401).json({ error: "Auth required" });
  if (req.user.role === "Read Only" && !req.user.isAdmin) {
    return res.status(403).json({ error: "Read-only users cannot perform this action" });
  }
  next();
}
```

### `backend/server.js`

```javascript
import express from "express";
import cors from "cors";
import helmet from "helmet";
import rateLimit from "express-rate-limit";
import dotenv from "dotenv";

import authRoutes from "./routes/auth.js";
import userRoutes from "./routes/users.js";
import occupierRoutes from "./routes/occupiers.js";
import meetingRoutes from "./routes/meetings.js";
import auditRoutes from "./routes/audit.js";

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(express.json({ limit: "1mb" }));
app.use(cors({
  origin: process.env.FRONTEND_URL || "http://localhost:5173",
  credentials: true,
}));

// Rate limit on auth endpoints to prevent brute force
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10,
  message: { error: "Too many login attempts, try again in 15 minutes" },
});

// Health check
app.get("/api/health", (req, res) => res.json({ ok: true, ts: new Date().toISOString() }));

// Routes
app.use("/api/auth", authLimiter, authRoutes);
app.use("/api/users", userRoutes);
app.use("/api/occupiers", occupierRoutes);
app.use("/api/meetings", meetingRoutes);
app.use("/api/audit", auditRoutes);

// Global error handler
app.use((err, req, res, next) => {
  console.error("Server error:", err);
  res.status(500).json({ error: "Internal server error" });
});

app.listen(PORT, () => {
  console.log(`KRT CRM backend running on port ${PORT}`);
});
```

### `backend/routes/auth.js`

```javascript
import express from "express";
import { query } from "../db.js";
import { hashPassword, verifyPassword, generateToken, requireAuth } from "../auth.js";

const router = express.Router();

// POST /api/auth/login
router.post("/login", async (req, res) => {
  const { name, password } = req.body;
  if (!name || !password) return res.status(400).json({ error: "Name and password required" });

  try {
    const { rows } = await query(
      "SELECT * FROM users WHERE LOWER(name) = LOWER($1) AND is_active = TRUE",
      [name.trim()]
    );
    if (rows.length === 0) return res.status(401).json({ error: "Invalid credentials" });

    const user = rows[0];
    const ok = await verifyPassword(password, user.password_hash);
    if (!ok) return res.status(401).json({ error: "Invalid credentials" });

    const token = generateToken(user);
    await query(
      "INSERT INTO audit_log (user_name, action) VALUES ($1, $2)",
      [user.name, "signed in"]
    );

    res.json({
      token,
      user: {
        id: user.id,
        name: user.name,
        role: user.role,
        isAdmin: user.is_admin,
      },
    });
  } catch (e) {
    console.error("Login error:", e);
    res.status(500).json({ error: "Login failed" });
  }
});

// POST /api/auth/first-run (only works if no users exist)
router.post("/first-run", async (req, res) => {
  const { name, role, password } = req.body;
  if (!name || !password) return res.status(400).json({ error: "Name and password required" });
  if (password.length < 8) return res.status(400).json({ error: "Password must be at least 8 characters" });

  try {
    const { rows: existing } = await query("SELECT COUNT(*) FROM users");
    if (parseInt(existing[0].count) > 0) {
      return res.status(403).json({ error: "Setup already complete" });
    }

    const passwordHash = await hashPassword(password);
    const { rows } = await query(
      `INSERT INTO users (name, role, is_admin, is_active, password_hash, created_by)
       VALUES ($1, $2, TRUE, TRUE, $3, $1) RETURNING *`,
      [name.trim(), role || "Management", passwordHash]
    );

    const user = rows[0];
    const token = generateToken(user);
    await query("INSERT INTO audit_log (user_name, action) VALUES ($1, $2)", [user.name, "set up CRM as admin"]);

    res.json({
      token,
      user: { id: user.id, name: user.name, role: user.role, isAdmin: user.is_admin },
    });
  } catch (e) {
    console.error("First-run error:", e);
    res.status(500).json({ error: "Setup failed" });
  }
});

// GET /api/auth/status — checks if first-run is needed
router.get("/status", async (req, res) => {
  try {
    const { rows } = await query("SELECT COUNT(*) FROM users");
    res.json({ initialized: parseInt(rows[0].count) > 0 });
  } catch (e) {
    res.status(500).json({ error: "Status check failed" });
  }
});

// POST /api/auth/logout
router.post("/logout", requireAuth, async (req, res) => {
  await query("INSERT INTO audit_log (user_name, action) VALUES ($1, $2)", [req.user.name, "signed out"]);
  res.json({ ok: true });
});

export default router;
```

### `backend/routes/users.js`

```javascript
import express from "express";
import { query } from "../db.js";
import { hashPassword, requireAuth, requireAdmin } from "../auth.js";

const router = express.Router();

// GET /api/users (admin only)
router.get("/", requireAuth, requireAdmin, async (req, res) => {
  const { rows } = await query(
    "SELECT id, name, email, role, is_admin, is_active, created_at, created_by FROM users ORDER BY created_at"
  );
  res.json(rows);
});

// POST /api/users (admin only — add new user)
router.post("/", requireAuth, requireAdmin, async (req, res) => {
  const { name, role, isAdmin, password } = req.body;
  if (!name || !password) return res.status(400).json({ error: "Name and password required" });
  if (password.length < 8) return res.status(400).json({ error: "Password must be at least 8 chars" });

  try {
    const passwordHash = await hashPassword(password);
    const { rows } = await query(
      `INSERT INTO users (name, role, is_admin, is_active, password_hash, created_by)
       VALUES ($1, $2, $3, TRUE, $4, $5) RETURNING id, name, role, is_admin, is_active, created_at`,
      [name.trim(), role || "Leasing", !!isAdmin, passwordHash, req.user.name]
    );
    await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
      [req.user.name, isAdmin ? "added admin user" : "added user", name]);
    res.json(rows[0]);
  } catch (e) {
    if (e.code === "23505") return res.status(400).json({ error: "Username already exists" });
    console.error(e);
    res.status(500).json({ error: "Failed to add user" });
  }
});

// PATCH /api/users/:id (admin only — toggle active/admin, change role)
router.patch("/:id", requireAuth, requireAdmin, async (req, res) => {
  const { is_active, is_admin, role } = req.body;
  const { id } = req.params;

  // Prevent demoting the last active admin
  if (is_admin === false) {
    const { rows } = await query("SELECT COUNT(*) FROM users WHERE is_admin = TRUE AND is_active = TRUE AND id != $1", [id]);
    if (parseInt(rows[0].count) === 0) {
      return res.status(400).json({ error: "Cannot demote the last admin" });
    }
  }

  const updates = [];
  const values = [];
  let i = 1;
  if (is_active !== undefined) { updates.push(`is_active = $${i++}`); values.push(is_active); }
  if (is_admin !== undefined) { updates.push(`is_admin = $${i++}`); values.push(is_admin); }
  if (role !== undefined) { updates.push(`role = $${i++}`); values.push(role); }

  if (updates.length === 0) return res.status(400).json({ error: "No updates provided" });
  values.push(id);

  const { rows } = await query(
    `UPDATE users SET ${updates.join(", ")} WHERE id = $${i} RETURNING id, name, role, is_admin, is_active`,
    values
  );
  if (rows.length === 0) return res.status(404).json({ error: "User not found" });

  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "updated user", rows[0].name]);
  res.json(rows[0]);
});

// POST /api/users/:id/reset-password (admin only)
router.post("/:id/reset-password", requireAuth, requireAdmin, async (req, res) => {
  const { password } = req.body;
  if (!password || password.length < 8) return res.status(400).json({ error: "Password must be at least 8 chars" });

  const passwordHash = await hashPassword(password);
  const { rows } = await query(
    "UPDATE users SET password_hash = $1 WHERE id = $2 RETURNING name",
    [passwordHash, req.params.id]
  );
  if (rows.length === 0) return res.status(404).json({ error: "User not found" });

  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "reset password for", rows[0].name]);
  res.json({ ok: true });
});

export default router;
```

### `backend/routes/occupiers.js`

```javascript
import express from "express";
import { query } from "../db.js";
import { requireAuth, requireWriter } from "../auth.js";

const router = express.Router();

// All occupier endpoints require authentication
router.use(requireAuth);

// GET /api/occupiers
router.get("/", async (req, res) => {
  const { rows } = await query("SELECT * FROM occupiers ORDER BY name");
  res.json(rows);
});

// GET /api/occupiers/:id
router.get("/:id", async (req, res) => {
  const { rows } = await query("SELECT * FROM occupiers WHERE id = $1", [req.params.id]);
  if (rows.length === 0) return res.status(404).json({ error: "Not found" });
  res.json(rows[0]);
});

// POST /api/occupiers (writers only)
router.post("/", requireWriter, async (req, res) => {
  const { name, tier, depth, sector, city, sqft, lease_expiry, risk, owner, notes } = req.body;
  if (!name || !tier) return res.status(400).json({ error: "Name and tier required" });

  const { rows } = await query(
    `INSERT INTO occupiers (name, tier, depth, sector, city, sqft, lease_expiry, risk, owner, notes, created_by, updated_by)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$11) RETURNING *`,
    [name, tier, depth, sector, city, sqft || null, lease_expiry, risk, owner, notes, req.user.name]
  );
  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "added occupier", name]);
  res.json(rows[0]);
});

// PUT /api/occupiers/:id (writers only)
router.put("/:id", requireWriter, async (req, res) => {
  const { name, tier, depth, sector, city, sqft, lease_expiry, risk, owner, notes } = req.body;

  const { rows } = await query(
    `UPDATE occupiers SET name=$1, tier=$2, depth=$3, sector=$4, city=$5, sqft=$6,
     lease_expiry=$7, risk=$8, owner=$9, notes=$10, updated_by=$11, updated_at=NOW()
     WHERE id=$12 RETURNING *`,
    [name, tier, depth, sector, city, sqft || null, lease_expiry, risk, owner, notes, req.user.name, req.params.id]
  );
  if (rows.length === 0) return res.status(404).json({ error: "Not found" });

  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "edited occupier", name]);
  res.json(rows[0]);
});

// DELETE /api/occupiers/:id (admin only — added for safety)
router.delete("/:id", requireWriter, async (req, res) => {
  if (!req.user.isAdmin) return res.status(403).json({ error: "Admin only" });
  const { rows } = await query("DELETE FROM occupiers WHERE id = $1 RETURNING name", [req.params.id]);
  if (rows.length === 0) return res.status(404).json({ error: "Not found" });
  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "deleted occupier", rows[0].name]);
  res.json({ ok: true });
});

export default router;
```

### `backend/routes/meetings.js`

```javascript
import express from "express";
import { query } from "../db.js";
import { requireAuth, requireWriter } from "../auth.js";

const router = express.Router();

router.use(requireAuth);

// GET /api/meetings (optionally filtered by occupier_id)
router.get("/", async (req, res) => {
  const { occupier_id } = req.query;
  let sql = "SELECT * FROM meetings";
  let params = [];
  if (occupier_id) { sql += " WHERE occupier_id = $1"; params = [occupier_id]; }
  sql += " ORDER BY meeting_date DESC, created_at DESC";

  const { rows } = await query(sql, params);
  res.json(rows);
});

// POST /api/meetings (writers only)
router.post("/", requireWriter, async (req, res) => {
  const { occupier_id, meeting_date, meeting_type, attendees, notes, actions, outcome } = req.body;
  if (!occupier_id || !meeting_date || !notes) {
    return res.status(400).json({ error: "Occupier, date, and notes required" });
  }

  const { rows } = await query(
    `INSERT INTO meetings (occupier_id, meeting_date, meeting_type, attendees, notes, actions, outcome, created_by)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,
    [occupier_id, meeting_date, meeting_type, attendees, notes, actions, outcome, req.user.name]
  );

  const { rows: occRows } = await query("SELECT name FROM occupiers WHERE id = $1", [occupier_id]);
  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "logged meeting for", occRows[0]?.name || "Unknown"]);

  res.json(rows[0]);
});

// DELETE /api/meetings/:id (writers only)
router.delete("/:id", requireWriter, async (req, res) => {
  const { rows } = await query(
    `DELETE FROM meetings WHERE id = $1 RETURNING occupier_id`,
    [req.params.id]
  );
  if (rows.length === 0) return res.status(404).json({ error: "Not found" });

  const { rows: occRows } = await query("SELECT name FROM occupiers WHERE id = $1", [rows[0].occupier_id]);
  await query("INSERT INTO audit_log (user_name, action, target) VALUES ($1, $2, $3)",
    [req.user.name, "deleted meeting from", occRows[0]?.name || "Unknown"]);

  res.json({ ok: true });
});

export default router;
```

### `backend/routes/audit.js`

```javascript
import express from "express";
import { query } from "../db.js";
import { requireAuth, requireAdmin } from "../auth.js";

const router = express.Router();

// GET /api/audit (admin only — last 500 entries)
router.get("/", requireAuth, requireAdmin, async (req, res) => {
  const { rows } = await query("SELECT * FROM audit_log ORDER BY at DESC LIMIT 500");
  res.json(rows);
});

export default router;
```

---

## 3. Frontend Files

### `frontend/package.json`

```json
{
  "name": "krt-crm-frontend",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.1",
    "vite": "^5.3.5"
  }
}
```

### `frontend/vite.config.js`

```javascript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://localhost:3000",
    },
  },
  build: {
    outDir: "dist",
    sourcemap: false,
  },
});
```

### `frontend/index.html`

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
    <title>KRT Occupier Engagement Tracker</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
```

### `frontend/src/main.jsx`

```javascript
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App.jsx";

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
```

### `frontend/src/api.js`

```javascript
const API_BASE = "/api";

function getToken() {
  return localStorage.getItem("krt_token");
}

export function setToken(token) {
  if (token) localStorage.setItem("krt_token", token);
  else localStorage.removeItem("krt_token");
}

async function request(path, options = {}) {
  const token = getToken();
  const headers = {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(options.headers || {}),
  };
  const res = await fetch(`${API_BASE}${path}`, { ...options, headers });

  if (res.status === 401) {
    setToken(null);
    window.location.reload();
    throw new Error("Session expired");
  }
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Request failed" }));
    throw new Error(err.error || `HTTP ${res.status}`);
  }
  return res.json();
}

export const api = {
  // Auth
  status: () => request("/auth/status"),
  login: (name, password) =>
    request("/auth/login", { method: "POST", body: JSON.stringify({ name, password }) }),
  firstRun: (data) =>
    request("/auth/first-run", { method: "POST", body: JSON.stringify(data) }),
  logout: () => request("/auth/logout", { method: "POST" }),

  // Users
  listUsers: () => request("/users"),
  addUser: (data) => request("/users", { method: "POST", body: JSON.stringify(data) }),
  updateUser: (id, data) => request(`/users/${id}`, { method: "PATCH", body: JSON.stringify(data) }),
  resetPassword: (id, password) =>
    request(`/users/${id}/reset-password`, { method: "POST", body: JSON.stringify({ password }) }),

  // Occupiers
  listOccupiers: () => request("/occupiers"),
  addOccupier: (data) => request("/occupiers", { method: "POST", body: JSON.stringify(data) }),
  updateOccupier: (id, data) => request(`/occupiers/${id}`, { method: "PUT", body: JSON.stringify(data) }),
  deleteOccupier: (id) => request(`/occupiers/${id}`, { method: "DELETE" }),

  // Meetings
  listMeetings: () => request("/meetings"),
  addMeeting: (data) => request("/meetings", { method: "POST", body: JSON.stringify(data) }),
  deleteMeeting: (id) => request(`/meetings/${id}`, { method: "DELETE" }),

  // Audit
  listAudit: () => request("/audit"),
};
```

### `frontend/src/App.jsx`

**This is the same JSX from the artifact, but with `window.storage` calls replaced by `api.*` calls.** Use the latest version of the artifact code as your starting point, then make these specific replacements:

```javascript
// At the top, add:
import { api, setToken } from "./api.js";

// REPLACE:
// const uR = await window.storage.get(SK_USERS, true);
// WITH:
const usersData = await api.listUsers();

// REPLACE:
// await window.storage.set(SK_OCCS, JSON.stringify(no), true);
// WITH:
await api.addOccupier(occ);  // or updateOccupier(id, occ)

// REPLACE login:
// const hashed = await hashCode(pass);
// if (hashed !== user.passHash) ...
// WITH:
const result = await api.login(name, password);
setToken(result.token);
setCurrentUser(result.user);
```

A full conversion takes about 2-3 hours for a React developer. The key idea: every place that read from or wrote to `window.storage` now talks to the backend API instead.

---

## 4. Deployment Files

### `deploy/nginx.conf`

```nginx
# Place at /etc/nginx/sites-available/krt-crm
# Then: sudo ln -s /etc/nginx/sites-available/krt-crm /etc/nginx/sites-enabled/

server {
    listen 80;
    server_name crm.knowledgerealtytrust.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name crm.knowledgerealtytrust.com;

    # SSL certificate paths — adjust to your cert location
    ssl_certificate /etc/letsencrypt/live/crm.knowledgerealtytrust.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/crm.knowledgerealtytrust.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Security headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Serve frontend
    root /var/www/krt-crm/frontend/dist;
    index index.html;

    location / {
        try_files $uri /index.html;
    }

    # Proxy API to Node.js backend
    location /api/ {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }

    # Block direct access to sensitive paths
    location ~ /\. { deny all; }
}
```

---

## 5. Deployment Steps

### One-time server setup

```bash
# Install dependencies (Ubuntu 22.04)
sudo apt update && sudo apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs postgresql postgresql-contrib nginx git
sudo npm install -g pm2

# Create app directory
sudo mkdir -p /var/www/krt-crm
sudo chown $USER:$USER /var/www/krt-crm
```

### Database setup

```bash
sudo -u postgres psql -c "CREATE DATABASE krt_crm;"
sudo -u postgres psql -c "CREATE USER krt_app WITH ENCRYPTED PASSWORD 'CHANGE_THIS_PASSWORD';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE krt_crm TO krt_app;"
sudo -u postgres psql -d krt_crm -f database/schema.sql
```

### Deploy backend

```bash
cd /var/www/krt-crm/backend
npm install
cp .env.example .env
nano .env   # Fill in DATABASE_URL, JWT_SECRET, FRONTEND_URL
pm2 start server.js --name krt-backend
pm2 startup
pm2 save
```

### Deploy frontend

```bash
cd /var/www/krt-crm/frontend
npm install
npm run build   # Creates dist/ folder served by Nginx
```

### Configure Nginx + HTTPS

```bash
sudo cp deploy/nginx.conf /etc/nginx/sites-available/krt-crm
sudo ln -s /etc/nginx/sites-available/krt-crm /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Get free SSL cert
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d crm.knowledgerealtytrust.com
```

### First-time access

Open `https://crm.knowledgerealtytrust.com` in a browser. Since no users exist, the first-run admin setup screen appears. Create the first admin account, then sign in and start using.

---

## 6. Daily backup script

**File: `/etc/cron.daily/krt-backup`** (chmod +x)

```bash
#!/bin/bash
BACKUP_DIR=/var/backups/krt-crm
mkdir -p $BACKUP_DIR
DATE=$(date +%Y-%m-%d)
sudo -u postgres pg_dump krt_crm | gzip > $BACKUP_DIR/krt_crm_$DATE.sql.gz
# Keep last 30 days only
find $BACKUP_DIR -name "*.sql.gz" -mtime +30 -delete
```

---

## What you have here

This package gives you everything to host a real, production-grade CRM:

- **Real authentication** with bcrypt passwords and JWT tokens
- **Role-based access** (admin / standard / read-only) enforced server-side
- **Real shared database** — all users see the same data
- **Audit log** of every action
- **Rate limiting** on login to prevent brute force
- **Security headers**, HTTPS, and proper CORS
- **Daily automated backups**

## What still needs your developer's time

1. Final conversion of `App.jsx` from `window.storage` calls to `api.*` calls — about 2-3 hours
2. Testing all flows end-to-end
3. Setting environment variables and SSL on your server
4. Configuring DNS to point `crm.knowledgerealtytrust.com` to your server's IP

Total time from zero to live: **1-2 days** for a Node.js + React developer.

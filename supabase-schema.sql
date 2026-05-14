-- ====================================================
-- KRT CRM Supabase Schema Setup
-- Run this in your Supabase SQL Editor
-- ====================================================

-- 1. Create the Users Table
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL UNIQUE,
    role VARCHAR(50) NOT NULL DEFAULT 'Leasing',
    is_admin BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(200)
);

-- 2. Create the Occupiers Table
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

-- 3. Create the Meetings Table
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

-- 4. Create the Audit Log Table
CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_name VARCHAR(200),
    action TEXT,
    target TEXT,
    at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Enable Row Level Security (RLS)
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE occupiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- 6. Setup Basic Access Policies
-- For this CRM, authentication is handled in-app via pass_hash verification.
-- This policy allows all operations by the anon key since your app verifies login locally.
-- If you transition to Supabase Auth in the future, you can update these to check auth.uid().
CREATE POLICY "Allow all operations on users" ON users FOR ALL USING (true);
CREATE POLICY "Allow all operations on occupiers" ON occupiers FOR ALL USING (true);
CREATE POLICY "Allow all operations on meetings" ON meetings FOR ALL USING (true);
CREATE POLICY "Allow all operations on audit_log" ON audit_log FOR ALL USING (true);

-- 7. Add Indexes for performance
CREATE INDEX IF NOT EXISTS idx_meetings_occupier ON meetings(occupier_id);
CREATE INDEX IF NOT EXISTS idx_meetings_date ON meetings(meeting_date DESC);
CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log(at DESC);
CREATE INDEX IF NOT EXISTS idx_occupiers_tier ON occupiers(tier);
